import '../api/models/capture_bundle.dart';
import '../api/models/sphere_capture_config.dart';

/// Why a captured position was rejected, so the UI can say something specific.
enum FrameRejection {
  /// Laplacian variance below `SphereCaptureConfig.minSharpness`.
  blurred,

  /// The device was still turning fast enough to skew the rolling shutter.
  moving,

  /// No pose could be interpolated to the shutter timestamp — the buffer did
  /// not bracket it, so pairing this frame with any pose would be a guess.
  noPoseAtShutter,

  /// The bracket came back with fewer frames than requested.
  incompleteBracket,

  /// The frame on disk could not be decoded, so it is not a photograph yet.
  ///
  /// A truncated or empty write is reachable: the iOS writer discards the result
  /// of `data.write(to:)` and cannot report a partial one. It used to be scored as
  /// *infinitely sharp* — `Sharpness.ofFile` returns null exactly when the bytes
  /// will not decode, and the null became `double.infinity`, which passes every
  /// sharpness threshold there is. So the position was accepted, written into
  /// `bundle.json`, and failed the entire stitch an hour later with SV_ERR_IO,
  /// having taken the other twenty-eight frames with it.
  unreadableFrame,
}

/// The sentence to show for each rejection, written for a construction manager
/// standing on a site rather than for a developer reading a log.
extension FrameRejectionMessage on FrameRejection {
  /// Plain-language explanation, including what to do about it.
  String get message => switch (this) {
    FrameRejection.blurred => 'Too blurry — hold still',
    FrameRejection.moving => 'Still moving — hold still',
    FrameRejection.noPoseAtShutter =>
      'Lost track of the tablet at that shutter — try again',
    FrameRejection.incompleteBracket =>
      'The camera returned fewer photos than asked for — try again',
    FrameRejection.unreadableFrame =>
      'That photo did not save properly — try again',
  };
}

/// Accepts a captured position or sends the user back to re-shoot it.
///
/// Exists so that rejection happens at the one moment it is cheap. Every defect
/// this gate catches is unfixable later and expensive later: a blurred frame is
/// discovered during a 60 s stitch, and by then the user has walked to the next
/// station. Catching it here costs a three-second re-prompt.
///
/// Note what is *not* relaxed anywhere. The shutter gate widens its aim
/// tolerance for a target the user cannot reach (§4), because a worse seed is
/// still a seed. Nothing widens these: a blurred or skewed frame damages the
/// stitch rather than merely weakening it, so the only correct response is to
/// shoot it again.
class FrameGate {
  /// Creates a gate for [config].
  const FrameGate(this.config);

  /// The thresholds in force.
  final SphereCaptureConfig config;

  /// Returns the reason [position] must be re-shot, or `null` to accept it.
  ///
  /// [expectedShotCount] defaults to what [config] asks for, and must be
  /// overridden with what was actually *requested* on a device whose bracket
  /// the exposure controller had to trim — a single-shot camera returning one
  /// frame has done everything asked of it, and failing it as an incomplete
  /// bracket would make such a device unable to capture anything at all.
  FrameRejection? evaluate(CapturedPosition position, {int? expectedShotCount}) {
    final expected = expectedShotCount ?? config.exposure.shotsPerPosition;
    if (position.shots.length < expected) {
      return FrameRejection.incompleteBracket;
    }
    // Steadiness before sharpness: both reject, but this one names the cause,
    // and a frame shot while turning is skewed by the rolling shutter whether
    // or not it also happens to read sharp.
    if (position.steadinessRadPerSec >= config.steadinessThresholdRadPerSec) {
      return FrameRejection.moving;
    }
    if (position.sharpness < config.minSharpness) {
      return FrameRejection.blurred;
    }
    return null;
  }
}
