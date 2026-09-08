import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../metadata/panorama_metadata.dart';
import '../utils/math_utils.dart';

/// Camera state and input handling for the 360° viewer.
///
/// The controller stores yaw/pitch/roll + zoom (expressed as vertical FOV
/// in radians) and is driven by the widget's gesture callbacks, an
/// optional auto-rotate, and [animateTo] transitions. All angles are
/// radians unless a parameter name says otherwise.
///
/// [yaw] is the **world** yaw of the view centre, in the sense Math §3 fixes:
/// yaw 0 is the session-start heading and is the middle column of the
/// equirect. That correspondence is not incidental — it is what lets the
/// viewer open at `PoseHeadingDegrees` without a second angular convention
/// existing anywhere, and `viewer_mapping_test.dart` pins it.
class SphereViewerController extends ChangeNotifier {
  /// Creates a controller looking at [initialYaw]/[initialPitch].
  SphereViewerController({
    double initialYaw = 0,
    double initialPitch = 0,
    double initialFovDegrees = 75,
    this.minFovDegrees = minimumFovDegrees,
    this.maxFovDegrees = maximumFovDegrees,
  }) : yaw = MathUtils.wrapPi(initialYaw),
       pitch = initialPitch.clamp(-maxPitch, maxPitch),
       fov = _clampFov(initialFovDegrees, minFovDegrees, maxFovDegrees),
       _homeYaw = MathUtils.wrapPi(initialYaw),
       _homePitch = initialPitch.clamp(-maxPitch, maxPitch),
       _homeFov = _clampFov(initialFovDegrees, minFovDegrees, maxFovDegrees);

  /// Phase 11 §3.2's lower zoom bound.
  ///
  /// Below 30° the source resolution runs out: a 6144-wide equirect gives
  /// ~17 px per degree, so a 30° field across a 1080-px-wide view is already
  /// magnifying past 1:1 and further zoom shows JPEG blocks rather than
  /// detail. It looks broken, and the thing it looks broken *at* is the
  /// stitcher.
  static const double minimumFovDegrees = 30;

  /// Phase 11 §3.2's upper zoom bound. Past 100° the rectilinear projection's
  /// corner stretching is unpleasant and reads as a lens fault.
  static const double maximumFovDegrees = 100;

  /// The pitch limit, ±90° exactly.
  ///
  /// The pole itself is reachable; what is not reachable is going past it.
  /// Rolling over the top leaves the horizon upside down, and a user who does
  /// it by accident has no idea what happened or how to undo it — the view
  /// simply stops making sense (§3.2).
  static const double maxPitch = math.pi / 2;

  /// Where the last [degrees] of approach to the pole resist the drag.
  ///
  /// The soft stop §3.2 asks for. A hard clamp makes the drag feel as though
  /// it stopped tracking the finger; resistance that grows toward the limit
  /// reads as the edge of the world, which is what it is.
  static const double softStopBandRadians = 0.35;

  /// World yaw of the view centre. Math §3's yaw: 0 is the image centre.
  double yaw;

  /// Pitch of the view centre; `+π/2` is the zenith.
  double pitch;

  /// Roll about the view axis. Only the gyro path sets it.
  double roll = 0;

  /// Vertical FOV in radians. Lower = zoomed in.
  double fov;

  /// Zoom-in bound in degrees.
  final double minFovDegrees;

  /// Zoom-out bound in degrees.
  final double maxFovDegrees;

  final double _homeYaw;
  final double _homePitch;
  final double _homeFov;

  double _velYaw = 0;
  double _velPitch = 0;

  double _autoRotateSpeed = 0;

  /// Auto-rotation speed in rad/s (positive pans the view). 0 = off.
  double get autoRotateSpeed => _autoRotateSpeed;

  set autoRotateSpeed(double value) {
    if (value == _autoRotateSpeed) return;
    _autoRotateSpeed = value;
    // Notifies because [needsTick] changes with it, and the widget starts and
    // stops its ticker off that. A plain field here would leave auto-rotate
    // switched on with nothing driving it — the button would appear to do
    // nothing at all.
    notifyListeners();
  }

