import 'dart:math' as math;

/// Small angular / geometric helpers used across the package.
///
/// All angles are expressed in radians unless otherwise noted.
class MathUtils {
  MathUtils._();

  /// Wraps [angle] into the range `[-pi, pi]`.
  static double wrapPi(double angle) {
    var a = (angle + math.pi) % (2 * math.pi);
    if (a < 0) a += 2 * math.pi;
    return a - math.pi;
  }

  /// Wraps [angle] into `[0, 2*pi)`.
  static double wrapTwoPi(double angle) {
    final a = angle % (2 * math.pi);
    return a < 0 ? a + 2 * math.pi : a;
  }

  /// Great-circle angular distance between two unit direction vectors.
  static double angularDistance(
    double x1,
    double y1,
    double z1,
    double x2,
    double y2,
    double z2,
  ) {
    final dot = (x1 * x2 + y1 * y2 + z1 * z2).clamp(-1.0, 1.0);
    return math.acos(dot);
  }

  /// Converts spherical `(yaw, pitch)` to a unit direction vector.
  ///
  /// Yaw is measured around the world-up axis (Y), pitch around the world-x
  /// axis (positive pitch tilts up).
  static List<double> sphericalToVector(double yaw, double pitch) {
    final cp = math.cos(pitch);
    return [math.sin(yaw) * cp, math.sin(pitch), math.cos(yaw) * cp];
  }

  /// Linear interpolation.
  static double lerp(double a, double b, double t) => a + (b - a) * t;

  /// Shortest-angle interpolation between two angles.
  static double lerpAngle(double a, double b, double t) {
    final delta = wrapPi(b - a);
    return a + delta * t;
  }
}
