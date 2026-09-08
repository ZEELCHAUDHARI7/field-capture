import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../../utils/quaternion_utils.dart';
import '../../utils/spherical_conventions.dart';
import 'json_codec.dart';

/// The device's orientation at one instant, stamped with the clock the camera
/// stamps its frames with.
///
/// This type exists to make the architecture's central idea representable: the
/// IMU is a **prior, not a measurement** (§6.1). The previous implementation
/// trusted an orientation good to ±2–5°, which at a 6144-wide equirect is
/// 35–85 px of misregistration on every seam — no blend hides that. Here the
/// same numbers do three jobs instead: they decide which image pairs are worth
/// matching (turning O(n²) into O(n·k)), they seed bundle adjustment into the
/// right basin, and [gravityWorld] supplies the gravity axis so OpenCV's
/// `waveCorrect` heuristic is never called (Math §7). Bundle adjustment then
/// overwrites the rotation with a photometrically-correct one.
class DevicePose {
  /// Creates a pose. [deviceToWorld] must already be a unit quaternion; it is
  /// stored as a defensive copy but deliberately **not** re-normalised, so
  /// that `fromJson(toJson(p)) == p` holds bit-exactly.
  DevicePose({
    required Quaternion deviceToWorld,
    required Vector3 gravityWorld,
    required this.timestampUs,
    required this.angularSpeedRadPerSec,
  }) : deviceToWorld = deviceToWorld.clone(),
       gravityWorld = gravityWorld.clone();

  /// Rotation taking a vector expressed in the device frame `D` to the world
  /// frame `W` (Math §2). Treat as immutable — do not mutate in place.
  final Quaternion deviceToWorld;

  /// Measured world-space up, from the accelerometer.
  ///
  /// Separate from [deviceToWorld] because it is what pins bundle adjustment's
  /// 3-DOF gauge freedom: Kabsch against these vectors levels the panorama with
  /// data rather than with a guess (Math §7). Treat as immutable.
  final Vector3 gravityWorld;

  /// Capture instant on the platform's **monotonic** clock, in microseconds.
  ///
  /// The single most important field in this class. It must share a clock base
  /// with the camera's frame timestamps: at a realistic 60°/s pan, being wrong
  /// by tens of milliseconds is 1–2° of pose error, which is larger than
  /// everything bundle adjustment is trying to fix. Phase 07 owns proving the
  /// two clocks agree.
  final int timestampUs;

  /// Angular speed at [timestampUs], for the steadiness gate and for the
  /// rolling-shutter-skew check. Recorded per shot so a soft frame can be
  /// explained rather than guessed at.
  final double angularSpeedRadPerSec;

  /// The optical axis in world coordinates: the device frame looks along `−Z`.
  ///
  /// Via [QuaternionUtils.rotate] rather than `Quaternion.rotated`, which in
  /// `vector_math` applies the *inverse* rotation — see that method's doc. The
  /// two disagree for every pose that is not a half turn, and because
  /// [toOpenCvRotation] goes through `asRotationMatrix`, using `rotated` here
  /// would have this class report a yaw of the opposite sign to the rotation it
  /// hands the stitcher.
  Vector3 get forward =>
      QuaternionUtils.rotate(deviceToWorld, Vector3(0, 0, -1));

  /// Heading of [forward], `atan2(d.x, d.z)`, relative to the session-start
  /// direction (Math §3).
  double get yaw => SphericalConventions.yawOf(forward);

  /// Elevation of [forward], `asin(d.y)` (Math §3).
  double get pitch => SphericalConventions.pitchOf(forward);

  /// Row-major 3×3, already converted to the OpenCV camera→panorama frame
  /// (Math §2). This is the only form the native side ever sees.
  List<double> toOpenCvRotation() =>
      SphericalConventions.openCvRotationFromDeviceToWorld(deviceToWorld);

  /// Serialises to the JSON stored in `bundle.json` and sent over the ABI.
  Map<String, Object?> toJson() => {
    'qx': deviceToWorld.x,
    'qy': deviceToWorld.y,
    'qz': deviceToWorld.z,
    'qw': deviceToWorld.w,
    'gravity_x': gravityWorld.x,
    'gravity_y': gravityWorld.y,
    'gravity_z': gravityWorld.z,
    'timestamp_us': timestampUs,
    'angular_speed_rad_per_sec': angularSpeedRadPerSec,
  };

  /// Inverse of [toJson].
  factory DevicePose.fromJson(Map<String, Object?> json) {
    const ctx = 'DevicePose';
    return DevicePose(
      deviceToWorld: Quaternion(
        jsonDouble(json, 'qx', context: ctx),
        jsonDouble(json, 'qy', context: ctx),
        jsonDouble(json, 'qz', context: ctx),
        jsonDouble(json, 'qw', context: ctx),
      ),
      gravityWorld: Vector3(
        jsonDouble(json, 'gravity_x', context: ctx),
        jsonDouble(json, 'gravity_y', context: ctx),
        jsonDouble(json, 'gravity_z', context: ctx),
      ),
      timestampUs: jsonInt(json, 'timestamp_us', context: ctx),
      angularSpeedRadPerSec: jsonDouble(
        json,
        'angular_speed_rad_per_sec',
        context: ctx,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DevicePose &&
      other.timestampUs == timestampUs &&
      other.angularSpeedRadPerSec == angularSpeedRadPerSec &&
      other.deviceToWorld.x == deviceToWorld.x &&
      other.deviceToWorld.y == deviceToWorld.y &&
      other.deviceToWorld.z == deviceToWorld.z &&
      other.deviceToWorld.w == deviceToWorld.w &&
      other.gravityWorld.x == gravityWorld.x &&
      other.gravityWorld.y == gravityWorld.y &&
      other.gravityWorld.z == gravityWorld.z;

  @override
  int get hashCode => Object.hash(
    deviceToWorld.x,
    deviceToWorld.y,
    deviceToWorld.z,
    deviceToWorld.w,
    gravityWorld.x,
    gravityWorld.y,
    gravityWorld.z,
    timestampUs,
    angularSpeedRadPerSec,
  );

  @override
  String toString() =>
      'DevicePose(t: ${timestampUs}us, '
      'yaw: ${(yaw * 180 / math.pi).toStringAsFixed(1)}°, '
      'pitch: ${(pitch * 180 / math.pi).toStringAsFixed(1)}°)';
}