  /// Whether auto-rotation is running.
  bool get isAutoRotating => _autoRotateSpeed != 0;

  /// Whether anything is still moving and the widget's ticker is needed.
  ///
  /// The viewer stops ticking when this is false. A panorama that is sitting
  /// still is the overwhelmingly common state — somebody looking at a defect
  /// is not dragging — and a ticker that wakes the raster thread 60 times a
  /// second to recompute nothing is pure battery cost on a device that is
  /// already being used all day on site.
  bool get needsTick =>
      isAnimating ||
      _autoRotateSpeed != 0 ||
      _velYaw.abs() > _velocityFloor ||
      _velPitch.abs() > _velocityFloor;

  /// Below this, an inertial velocity is treated as stopped.
  static const double _velocityFloor = 1e-5;

  // animateTo state.
  double _animT = 1;
  double _animDuration = 0;
  double _animFromYaw = 0, _animToYaw = 0;
  double _animFromPitch = 0, _animToPitch = 0;
  double _animFromFov = 0, _animToFov = 0;

  /// Whether an [animateTo] transition is in flight.
  bool get isAnimating => _animT < 1;

  /// A controller opening at the direction a panorama's metadata names.
  ///
  /// The whole of Phase 11 §3.2's "open at `PoseHeadingDegrees`". When the
  /// panorama knows which way its centre faces and the caller knows which way
  /// they want to look, the opening yaw is the difference between the two —
  /// and the sign flip in that subtraction is the interesting part, because a
  /// compass bearing increases clockwise while Math §3's yaw decreases. Getting
  /// it backwards gives a view that is right at 0° and 180° and wrong
  /// everywhere else, which is the hardest kind of wrong to notice.
  ///
  /// With no [lookAtCompassDegrees] the view opens at yaw 0, which is the
  /// session-start heading — still meaningful, just not north-referenced.
  factory SphereViewerController.forPanorama(
    PanoramaMetadata? metadata, {
    double? lookAtCompassDegrees,
    double initialPitch = 0,
    double initialFovDegrees = 75,
  }) {
    final centre = metadata?.heading.degrees;
    final yaw = (centre == null || lookAtCompassDegrees == null)
        ? 0.0
        : PanoramaMetadata.yawForCompassHeading(lookAtCompassDegrees, centre);
    return SphereViewerController(
      initialYaw: yaw,
      initialPitch: initialPitch,
      initialFovDegrees: initialFovDegrees,
    );
  }

  /// Applies a drag, in radians of view movement.
  ///
  /// The caller passes screen deltas scaled by its sensitivity, and the signs
  /// are §3.2's: dragging left turns the view right. Both conventions describe
  /// the same feel — the content follows the finger — and every panorama viewer
  /// on every platform behaves this way, so the one that does not feels broken
  /// rather than novel.
  void drag(double dxRadians, double dyRadians) {
    _animT = 1; // gestures cancel animations
    yaw = MathUtils.wrapPi(yaw + dxRadians);
    pitch = _applySoftStop(pitch, dyRadians);
    _velYaw = dxRadians;
    _velPitch = dyRadians;
    notifyListeners();
  }

  /// Adds [delta] to [pitch], resisting as the pole approaches.
  ///
  /// Inside [softStopBandRadians] of the limit, motion *toward* the pole is
  /// scaled down by how far into the band it already is, reaching zero exactly
  /// at ±90°. Motion away is never damped, so the view is never sticky — a user
  /// who hits the top can always come straight back.
  double _applySoftStop(double current, double delta) {
    if (delta == 0) return current;
    final towardPole = delta.sign == current.sign || current == 0;
    if (!towardPole) {
      return (current + delta).clamp(-maxPitch, maxPitch);
    }
    final remaining = maxPitch - current.abs();
    if (remaining <= 0) return current.sign * maxPitch;
    final resistance = remaining >= softStopBandRadians
        ? 1.0
        : remaining / softStopBandRadians;
    return (current + delta * resistance).clamp(-maxPitch, maxPitch);
  }

