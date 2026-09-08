import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../api/models/camera_intrinsics.dart';
import '../api/models/distortion_model.dart';
import 'quaternion_utils.dart';

/// The one place the conventions of `phases/01_MATH_AND_CONVENTIONS.md` become
/// code.
///
/// It exists so that no other file in either language ever writes a mapping
/// formula or a frame conversion by hand. That document opens by saying
/// mismatched conventions between the planner, the tracker, the stitcher and
/// the viewer are the single most common cause of mirrored, upside-down or
/// 90°-rotated panoramas, and that the bugs are maddening because each
/// component looks correct in isolation. A second copy of `atan2(d.x, d.z)`
/// somewhere else in the tree is exactly how that happens, so there is one
/// copy, here, and `test/conventions_test.dart` pins it against hand-computed
/// values.
///
/// Frames, all right-handed (§1):
///
/// - **W** world — `+Y` up (anti-gravity), `+Z` the heading at session start.
/// - **D** device — ARKit/OpenGL: `+X` right, `+Y` up the screen, camera looks
///   along `−Z`.
/// - **C** OpenCV camera — `+X` right, `+Y` down, `+Z` forward.
/// - **P** OpenCV panorama — `+X` right, `+Y` down, `+Z` forward.
class SphericalConventions {
  const SphericalConventions._();

  /// `C = N · D`, `N = diag(1, −1, −1)` — 180° about X, and its own inverse
  /// (§2).
  static const List<double> deviceToOpenCvCameraDiagonal = [1.0, -1.0, -1.0];

  /// `P = M · W`, `M = diag(−1, −1, 1)` — 180° about Z, and its own inverse
  /// (§2).
  static const List<double> worldToOpenCvPanoDiagonal = [-1.0, -1.0, 1.0];

  /// Clockwise quarter turns that carry the **capture** frame onto the
  /// **device** frame, from the frame's shape and the sensor's mounting.
  ///
  /// The capture stream is the sensor's, the device frame is the portrait-locked
  /// screen's, and on most phones and tablets the two are a quarter turn apart.
  /// This is the only place that turn is decided. Three things read it and they
  /// must not disagree, because each hides the others' error: the intrinsics the
  /// plan is built from, the preview texture the user aims with, and the seed
  /// roll the stitcher applies.
  ///
  /// The frame's own shape decides *whether* to turn, and the mounting decides
  /// *which way*. That order matters: iOS reports a 0° sensor orientation while
  /// still delivering landscape photos, so the mounting angle alone would say
  /// "no turn" on exactly the platform that needs one.
  static int captureToDeviceQuarterTurns({
    required bool landscapeCapture,
    required int sensorOrientationDegrees,
  }) {
    // A frame that is already portrait is already in the device frame, whatever
    // the mounting angle says about the sensor behind it — the platform has
    // rotated it on the way out, and turning it again would undo that.
    if (!landscapeCapture) return 0;
    // Landscape, so it does need turning, and the mounting angle says how far.
    // This is the standard Android formula: a buffer from a sensor mounted `θ`
    // off the display needs `θ` of clockwise rotation to stand up on a portrait
    // screen.
    //
    // It used to be `!= 270 ? 1 : 3`, which is right for 90 and 270 and quietly
    // wrong for 180 — a half-turn mounting got a quarter turn. Rare, and "rare" is
    // not a reason to encode it wrongly.
    final degrees = ((sensorOrientationDegrees % 360) + 360) % 360;
    if (degrees != 0) return (degrees ~/ 90) % 4;
    // A reported 0 with a landscape frame is iOS, which delivers the sensor's
    // landscape buffer and describes its mounting as 0 regardless. The frame's own
    // shape is the only signal left, and it is enough: portrait screen, landscape
    // buffer, one turn.
    return 1;
  }

