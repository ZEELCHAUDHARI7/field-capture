import 'dart:math' as math;

import 'package:sphere_view/src/api/models/camera_intrinsics.dart';
import 'package:sphere_view/src/api/models/distortion_model.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart';

/// Brown–Conrady distortion, in both directions, plus the equirectangular
/// mapping expressed for a specific canvas size.
///
/// The frame conversions and the two mapping formulas themselves are **not**
/// here — they are in `SphericalConventions`, and this file calls them. That is
/// the point: Math §0 says a second copy of `atan2(d.x, d.z)` somewhere in the
/// tree is how mirrored panoramas happen, and a synthetic renderer that quietly
/// kept its own copy would be the most dangerous place of all for one, because
/// its errors would cancel against the stitcher's.
///
/// What the renderer legitimately needs beyond the conventions is the
/// *forward* distortion model. Undistortion is what a stitcher does; a lens
/// distorts, so the rig has to be able to go the other way, and by definition
/// nothing else in the tree does.
class Distorter {
  /// Creates a distorter for OpenCV-ordered coefficients.
  const Distorter(this.k1, this.k2, this.p1, this.p2, this.k3);

  /// No distortion at all — an ideal pinhole.
  static const Distorter identity = Distorter(0, 0, 0, 0, 0);

  /// Reads the coefficients out of a [DistortionModel], which for the rig is
  /// always the Brown–Conrady variant; iOS's lookup table is a capture-side
  /// concern and the rig has no reason to synthesise one.
  factory Distorter.from(DistortionModel? model) => switch (model) {
    BrownConradyDistortion m => Distorter(m.k1, m.k2, m.p1, m.p2, m.k3),
    null => identity,
    _ => throw ArgumentError(
      'the synthetic rig models Brown–Conrady only, got ${model.runtimeType}',
    ),
  };

  /// Second-order radial coefficient.
  final double k1;

  /// Fourth-order radial coefficient.
  final double k2;

  /// First tangential coefficient.
  final double p1;

  /// Second tangential coefficient.
  final double p2;

  /// Sixth-order radial coefficient.
  final double k3;

  /// True when this is the identity, so callers can skip the whole path.
  bool get isIdentity => k1 == 0 && k2 == 0 && p1 == 0 && p2 == 0 && k3 == 0;

  /// The model as Phase 01 stores it, for writing into `ground_truth.json`.
  BrownConradyDistortion toModel() =>
      BrownConradyDistortion(k1: k1, k2: k2, p1: p1, p2: p2, k3: k3);

  /// Ideal normalised point → the normalised point the lens actually puts it
  /// at. This is the direction OpenCV's coefficients are *defined* in, so no
  /// sign or convention flip is involved (Math §4.1).
  ({double x, double y}) distort(double x, double y) {
    final r2 = x * x + y * y;
    final radial = 1 + r2 * (k1 + r2 * (k2 + r2 * k3));
    return (
      x: x * radial + 2 * p1 * x * y + p2 * (r2 + 2 * x * x),
      y: y * radial + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y,
    );
  }

  /// Distorted normalised point → ideal, by fixed-point iteration.
  ///
  /// The rig renders *destination* pixels, so it needs this direction: given
  /// where a pixel sits on the distorted sensor, which ideal ray landed there.
  /// Brown–Conrady has no closed-form inverse; the same fixed-point iteration
  /// `cv::undistortPoints` uses converges in a handful of steps for the modest
  /// coefficients a phone lens has, and 12 is comfortably past the point where
  /// the update falls below a thousandth of a pixel.
  ({double x, double y}) undistort(double xd, double yd) {
    if (isIdentity) return (x: xd, y: yd);
    var x = xd;
    var y = yd;
    for (var i = 0; i < 12; i++) {
      final r2 = x * x + y * y;
      final radial = 1 + r2 * (k1 + r2 * (k2 + r2 * k3));
      final dx = 2 * p1 * x * y + p2 * (r2 + 2 * x * x);
      final dy = p1 * (r2 + 2 * y * y) + 2 * p2 * x * y;
      final nx = (xd - dx) / radial;
      final ny = (yd - dy) / radial;
      final step = (nx - x).abs() + (ny - y).abs();
      x = nx;
      y = ny;
      // A thousandth of a pixel at any sane focal length. For the mild
      // coefficients a phone lens has this trips after four or five passes;
      // the cap is there for coefficients that would not converge at all.
      if (step < 1e-9) break;
    }
    return (x: x, y: y);
  }
}

/// One camera: where it is pointing, what its intrinsics are, and how its lens
/// bends. Everything the rig needs to turn a pixel into a world ray.
class SyntheticCamera {
  /// Creates a camera with the given pose, intrinsics and lens.
  SyntheticCamera({
    required this.deviceToWorld,
    required this.intrinsics,
    required this.distortion,
  }) : _worldToDevice = deviceToWorld.transposed();

