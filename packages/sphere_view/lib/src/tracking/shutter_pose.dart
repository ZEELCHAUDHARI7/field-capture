import '../api/models/device_pose.dart';
import '../camera/camera_platform.dart';
import 'pose_buffer.dart';

/// The outcome of pairing one bracket with the pose stream: either a pose
/// interpolated to the reference shutter, or a sentence saying why not.
///
/// Never a bare `null`. Architecture §8's rule is that no compromise is silent,
/// and "there was no pose for this frame" is a compromise a capture session has
/// to act on — Phase 08 re-queues the target, and the reason is what tells the
/// user whether to expect it to work the second time.
class ShutterPoseResolution {
  /// A successful pairing.
  const ShutterPoseResolution.resolved({
    required DevicePose this.pose,
    required this.referenceFrame,
    required this.exact,
  }) : reason = null;

  /// A failed pairing, with [reason] explaining what was missing.
  const ShutterPoseResolution.unavailable({
    required String this.reason,
    this.referenceFrame,
  }) : pose = null,
       exact = false;

  /// The pose SLERPed to [referenceFrame]'s shutter, or `null`.
  final DevicePose? pose;

  /// The frame the pose belongs to: the 0 EV shot when the bracket has one.
  final PlatformFrame? referenceFrame;

  /// Whether the reference frame really was at 0 EV, or whether the bracket
  /// had no 0 EV shot and the first frame stood in.
  final bool exact;

  /// Why no pose could be produced, or `null` on success.
  final String? reason;

  /// Whether a pose is available.
  bool get isResolved => pose != null;

  @override
  String toString() => pose == null
      ? 'ShutterPoseResolution.unavailable($reason)'
      : 'ShutterPoseResolution.resolved($pose)';
}

/// Interpolates the pose stream to the instant a bracket's reference shutter
/// fired.
///
/// **Why the 0 EV shot specifically** (§3). A bracket is three frames spread
/// over a few hundred milliseconds, and Phase 05 fuses the other two *onto* the
/// 0 EV frame — it is the alignment reference, so the fused output inherits its
/// geometry and nothing else's. Attaching the pose of the burst's start, or of
/// its midpoint, would describe a frame that does not exist. At a realistic
/// 60°/s pan, the ±2 EV shots are 0.5–1.5° away from the 0 EV one, which is
/// larger than the entire error budget bundle adjustment works within.
///
/// The 0 EV frame is selected exactly as `CapturedPosition.baseShot` does —
/// the frame whose requested bias is 0.0, else the first — so that the pose
/// written into the bundle and the shot the bundle calls its base can never
/// disagree.
class ShutterPoseResolver {
  /// Resolves against [buffer].
  const ShutterPoseResolver(this.buffer);

  /// The history to interpolate. Deliberately the live buffer rather than a
  /// snapshot: §6 pitfall 5 is that continuous history is what makes this work.
  final PoseBuffer buffer;

  /// Pairs [capture] with a pose.
  ShutterPoseResolution resolve(BracketCapture capture) {
    if (capture.frames.isEmpty) {
      return const ShutterPoseResolution.unavailable(
        reason: 'the bracket returned no frames, so there is no shutter '
            'timestamp to interpolate to',
      );
    }

    final zeroEv = capture.frames.where((f) => f.evBias == 0.0);
    final reference = zeroEv.isEmpty ? capture.frames.first : zeroEv.first;
    final exact = zeroEv.isNotEmpty;

    final pose = buffer.at(reference.timestampUs);
    if (pose != null) {
      return ShutterPoseResolution.resolved(
        pose: pose,
        referenceFrame: reference,
        exact: exact,
      );
    }

    return ShutterPoseResolution.unavailable(
      reason: _explain(reference),
      referenceFrame: reference,
    );
  }

  /// Says *how* the timestamp missed, because the three ways it can miss have
  /// three different fixes: a shutter older than the buffer means the burst
  /// pipeline is slower than the buffer is long; a shutter newer than the
  /// newest sample means the pose stream stalled or the two clocks are not the
  /// same clock at all; an empty buffer means sampling never started or is
  /// still warming up.
  String _explain(PlatformFrame reference) {
    final window = buffer.window;
    if (window == null) {
      return 'the pose buffer is empty at the shutter '
          '(${reference.timestampUs} µs): sampling has not started, or is '
          'still in its warm-up window';
    }
    if (reference.timestampUs < window.fromUs) {
      final lateBy = (window.fromUs - reference.timestampUs) / 1000.0;
      return 'the shutter at ${reference.timestampUs} µs is '
          '${lateBy.toStringAsFixed(0)} ms older than the oldest buffered '
          'pose, so the burst took longer to deliver than the buffer is long';
    }
    final aheadBy = (reference.timestampUs - window.toUs) / 1000.0;
    return 'the shutter at ${reference.timestampUs} µs is '
        '${aheadBy.toStringAsFixed(0)} ms newer than the newest buffered pose: '
        'either the pose stream stalled, or the camera and motion clocks are '
        'not the same clock (Phase 06 §2.5, Phase 07 §6 pitfall 1)';
  }
}