  /// Quarter turns from the **device** frame to the **capture** frame — the
  /// `captureQuarterTurns` the native stitcher rolls its IMU seeds by.
  ///
  /// The inverse of [captureToDeviceQuarterTurns], and getting the inverse wrong
  /// is a 180° error rather than a small one: `sv_geometry.cpp` applies the roll
  /// on the *right*, where bundle adjustment's gauge freedom — a left
  /// multiplication — cannot absorb it, so the whole panorama comes out upside
  /// down. This shipped, returning the forward turn, on every Android device
  /// reporting `SENSOR_ORIENTATION = 90`.
  ///
  /// The sign is a derivation, not a reading of the phase doc.
  /// [CameraIntrinsics.rotatedQuarterTurn] with `clockwise: true` sends a capture
  /// pixel `(x, y)` to `(H − y, x)`, so the capture frame's axes are
  /// `X_c = Y_d`, `Y_c = −X_d`, `Z_c = Z_d`. A vector with device-camera
  /// coordinates `(a, b, c)` therefore reads `(b, −a, c)` in the capture frame,
  /// and `C = Rz(θ)·N·D` then forces `cos θ = 0` and `sin θ = −1`: **θ = −90°**,
  /// i.e. three quarter turns. `test/pose_conversion_test.dart` pins it by
  /// projecting the same physical pixel through both frames.
  static int deviceToCaptureQuarterTurns({
    required bool landscapeCapture,
    required int sensorOrientationDegrees,
  }) =>
      (4 -
          captureToDeviceQuarterTurns(
            landscapeCapture: landscapeCapture,
            sensorOrientationDegrees: sensorOrientationDegrees,
          )) %
      4;

  /// The roll the native stitcher applies on the right of an IMU seed, as a
  /// row-major 3×3 — `Rz(−θ)` for `θ = 90° · turns`, in the OpenCV camera frame.
  ///
  /// The Dart mirror of `imuRotationOpenCvD`'s right multiplication, exact and
  /// without trigonometry. It exists so a test can check the C++ convention
  /// without building C++, and so the replay harness can reproduce a device
  /// bundle's geometry exactly.
  static List<double> captureRollRowMajor(int quarterTurns) {
    final turns = ((quarterTurns % 4) + 4) % 4;
    final c = switch (turns) {
      0 => 1.0,
      2 => -1.0,
      _ => 0.0,
    };
    // sin(−θ), matching sv_geometry.cpp exactly.
    final s = switch (turns) {
      1 => -1.0,
      3 => 1.0,
      _ => 0.0,
    };
    return [c, -s, 0, s, c, 0, 0, 0, 1];
  }

