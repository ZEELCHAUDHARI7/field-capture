import 'package:vector_math/vector_math_64.dart';

import 'pose_frame_conversion.dart';
import 'pose_source.dart';

/// Which clock a raw attitude sample's timestamp is on.
///
/// §6 pitfall 1: `SensorEvent.timestamp`'s base "varies by device" — usually
/// `elapsedRealtimeNanos`, but not universally. Phase 06's camera-side
/// `TimestampMapper` already *assumed* the usual case when it declared the
/// `REALTIME` offset to be exactly zero; this is where that assumption stops
/// being inherited and starts being measured. If it is wrong, the two clocks
/// disagree by however long the device has been asleep since boot — which is
/// not a subtle error, but it is a completely silent one.
enum PoseClockBase {
  /// `SensorEvent.timestamp` is `SystemClock.elapsedRealtimeNanos()`, the same
  /// base Phase 06 puts camera frames on. The offset is zero, exactly.
  androidElapsedRealtime,

  /// `SensorEvent.timestamp` is `System.nanoTime()` — pitfall 1's device. The
  /// offset is real, device-specific, and measured.
  androidMonotonicNanoTime,

  /// `CMDeviceMotion.timestamp`, on `systemUptime`, which is exactly what
  /// Phase 06's iOS `TimestampMapper` converts sample buffers onto.
  iosSystemUptime,
}

/// How pose timestamps were reconciled with the camera's.
class PoseClock {
  /// Creates a clock record.
  const PoseClock({
    required this.base,
    required this.offsetUs,
    required this.uncertaintyUs,
    required this.note,
  });

  /// The clock raw samples arrive on.
  final PoseClockBase base;

  /// Added to a raw sample timestamp to reach the shared motion clock.
  final int offsetUs;

  /// Bound on that estimate; zero when nothing needed estimating.
  final int uncertaintyUs;

  /// Plain-language description of what was done.
  final String note;

  /// Whether the two clocks were the same clock and no estimate was involved.
  bool get isExact => base != PoseClockBase.androidMonotonicNanoTime;

  /// Serialised into the bundle's `device_info`.
  Map<String, Object?> toJson() => {
    'base': base.name,
    'offset_us': offsetUs,
    'uncertainty_us': uncertaintyUs,
    'is_exact': isExact,
    'note': note,
  };

  @override
  String toString() =>
      'PoseClock(${base.name}, offset $offsetUs µs ±$uncertaintyUs µs)';
}

/// What starting the attitude stream settled.
class PoseStreamStart {
  /// Creates a stream description.
  const PoseStreamStart({
    required this.frame,
    required this.clock,
    required this.samplingPeriod,
    required this.minDelayUs,
    required this.note,
  });

  /// The reference frame the samples' quaternions are against.
  final PoseReferenceFrame frame;

  /// How the sample clock relates to the camera's.
  final PoseClock clock;

  /// The period actually requested of the platform.
  final Duration samplingPeriod;

  /// The floor the platform imposes on it; `0` when unreported.
  final int minDelayUs;

  /// Anything worth recording about how the stream was configured.
  final String note;

  /// Serialised into `device_info`.
  Map<String, Object?> toJson() => {
    'frame': frame.name,
    'sampling_period_us': samplingPeriod.inMicroseconds,
    'min_delay_us': minDelayUs,
    'clock': clock.toJson(),
    'note': note,
  };

  @override
  String toString() =>
      'PoseStreamStart(${frame.name}, '
      '${samplingPeriod.inMicroseconds}µs, $clock)';
}

/// One attitude sample exactly as the platform reported it — no frame
/// conversion applied.
class PlatformAttitudeSample {
  /// Creates a raw sample.
  PlatformAttitudeSample({
    required Quaternion deviceToReference,
    required Vector3 upDevice,
    required this.angularSpeedRadPerSec,
    required this.timestampUs,
    required this.sequence,
    required this.accuracy,
  }) : deviceToReference = deviceToReference.clone(),
       upDevice = upDevice.clone();

  /// Device→reference rotation, in the frame [PoseStreamStart.frame] names.
  final Quaternion deviceToReference;

  /// Unit vector in the **device** frame pointing away from the earth.
  ///
  /// Normalised natively because the two platforms disagree on magnitude *and*
  /// sign — Android `TYPE_GRAVITY` reads `(0, 0, +9.81)` with the device flat
  /// on its back, iOS `CMDeviceMotion.gravity` reads `(0, 0, −1)` in the same
  /// pose. It is not taken on trust: `PlatformAhrsPoseSource` checks that this
  /// rotates to world up, and refuses to start when it does not.
  final Vector3 upDevice;

  /// `|ω|` from the gyroscope, rad/s. A magnitude because it is
  /// frame-invariant, which keeps one more sign convention off the wire.
  final double angularSpeedRadPerSec;

  /// Sample instant on the shared motion clock.
  final int timestampUs;

  /// Monotonic counter from the start of the stream, so a gap in *delivery* is
  /// distinguishable from a gap in *sampling*.
  final int sequence;

  /// Android `SensorEvent.accuracy`; `-1` on iOS, which has no equivalent.
  final int accuracy;

  @override
  String toString() =>
      'PlatformAttitudeSample(#$sequence, $timestampUs µs, '
      '${angularSpeedRadPerSec.toStringAsFixed(3)} rad/s)';
}

/// An asynchronous failure of the attitude stream.
class PosePlatformError {
  /// Creates an error record.
  const PosePlatformError(this.code, this.message);

  /// Stable machine-readable code.
  final String code;

  /// Human-readable detail.
  final String message;

  @override
  String toString() => 'PosePlatformError($code): $message';
}

/// The host-side motion interface.
///
/// Deliberately separate from `SphereCameraPlatform`: the pose stream outlives
/// any one camera session — §6 pitfall 5 says never to reset the buffer between
/// targets — and it has to keep running while the camera is closed and
/// reopened. Two interfaces make that independence structural rather than a
/// convention someone has to remember.
///
/// Implemented for real by `PigeonPosePlatform` over the generated channel, and
/// by fakes in tests. Everything above this seam — the frame conversion, the
/// warm-up, the yaw datum, the gravity check — is therefore testable on a
/// laptop, which is the whole point given that §2 says the platform docs cannot
/// be trusted and the conversion has to be pinned by experiment.
abstract class SpherePosePlatform {
  /// What this device's motion hardware can do, and why not when it cannot.
  Future<PoseSupport> capabilities();

  /// Starts the stream at [samplingPeriod].
  ///
  /// Throws [PoseSourceUnsupported] on a device that cannot be supported, so
  /// the refusal cannot be missed by a caller that skipped [capabilities].
  Future<PoseStreamStart> start(Duration samplingPeriod);

  /// Stops the stream and releases the sensors.
  Future<void> stop();

  /// Raw samples, unconverted.
  Stream<PlatformAttitudeSample> get samples;

  /// Failures that arrive outside a pending call.
  Stream<PosePlatformError> get errors;
}
