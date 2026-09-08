import 'dart:async';

import 'package:vector_math/vector_math_64.dart';

import '../camera/messages.g.dart' as wire;
import 'pose_frame_conversion.dart';
import 'pose_platform.dart';
import 'pose_source.dart';

/// [SpherePosePlatform] over the Pigeon-generated channel.
///
/// The only file in the tracking layer that touches the wire types, and it does
/// exactly one thing: translate. No frame conversion, no warm-up, no yaw datum
/// — those live above this seam so they can be tested on a laptop, which is the
/// same division `pigeon_camera_platform.dart` draws for the intrinsics chain
/// and for the same reason: the arithmetic that decides whether a panorama is
/// mirrored must be exercised on more than the two devices in the room.
class PigeonPosePlatform implements SpherePosePlatform {
  /// Creates a platform over the real channel.
  ///
  /// It took an injectable `api` until Phase 13's API audit found that nothing
  /// had ever passed one — and that the parameter put a generated wire type
  /// into a public constructor, where a consumer could see a name they are
  /// told never to touch. Tests fake [SpherePosePlatform] itself, one layer up,
  /// which is the seam worth having: it is the boundary the conversion in
  /// Math §2 sits above.
  PigeonPosePlatform() : _api = wire.SpherePoseHostApi() {
    wire.SpherePoseFlutterApi.setUp(_Callbacks(this));
  }

  final wire.SpherePoseHostApi _api;

  final _samples = StreamController<PlatformAttitudeSample>.broadcast();
  final _errors = StreamController<PosePlatformError>.broadcast();

  @override
  Stream<PlatformAttitudeSample> get samples => _samples.stream;

  @override
  Stream<PosePlatformError> get errors => _errors.stream;

  @override
  Future<PoseSupport> capabilities() async =>
      _support(await _api.poseCapabilities());

  @override
  Future<PoseStreamStart> start(Duration samplingPeriod) async {
    // Checked here as well as natively so the refusal is a typed Dart
    // exception with the platform's own sentence in it, rather than a
    // `PlatformException` a caller has to parse (Phase 12 §1).
    final found = await capabilities();
    if (!found.isSupported) throw PoseSourceUnsupported(found);
    final info = await _api.startPose(samplingPeriod.inMicroseconds);
    return PoseStreamStart(
      frame: _frame(info.frame),
      clock: PoseClock(
        base: switch (info.clock.base) {
          wire.PlatformPoseClockBase.androidElapsedRealtime =>
            PoseClockBase.androidElapsedRealtime,
          wire.PlatformPoseClockBase.androidMonotonicNanoTime =>
            PoseClockBase.androidMonotonicNanoTime,
          wire.PlatformPoseClockBase.iosSystemUptime =>
            PoseClockBase.iosSystemUptime,
        },
        offsetUs: info.clock.offsetUs,
        uncertaintyUs: info.clock.uncertaintyUs,
        note: info.clock.note,
      ),
      samplingPeriod: Duration(microseconds: info.samplingPeriodUs),
      minDelayUs: info.minDelayUs,
      note: info.note,
    );
  }

  @override
  Future<void> stop() => _api.stopPose();

  /// Closes the callback streams. Separate from [stop] because a session may
  /// stop and restart sampling while the same platform object lives on.
  Future<void> dispose() async {
    wire.SpherePoseFlutterApi.setUp(null);
    await _samples.close();
    await _errors.close();
  }

  // ----------------------------------------------------------- mapping --

  static PoseReferenceFrame _frame(wire.PlatformPoseFrame f) => switch (f) {
    wire.PlatformPoseFrame.androidGameRotationVector =>
      PoseReferenceFrame.androidGameRotationVector,
    wire.PlatformPoseFrame.iosXArbitraryCorrectedZVertical =>
      PoseReferenceFrame.iosXArbitraryCorrectedZVertical,
  };

  static PoseSupport _support(wire.PoseCapabilities c) => PoseSupport(
    hasGyroscope: c.hasGyroscope,
    hasAccelerometer: c.hasAccelerometer,
    hasFusedRotation: c.hasFusedRotation,
    hasGravity: c.hasGravity,
    usesMagnetometer: c.usesMagnetometer,
    frame: _frame(c.frame),
    minDelayUs: c.minDelayUs,
    detail: c.detail,
    unsupportedReason: c.unsupportedReason,
  );

  static PlatformAttitudeSample _sample(wire.PlatformPoseSample s) =>
      PlatformAttitudeSample(
        deviceToReference: Quaternion(s.qx, s.qy, s.qz, s.qw),
        upDevice: Vector3(s.upX, s.upY, s.upZ),
        angularSpeedRadPerSec: s.angularSpeedRadPerSec,
        timestampUs: s.timestampUs,
        sequence: s.sequence,
        accuracy: s.accuracy,
      );
}

/// The `FlutterApi` half: everything the native side pushes without being
/// asked.
class _Callbacks implements wire.SpherePoseFlutterApi {
  _Callbacks(this._owner);

  final PigeonPosePlatform _owner;

  @override
  void onPoseSample(wire.PlatformPoseSample sample) =>
      _owner._samples.add(PigeonPosePlatform._sample(sample));

  @override
  void onPoseError(String code, String message) =>
      _owner._errors.add(PosePlatformError(code, message));
}