  /// Advances inertia, auto-rotation, and [animateTo] transitions. Called
  /// by the viewer widget's ticker every frame.
  void applyInertiaTick(double dtSeconds) {
    var dirty = false;

    if (_animT < 1) {
      _animT = (_animT + dtSeconds / _animDuration).clamp(0.0, 1.0);
      final t = _easeInOut(_animT);
      yaw = MathUtils.lerpAngle(_animFromYaw, _animToYaw, t);
      pitch = MathUtils.lerp(_animFromPitch, _animToPitch, t);
      fov = MathUtils.lerp(_animFromFov, _animToFov, t);
      dirty = true;
    }

    if (_autoRotateSpeed != 0 && _animT >= 1) {
      yaw = MathUtils.wrapPi(yaw + _autoRotateSpeed * dtSeconds);
      dirty = true;
    }

    if (_velYaw.abs() > _velocityFloor || _velPitch.abs() > _velocityFloor) {
      yaw = MathUtils.wrapPi(yaw + _velYaw);
      pitch = _applySoftStop(pitch, _velPitch);
      final decay = math.pow(0.94, dtSeconds * 60).toDouble();
      _velYaw *= decay;
      _velPitch *= decay;
      // Snapped to zero rather than left to decay forever. A velocity of 1e-9
      // moves nothing visible but keeps [needsTick] true, which would keep the
      // ticker running for the rest of the panorama's life — the exact cost
      // the demand-driven ticker exists to avoid.
      if (_velYaw.abs() <= _velocityFloor) _velYaw = 0;
      if (_velPitch.abs() <= _velocityFloor) _velPitch = 0;
      dirty = true;
    }

    if (dirty) notifyListeners();
  }

  /// Multiplies the zoom by [factor], clamped to the §3.2 bounds.
  void zoom(double factor) {
    if (factor <= 0 || !factor.isFinite) return;
    final minFov = minFovDegrees * math.pi / 180.0;
    final maxFov = maxFovDegrees * math.pi / 180.0;
    fov = (fov / factor).clamp(minFov, maxFov);
    notifyListeners();
  }

  /// The current zoom as a vertical field of view in degrees.
  double get fovDegrees => fov * 180.0 / math.pi;

  /// Smoothly animates the camera to the given orientation/zoom.
  void animateTo({
    double? yaw,
    double? pitch,
    double? fovDegrees,
    Duration duration = const Duration(milliseconds: 600),
  }) {
    _velYaw = 0;
    _velPitch = 0;
    _animFromYaw = this.yaw;
    _animFromPitch = this.pitch;
    _animFromFov = fov;
    _animToYaw = yaw ?? this.yaw;
    _animToPitch = (pitch ?? this.pitch).clamp(-maxPitch, maxPitch);
    _animToFov = fovDegrees != null
        ? _clampFov(fovDegrees, minFovDegrees, maxFovDegrees)
        : fov;
    _animDuration = math.max(duration.inMilliseconds / 1000.0, 1e-3);
    _animT = 0;
    // So the widget notices it has to start ticking; without this an animation
    // requested while the view is at rest never runs.
    notifyListeners();
  }

  /// Sets the orientation directly, without animation. The gyro path uses it.
  void setOrientation({double? yaw, double? pitch, double? roll}) {
    if (yaw != null) this.yaw = MathUtils.wrapPi(yaw);
    if (pitch != null) this.pitch = pitch.clamp(-maxPitch, maxPitch);
    if (roll != null) this.roll = roll;
    notifyListeners();
  }

  /// Returns to the orientation and zoom this controller opened at.
  void resetToHome() {
    roll = 0;
    animateTo(
      yaw: _homeYaw,
      pitch: _homePitch,
      fovDegrees: _homeFov * 180.0 / math.pi,
      duration: const Duration(milliseconds: 450),
    );
  }

  static double _clampFov(double degrees, double minDegrees, double maxDegrees) =>
      (degrees * math.pi / 180.0).clamp(
        minDegrees * math.pi / 180.0,
        maxDegrees * math.pi / 180.0,
      );

  static double _easeInOut(double t) =>
      t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2;
}