  /// Builds the camera the plan is asking for: aimed at ([yaw], [pitch]) with
  /// the screen upright.
  factory SyntheticCamera.aimedAt({
    required double yaw,
    required double pitch,
    required CameraIntrinsics intrinsics,
    Distorter distortion = Distorter.identity,
  }) => SyntheticCamera(
    deviceToWorld: SphericalConventions.aimingDeviceToWorld(yaw, pitch),
    intrinsics: intrinsics,
    distortion: distortion,
  );

  /// Rotation taking device-frame vectors to world, as `DevicePose` stores it.
  final Matrix3 deviceToWorld;

  /// The pinhole model, in this frame's pixel coordinates.
  final CameraIntrinsics intrinsics;

  /// The lens.
  final Distorter distortion;

  final Matrix3 _worldToDevice;

  /// The world direction that lands on pixel ([x], [y]) of the **distorted**
  /// image the sensor produces. Unit length.
  Vector3 rayForPixel(double x, double y) {
    final undistorted = distortion.undistort(
      (x - intrinsics.cx) / intrinsics.fx,
      (y - intrinsics.cy) / intrinsics.fy,
    );
    // Back to a pixel so the one true unprojection formula stays the one in
    // SphericalConventions; the round trip costs two multiplies and buys the
    // guarantee that the rig and the plan agree by construction.
    final ray = SphericalConventions.deviceRayForPixel(
      intrinsics,
      undistorted.x * intrinsics.fx + intrinsics.cx,
      undistorted.y * intrinsics.fy + intrinsics.cy,
    );
    return (deviceToWorld * ray as Vector3).normalized();
  }

  /// Pixel that world direction [direction] lands on, or `null` when it is
  /// behind the camera. The exact inverse of [rayForPixel].
  ({double x, double y})? pixelForRay(Vector3 direction) {
    final local = _worldToDevice.transformed(direction);
    final ideal = SphericalConventions.pixelForDeviceRay(intrinsics, local);
    if (ideal == null) return null;
    if (distortion.isIdentity) return ideal;
    final d = distortion.distort(
      (ideal.x - intrinsics.cx) / intrinsics.fx,
      (ideal.y - intrinsics.cy) / intrinsics.fy,
    );
    return (
      x: d.x * intrinsics.fx + intrinsics.cx,
      y: d.y * intrinsics.fy + intrinsics.cy,
    );
  }

  /// Whether [direction] falls inside the image rectangle.
  bool sees(Vector3 direction) {
    final p = pixelForRay(direction);
    return p != null &&
        p.x >= 0 &&
        p.x <= intrinsics.imageSize.width &&
        p.y >= 0 &&
        p.y <= intrinsics.imageSize.height;
  }

  /// The optical axis in world coordinates, computed once.
  late final Vector3 opticalAxis = deviceToWorld.transformed(Vector3(0, 0, -1));

  /// `cos θ` between the optical axis and a **unit** [direction].
  ///
  /// The cosine rather than the angle, because every caller wants the cosine:
  /// the vignette is `cos⁴θ`, and going out to an angle and back through
  /// `cos` costs an `acos` per pixel to arrive at the number the dot product
  /// already was.
  double cosineFromAxis(Vector3 direction) =>
      opticalAxis.dot(direction).clamp(-1.0, 1.0);
}

/// Equirectangular pixel coordinates for a canvas of a fixed size.
///
/// Thin on purpose: it holds the canvas dimensions so callers stop passing them
/// around, and forwards to `SphericalConventions` for the arithmetic.
class EquirectCanvas {
  /// Creates a canvas [width] × [height]; equirect output is always 2:1.
  EquirectCanvas(this.width, this.height);

  /// Creates a 2:1 canvas from its width.
  EquirectCanvas.fromWidth(int width) : this(width, width ~/ 2);

  /// Canvas width in pixels; the full 360° of yaw.
  final int width;

  /// Canvas height in pixels; the full 180° of pitch.
  final int height;

  /// Pixel a unit world direction maps to, `x = W(½ − yaw/2π)`,
  /// `y = H(½ − pitch/π)` (Math §3).
  ({double x, double y}) pixelForDirection(Vector3 direction) {
    final yaw = SphericalConventions.yawOf(direction);
    final pitch = SphericalConventions.pitchOf(direction);
    return (
      x: SphericalConventions.xForYaw(yaw, width.toDouble()),
      y: SphericalConventions.yForPitch(pitch, height.toDouble()),
    );
  }

  /// Unit world direction for a canvas pixel — the inverse of
  /// [pixelForDirection].
  Vector3 directionForPixel(double x, double y) =>
      SphericalConventions.directionOf(
        SphericalConventions.yawForX(x, width.toDouble()),
        SphericalConventions.pitchForY(y, height.toDouble()),
      );

  /// Solid angle of the pixel row at [y], relative to the equator's — `cos θ`.
  ///
  /// Every area-weighted number the metrics report (coverage, SSIM's excluded
  /// fraction) uses this. Without it the poles, which are a handful of square
  /// degrees, would carry as much weight as the entire equatorial band, and a
  /// coverage percentage would stop meaning "fraction of the sphere".
  double rowSolidAngleWeight(int y) =>
      math.cos(SphericalConventions.pitchForY(y + 0.5, height.toDouble()));
}