  /// Converts a device→world rotation into the camera→panorama rotation
  /// OpenCV's `detail::CameraParams::R` expects, returned row-major 3×3.
  ///
  /// `R_opencv = M · R_wd · N`, which because both `M` and `N` are diagonal
  /// reduces to a sign flip — no matrix multiply (§2):
  ///
  /// ```
  /// R_opencv[i][j] = s_i · R_wd[i][j] · t_j,  s = (−1,−1,+1),  t = (+1,−1,−1)
  /// ```
  static List<double> openCvRotationFromDeviceToWorld(Quaternion deviceToWorld) {
    final r = deviceToWorld.asRotationMatrix();
    const s = worldToOpenCvPanoDiagonal;
    const t = deviceToOpenCvCameraDiagonal;
    final out = List<double>.filled(9, 0);
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        out[i * 3 + j] = s[i] * r.entry(i, j) * t[j];
      }
    }
    return out;
  }

  /// The inverse of [openCvRotationFromDeviceToWorld]: takes the row-major 3×3
  /// `R_pc` the native stitcher reports and returns `R_wd`.
  ///
  /// The conversion is **its own inverse**, which is worth stating because it
  /// looks like a missing step rather than a saved one. From §2,
  /// `R_opencv = M · R_wd · N` with `M` and `N` both diagonal sign matrices and
  /// both self-inverse, so `M · R_opencv · N = M·M · R_wd · N·N = R_wd`. The
  /// same sign flip, applied twice, is the identity.
  ///
  /// This exists so the replay harness can score native rotations against
  /// ground truth without writing a second copy of the frame conversion — the
  /// exact duplication this class was created to prevent.
  static Matrix3 deviceToWorldFromOpenCvRotation(List<double> rowMajor) {
    if (rowMajor.length != 9) {
      throw ArgumentError.value(
        rowMajor.length,
        'rowMajor.length',
        'expected a row-major 3x3',
      );
    }
    const s = worldToOpenCvPanoDiagonal;
    const t = deviceToOpenCvCameraDiagonal;
    final m = Matrix3.zero();
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        // Matrix3.setEntry is (row, column); vector_math stores column-major
        // internally, so never index its storage directly here.
        m.setEntry(i, j, s[i] * rowMajor[i * 3 + j] * t[j]);
      }
    }
    return m;
  }

  /// Yaw of a world-space direction: `atan2(d.x, d.z)`, in `(−π, π]` (§3).
  static double yawOf(Vector3 worldDirection) =>
      math.atan2(worldDirection.x, worldDirection.z);

  /// Pitch of a world-space direction: `asin(d.y)`, in `[−π/2, π/2]` (§3).
  static double pitchOf(Vector3 worldDirection) =>
      math.asin(worldDirection.y.clamp(-1.0, 1.0));

  /// Unit world direction for a (yaw, pitch) pair — the inverse of [yawOf] and
  /// [pitchOf].
  static Vector3 directionOf(double yaw, double pitch) {
    final cp = math.cos(pitch);
    return Vector3(math.sin(yaw) * cp, math.sin(pitch), math.cos(yaw) * cp);
  }

  /// Equirectangular column for [yaw] on a canvas [width] px wide:
  /// `x = W · (½ − yaw / 2π)` (§3).
  ///
  /// Image centre is yaw 0, i.e. the session-start heading — which is why no
  /// yaw offset is applied anywhere else in the pipeline.
  static double xForYaw(double yaw, double width) =>
      width * (0.5 - yaw / (2 * math.pi));

  /// Equirectangular row for [pitch] on a canvas [height] px tall:
  /// `y = H · (½ − pitch / π)` (§3). Row 0 is the zenith.
  static double yForPitch(double pitch, double height) =>
      height * (0.5 - pitch / math.pi);

  /// Inverse of [xForYaw]: `yaw = π · (1 − 2x / W)`.
  static double yawForX(double x, double width) =>
      math.pi * (1 - 2 * x / width);

  /// Inverse of [yForPitch]: `pitch = (π/2) · (1 − 2y / H)`.
  static double pitchForY(double y, double height) =>
      (math.pi / 2) * (1 - 2 * y / height);

  /// The `scale` to construct OpenCV's `SphericalWarper` with, so that a
  /// [width]-wide canvas spans a full turn: `W / 2π` (§3).
  static double sphericalWarperScale(double width) => width / (2 * math.pi);

  /// The device→world rotation that aims the camera at [yaw]/[pitch] with the
  /// screen held upright — zero roll about the optical axis.
  ///
  /// This is the pose the shot plan is asking the user to reach, so it is also
  /// the pose the synthetic rig renders from. Its columns are the device basis
  /// vectors expressed in the world frame, which is the only form that makes
  /// the sign conventions checkable by eye:
  ///
  /// - `Z_d = −f`, because the device frame looks along `−Z_d` (§1.2) while the
  ///   plan names the direction the camera *points*, `f`;
  /// - `Y_d = u`, the screen-up direction, i.e. world up with the component
  ///   along `f` removed — that is what "zero roll" means;
  /// - `X_d = Y_d × Z_d = f × u`, forced by right-handedness (§1).
  ///
  /// `u` is written in closed form rather than as
  /// `normalize(up − f·(f·up))` so that it stays unit and continuous **at the
  /// poles**, where that expression is 0/0. The polar limit it takes is the
  /// correct one: standing under the zenith, the top of the screen points back
  /// along `−f_horizontal`.
  ///
  /// Sanity check, at yaw 0 / pitch 0: the result is `diag(−1, 1, −1)`, a half
  /// turn about `Y` — **not** the identity. That is right, and it is worth
  /// re-deriving rather than "fixing": `+Z_w` is the direction the camera faced
  /// at session start (§1.1), while an identity device pose looks along `−Z_d`
  /// mapped to `−Z_w`, i.e. yaw π.
  static Matrix3 aimingDeviceToWorld(double yaw, double pitch) {
    final f = directionOf(yaw, pitch);
    final sp = math.sin(pitch);
    final u = Vector3(
      -sp * math.sin(yaw),
      math.cos(pitch),
      -sp * math.cos(yaw),
    );
    return Matrix3.columns(f.cross(u), u, -f);
  }

  /// [aimingDeviceToWorld] as the unit quaternion `DevicePose` stores.
  static Quaternion aimingOrientation(double yaw, double pitch) =>
      Quaternion.fromRotation(aimingDeviceToWorld(yaw, pitch))..normalize();

  /// The ray, in the **device** frame `D`, that pixel ([x], [y]) of an image
  /// with intrinsics [k] looks along. Not normalised.
  ///
  /// Pinhole (§4) is defined in the OpenCV camera frame `C`, which is `Y`-down
  /// and `Z`-forward, so the normalised point `(x_n, y_n, 1)_c` becomes
  /// `N·(x_n, y_n, 1) = (x_n, −y_n, −1)_d` with `N = diag(1, −1, −1)` from §2.
  /// Distortion is *not* applied — a caller modelling a real lens must
  /// undistort the pixel first.
  static Vector3 deviceRayForPixel(CameraIntrinsics k, double x, double y) =>
      Vector3((x - k.cx) / k.fx, -(y - k.cy) / k.fy, -1);

  /// Pixel that a device-frame ray lands on, or `null` when the ray is behind
  /// the camera. The exact inverse of [deviceRayForPixel].
  ///
  /// Pinhole only. Use [distortedPixelForDeviceRay] to place a mark on a real
  /// lens's image.
  static ({double x, double y})? pixelForDeviceRay(
    CameraIntrinsics k,
    Vector3 rayDevice,
  ) {
    // Back to frame C: (x, y, z)_d → (x, −y, −z)_c, so "in front" is −z_d > 0.
    final z = -rayDevice.z;
    if (z <= 1e-12) return null;
    return (
      x: k.fx * (rayDevice.x / z) + k.cx,
      y: k.fy * (-rayDevice.y / z) + k.cy,
    );
  }

  /// An ideal normalised point → where the lens actually puts it.
  ///
  /// The direction OpenCV's coefficients are *defined* in, so no sign or
  /// convention flip is involved (§4.1). `tools/harness/camera_model.dart` needs
  /// the opposite direction — destination pixel back to ideal ray — and iterates;
  /// this one is closed form because placing a mark is a forward projection.
  static ({double x, double y}) distortNormalised(
    DistortionModel? model,
    double x,
    double y,
  ) {
    switch (model) {
      case null:
        return (x: x, y: y);
      case BrownConradyDistortion(
        :final k1,
        :final k2,
        :final p1,
        :final p2,
        :final k3,
      ):
        final r2 = x * x + y * y;
        final radial = 1 + r2 * (k1 + r2 * (k2 + r2 * k3));
        return (
          x: x * radial + 2 * p1 * x * y + p2 * (r2 + 2 * x * x),
          y: y * radial + p1 * (r2 + 2 * y * y) + 2 * p2 * x * y,
        );
      case LookupTableDistortion():
        // Apple's table is a magnification `r'/r` indexed by radius, and radius
        // is in *pixels* from `lensDistortionCenter` — which is neither the
        // principal point nor the image centre. Applying it needs the image size
        // the table was sampled against, which a normalised point no longer
        // carries, so it is handled by the pixel-space entry point below.
        return (x: x, y: y);
    }
  }

  /// Pixel that a device-frame ray lands on **through the lens**, or `null` when
  /// the ray is behind the camera.
  ///
  /// The pinhole version puts a mark several degrees away from the thing it is
  /// marking once the target is near the edge of a wide phone frame, which is
  /// exactly where a capture UI spends its time: the next target is usually at
  /// the rim of the preview, not the middle.
  static ({double x, double y})? distortedPixelForDeviceRay(
    CameraIntrinsics k,
    Vector3 rayDevice,
  ) {
    final z = -rayDevice.z;
    if (z <= 1e-12) return null;
    final model = k.distortion;
    if (model is LookupTableDistortion) {
      final ideal = (
        x: k.fx * (rayDevice.x / z) + k.cx,
        y: k.fy * (-rayDevice.y / z) + k.cy,
      );
      return _applyLookupTable(k, model, ideal.x, ideal.y);
    }
    final distorted = distortNormalised(
      model,
      rayDevice.x / z,
      -rayDevice.y / z,
    );
    return (x: k.fx * distorted.x + k.cx, y: k.fy * distorted.y + k.cy);
  }

  static ({double x, double y}) _applyLookupTable(
    CameraIntrinsics k,
    LookupTableDistortion model,
    double x,
    double y,
  ) {
    final table = model.magnifications;
    if (table.length < 2) return (x: x, y: y);
    final dx = x - model.centerX;
    final dy = y - model.centerY;
    final r = math.sqrt(dx * dx + dy * dy);
    if (r <= 0) return (x: x, y: y);
    // The table runs from radius 0 to the distance from the distortion centre to
    // the farthest corner, which is what Apple documents as its span.
    final corners = [
      math.sqrt(model.centerX * model.centerX + model.centerY * model.centerY),
      math.sqrt(
        math.pow(k.imageSize.width - model.centerX, 2).toDouble() +
            model.centerY * model.centerY,
      ),
      math.sqrt(
        model.centerX * model.centerX +
            math.pow(k.imageSize.height - model.centerY, 2).toDouble(),
      ),
      math.sqrt(
        math.pow(k.imageSize.width - model.centerX, 2).toDouble() +
            math.pow(k.imageSize.height - model.centerY, 2).toDouble(),
      ),
    ];
    final maxRadius = corners.reduce(math.max);
    if (!(maxRadius > 0)) return (x: x, y: y);
    final position = (r / maxRadius) * (table.length - 1);
    final lower = position.floor().clamp(0, table.length - 1);
    final upper = (lower + 1).clamp(0, table.length - 1);
    final t = position - lower;
    final magnification = table[lower] * (1 - t) + table[upper] * t;
    return (
      x: model.centerX + dx * magnification,
      y: model.centerY + dy * magnification,
    );
  }

  /// Where a world direction lands on the preview, in fractions of the preview's
  /// half-width and half-height from its centre — `−1` is the left/top edge,
  /// `+1` the right/bottom. `null` when the direction is behind the camera.
  ///
  /// **The one copy of this mapping.** The guidance engine and the capture
  /// overlay both need it — the engine for the hint and the gate, the overlay for
  /// every dot and every pinned thumbnail — and two copies is how a dot ends up
  /// somewhere the hint disagrees with.
  ///
  /// Relative to the image *centre* rather than the principal point: the mark has
  /// to land where the thing appears in the preview, and the preview is centred
  /// on the frame. A camera whose principal point is off-centre therefore puts
  /// the reticle slightly off its own optical axis, which is the truth.
  static ({double x, double y})? previewOffsetForWorldDirection({
    required CameraIntrinsics k,
    required Quaternion worldToDevice,
    required Vector3 direction,
  }) {
    final rayDevice = QuaternionUtils.rotate(worldToDevice, direction);
    final pixel = distortedPixelForDeviceRay(k, rayDevice);
    if (pixel == null) return null;
    final halfWidth = k.imageSize.width / 2;
    final halfHeight = k.imageSize.height / 2;
    if (halfWidth <= 0 || halfHeight <= 0) return null;
    return (
      x: (pixel.x - halfWidth) / halfWidth,
      y: (pixel.y - halfHeight) / halfHeight,
    );
  }
}
