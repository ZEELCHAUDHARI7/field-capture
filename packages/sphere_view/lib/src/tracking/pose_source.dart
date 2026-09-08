import '../api/models/device_pose.dart';
import 'pose_frame_conversion.dart';

/// What a device's motion hardware can do, and — when it cannot — why.
///
/// A value type rather than a bool because the refusal has to carry a sentence
/// somebody on a site can act on. "Not supported" sends a manager back to the
/// office; "this tablet has no gyroscope, so a 360 cannot be captured on it —
/// use a device with one" sends them to the right tablet.
class PoseSupport {
  /// Creates a support record.
  const PoseSupport({
    required this.hasGyroscope,
    required this.hasAccelerometer,
    required this.hasFusedRotation,
    required this.hasGravity,
    required this.usesMagnetometer,
    required this.frame,
    required this.minDelayUs,
    required this.detail,
    this.unsupportedReason,
  });

  /// The one hard requirement (§6 pitfall 3).
  final bool hasGyroscope;

  /// Needed for the gravity lock that keeps pitch and roll drift-free.
  final bool hasAccelerometer;

  /// Whether the fused magnetometer-free attitude source exists —
  /// `TYPE_GAME_ROTATION_VECTOR` / `CMDeviceMotion`.
  final bool hasFusedRotation;

  /// Whether a fused gravity vector is available.
  final bool hasGravity;

  /// **Expected to be false.** A true here means the build reached for
  /// `TYPE_ROTATION_VECTOR` or `.xTrueNorthZVertical`, which is the exact
  /// failure Math §1.1 rejects the magnetometer to avoid: indoors, rebar and
  /// steel studs bend magnetic heading by tens of degrees, and an aim gate
  /// needing ~5° would never fire.
  final bool usesMagnetometer;

  /// The frame this device's attitude quaternions are expressed against.
  final PoseReferenceFrame frame;

  /// The fastest the attitude source will run, µs between samples; `0` when the
  /// platform does not say.
  final int minDelayUs;

  /// Plain-language description of what was found. Goes into `bundle.json`.
  final String detail;

  /// Non-null exactly when this device cannot be supported.
  final String? unsupportedReason;

  /// Whether a capture session may proceed.
  bool get isSupported => unsupportedReason == null;

  /// Serialised into the bundle's `device_info`, so a panorama with an odd
  /// pose track can be explained years later rather than guessed at.
  Map<String, Object?> toJson() => {
    'has_gyroscope': hasGyroscope,
    'has_accelerometer': hasAccelerometer,
    'has_fused_rotation': hasFusedRotation,
    'has_gravity': hasGravity,
    'uses_magnetometer': usesMagnetometer,
    'frame': frame.name,
    'min_delay_us': minDelayUs,
    'detail': detail,
    'unsupported_reason': unsupportedReason,
  };

  @override
  String toString() => unsupportedReason == null
      ? 'PoseSupport(${frame.name}, min ${minDelayUs}us)'
      : 'PoseSupport(unsupported: $unsupportedReason)';
}

/// Thrown when a device cannot produce usable poses at all.
///
/// Phase 12 §1 refuses such a device at the **feature entry point**, before the
/// camera opens. Pretending otherwise wastes a site visit: without a gyroscope
/// there is no attitude source that tracks a pan, so every frame would be
/// seeded from accelerometer tilt with no heading at all, and the failure would
/// only become visible after the manager had walked the whole building.
class PoseSourceUnsupported implements Exception {
  /// Creates the refusal.
  const PoseSourceUnsupported(this.support);

  /// What was found, including the reason and the plain-language detail.
  final PoseSupport support;

  /// The message to show the user.
  String get message =>
      support.unsupportedReason ?? 'this device cannot provide device poses';

  @override
  String toString() => 'PoseSourceUnsupported: $message';
}

/// A stream of device orientations on a clock the camera also stamps with.
///
/// An interface rather than a class because the pose source is the one part of
/// the capture path most likely to be swapped: the synthetic rig of Phase 02
/// replays recorded poses through this same seam, which is what lets the
/// stitcher be tuned on a desktop in seconds instead of at a site.
///
/// The contract that matters is the clock. `DevicePose.timestampUs` must share
/// a base with the camera's frame timestamps — at a realistic 60°/s pan, a
/// 20 ms discrepancy is 1.2° of pose error, larger than the entire budget
/// bundle adjustment is working within.
abstract class PoseSource {
  /// Whether this device can be supported at all.
  ///
  /// A device with no gyroscope cannot produce usable poses by any means, and
  /// the feature is refused at its entry point rather than allowed to produce a
  /// bad panorama (Phase 12 §1).
  Future<bool> get isSupported;

  /// The full capability record behind [isSupported], including the reason a
  /// device was refused and the detail that goes into the bundle.
  Future<PoseSupport> get support;

  /// Orientations at the highest rate the platform will give, typically 100 Hz.
  Stream<DevicePose> get poses;

  /// Starts sampling. Yaw 0 is fixed at the first sample — the world frame's
  /// `+Z` is "wherever the user was pointing when the session began" (Math
  /// §1.1).
  ///
  /// Throws [PoseSourceUnsupported] on a device that cannot be supported.
  Future<void> start();

  /// Stops sampling and releases the sensor.
  Future<void> stop();
}
