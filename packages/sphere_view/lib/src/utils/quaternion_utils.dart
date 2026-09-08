import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Convenience helpers on top of `vector_math`'s [Quaternion].
class QuaternionUtils {
  QuaternionUtils._();

  /// Builds a quaternion from Tait–Bryan yaw/pitch/roll angles (radians).
  ///
  /// Rotation order is `Y (yaw) * X (pitch) * Z (roll)`, matching the
  /// convention used by the guidance engine (yaw ≈ compass heading).
  static Quaternion fromYawPitchRoll(double yaw, double pitch, double roll) {
    final qy = Quaternion.axisAngle(Vector3(0, 1, 0), yaw);
    final qx = Quaternion.axisAngle(Vector3(1, 0, 0), pitch);
    final qz = Quaternion.axisAngle(Vector3(0, 0, 1), roll);
    return qy * qx * qz;
  }

  /// Extracts yaw/pitch/roll (radians) from a rotation quaternion.
  static ({double yaw, double pitch, double roll}) toYawPitchRoll(
    Quaternion q,
  ) {
    // Normalize just in case; the caller may have accumulated drift.
    final n = q.clone()..normalize();
    final w = n.w, x = n.x, y = n.y, z = n.z;

    final sinp = 2 * (w * x - y * z);
    final pitch = sinp.abs() >= 1
        ? (sinp > 0 ? math.pi / 2 : -math.pi / 2)
        : math.asin(sinp);

    final yaw = math.atan2(2 * (w * y + x * z), 1 - 2 * (x * x + y * y));
    final roll = math.atan2(2 * (w * z + x * y), 1 - 2 * (x * x + z * z));
    return (yaw: yaw, pitch: pitch, roll: roll);
  }

  /// Spherical linear interpolation between [a] and [b] by [t] in `[0, 1]`.
  static Quaternion slerp(Quaternion a, Quaternion b, double t) {
    final result = a.clone();
    // vector_math ships slerp on Quaternion via `Quaternion.setFromSlerp`
    // in some versions; fall back to a manual implementation for portability.
    var ax = a.x, ay = a.y, az = a.z, aw = a.w;
    var bx = b.x, by = b.y, bz = b.z, bw = b.w;
    var dot = ax * bx + ay * by + az * bz + aw * bw;
    if (dot < 0) {
      bx = -bx;
      by = -by;
      bz = -bz;
      bw = -bw;
      dot = -dot;
    }
    if (dot > 0.9995) {
      final rx = ax + t * (bx - ax);
      final ry = ay + t * (by - ay);
      final rz = az + t * (bz - az);
      final rw = aw + t * (bw - aw);
      result.setValues(rx, ry, rz, rw);
      result.normalize();
      return result;
    }
    final theta0 = math.acos(dot);
    final theta = theta0 * t;
    final sinTheta = math.sin(theta);
    final sinTheta0 = math.sin(theta0);
    final s0 = math.cos(theta) - dot * sinTheta / sinTheta0;
    final s1 = sinTheta / sinTheta0;
    result.setValues(
      ax * s0 + bx * s1,
      ay * s0 + by * s1,
      az * s0 + bz * s1,
      aw * s0 + bw * s1,
    );
    return result;
  }

  /// Rotates a direction by [q] — the standard active rotation `v' = q v q⁻¹`,
  /// inlined.
  ///
  /// **Use this, never `Quaternion.rotated`.** `vector_math` is internally
  /// inconsistent about which direction a quaternion turns things: for the same
  /// `q`, `q.asRotationMatrix().transformed(v)` and `q.rotated(v)` differ by a
  /// transpose, i.e. by the *inverse rotation*. Demonstrably —
  /// `Quaternion.axisAngle(Vector3(0,1,0), π/2)` should carry `+Z` to `+X` by
  /// the right-hand rule, and `asRotationMatrix` does, while `rotated` returns
  /// `−X`. `fromRotation` and `asRotationMatrix` are a consistent pair, so
  /// `rotated` is the single odd one out.
  ///
  /// That matters here more than it would in most codebases. `DevicePose`
  /// hands the *matrix* form to the native stitcher and the *quaternion* form
  /// to the guidance engine and the viewer, so mixing the two conventions
  /// produces a package whose stitched panorama and whose on-screen yaw
  /// disagree about which way the user turned — the mirrored-panorama family of
  /// bug that `01_MATH_AND_CONVENTIONS.md` opens by warning about, and one that
  /// hides perfectly because each component is self-consistent.
  ///
  /// `test/conventions_test.dart` pins the difference so it cannot silently
  /// change under a `vector_math` upgrade.
  static Vector3 rotate(Quaternion q, Vector3 v) {
    final x = q.x, y = q.y, z = q.z, w = q.w;
    final vx = v.x, vy = v.y, vz = v.z;
    // t = 2 * cross(q.xyz, v)
    final tx = 2 * (y * vz - z * vy);
    final ty = 2 * (z * vx - x * vz);
    final tz = 2 * (x * vy - y * vx);
    return Vector3(
      vx + w * tx + (y * tz - z * ty),
      vy + w * ty + (z * tx - x * tz),
      vz + w * tz + (x * ty - y * tx),
    );
  }
}
