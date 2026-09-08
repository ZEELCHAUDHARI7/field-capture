import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../utils/quaternion_utils.dart';
import '../utils/spherical_conventions.dart';

/// Which reference frame a platform attitude quaternion is expressed against.
///
/// The Dart mirror of the wire enum. Kept separate for the same reason the
/// whole model layer is: `tools/replay` loads these types with a plain
/// `dart run` and no Flutter engine (architecture §6.6).
enum PoseReferenceFrame {
  /// Android `TYPE_GAME_ROTATION_VECTOR` — world frame `Z` up, gyro + accel,
  /// **no magnetometer**.
  androidGameRotationVector,

  /// iOS `CMDeviceMotion` under `.xArbitraryCorrectedZVertical` — reference
  /// frame `Z` vertical, yaw arbitrary but drift-corrected, no magnetometer.
  iosXArbitraryCorrectedZVertical,
}

/// Turns a platform attitude quaternion into the device→world rotation the
/// rest of the pipeline speaks (Math §1.1, §2), and pins yaw 0 to the heading
/// the session started at.
///
/// ## Why this file exists, and why it is so short
///
/// Phase 07 §2 walks through the Android derivation and arrives at
/// `A = [[1,0,0],[0,0,1],[0,1,0]]` — whose determinant is **−1**. That is a
/// reflection, not a rotation, and it would mirror the panorama: every seam
/// would still close, every drift test would still pass, and the output would
/// be wrong in a way that only a human looking at readable text would notice.
/// The doc then says, in as many words, not to trust the derivation and to
/// prove the conversion with the §5 mirroring test instead.
///
/// So the code is written to make the thing under test as small as possible.
///
/// ## There is only one degree of freedom at stake
///
/// Any `A` that is a valid conversion has to satisfy exactly one physical
/// constraint: it carries the platform's vertical onto our `+Y_w` (Math §1.1
/// defines `+Y_w` as up). Suppose `A` and `A'` both do. Then `A'·A⁻¹` fixes
/// `+Y_w`, so it is either **a rotation about the vertical** or **a reflection
/// through a vertical plane**.
///
/// The rotation case does not matter *at all*, because [yawOffsetFor] then
/// rotates about the vertical to put the session-start heading at yaw 0, and
/// that offset absorbs any such difference exactly:
/// `O'·(R_y(θ)·A)·q = (O'·R_y(θ))·A·q`, and both offsets are chosen to send the
/// same first sample to yaw 0, so both compositions are the same rotation. The
/// arbitrary horizontal axis of `GAME_ROTATION_VECTOR` and of
/// `.xArbitraryCorrectedZVertical` is unobservable for the same reason — which
/// is precisely why neither platform bothers to define it.
///
/// That leaves **only the determinant**. Mirrored or not mirrored is the entire
/// remaining question, and no amount of further derivation settles it, because
/// what is uncertain is the platform documentation rather than the algebra.
/// Hence the §5 mirroring test, on hardware, with its acceptance criterion
/// stated as a sign: **turning right must decrease yaw**
/// (`example/integration_test/pose_device_test.dart`). The unit tests here can
/// only prove the conversion is self-consistent with the documented platform
/// conventions; they cannot prove the documentation.
///
/// The up-sign half *is* checkable at runtime, and is:
/// `PlatformAhrsPoseSource` rotates the measured gravity vector through this
/// conversion and refuses to start if world up does not come out pointing up.
/// That catches an upside-down panorama; it cannot catch a mirrored one,
/// because a reflection through a vertical plane maps up to up as happily as a
/// rotation does. The two checks are looking at different failures and both are
/// needed.
class PoseFrameConversion {
  const PoseFrameConversion._();

  /// The conversion matrix, row-major 3×3, mapping the platform's reference
  /// frame to our world frame `W`.
  ///
  /// ```
  ///          ⎡ −1  0  0 ⎤
  ///     A =  ⎢  0  0  1 ⎥      det = +1
  ///          ⎣  0  1  0 ⎦
  /// ```
  ///
  /// Read by columns — the images of the reference basis vectors:
  /// `X_ref → −X_w`, `Y_ref → +Z_w`, `Z_ref → +Y_w`. The third is the physical
  /// constraint (both platforms' reference frames are `Z`-vertical, ours is
  /// `Y`-up). The first two are the free choice, and the negated `X` is what
  /// makes the determinant `+1` instead of the `−1` the phase doc's own
  /// derivation lands on.
  ///
  /// It is also the physically honest choice rather than a sign patch. Reading
  /// Android's frame as ENU, the constraint `+X_w = Y_w × Z_w` from Math §1.1
  /// gives `X_w = U × N = −E`: our `+X` genuinely *is* west when `+Z` is north.
  /// The reflection appears only if one insists on `X_ref → +X_w` as well,
  /// which nothing requires.
  static const List<double> referenceToWorldRowMajor = <double>[
    -1, 0, 0, //
    0, 0, 1, //
    0, 1, 0, //
  ];

  /// [referenceToWorldRowMajor] as a rotation: a half turn about
  /// `(0, 1, 1)/√2`.
  ///
  /// Built from an axis and an angle rather than converted from the matrix
  /// because a 180° rotation has trace `−1`, which is the degenerate branch of
  /// every matrix→quaternion routine. `test/pose_conversion_test.dart` asserts
  /// this quaternion reproduces the matrix entry for entry, so the two
  /// statements of `A` cannot drift apart.
  static final Quaternion referenceToWorldRotation = Quaternion.axisAngle(
    Vector3(0, 1, 1)..normalize(),
    math.pi,
  );

  /// `A` for [frame].
  ///
  /// Both platforms currently take the same conversion — both reference frames
  /// are `Z`-vertical and right-handed, so the constraint and the free choice
  /// are identical. They are still switched on rather than collapsed, because
  /// what is uncertain here is *documentation*, and if the §5 test disproves
  /// one platform's convention the fix must not silently move the other.
  static Quaternion rotationFor(PoseReferenceFrame frame) => switch (frame) {
    PoseReferenceFrame.androidGameRotationVector => referenceToWorldRotation,
    PoseReferenceFrame.iosXArbitraryCorrectedZVertical =>
      referenceToWorldRotation,
  };

  /// `R_wd = A · R_ref,d` — the raw platform attitude expressed in our world
  /// frame, **before** the session-start yaw offset.
  ///
  /// Both platforms' device frames already match Math §1.2 (`+X` right, `+Y` up
  /// the screen, camera along `−Z`), so no device-side conversion is needed and
  /// none is applied. That is the one part of §2 that is unambiguous, and it is
  /// asserted in the tests rather than left implicit.
  static Quaternion deviceToWorldUnoffset(
    PoseReferenceFrame frame,
    Quaternion deviceToReference,
  ) => (rotationFor(frame) * deviceToReference)..normalize();

  /// The rotation about world up that puts [deviceToWorld]'s heading at yaw 0.
  ///
  /// Math §1.1: "yaw 0 is wherever the user was pointing when the session
  /// began". Latched once, from the first accepted sample, and composed on the
  /// left of every later pose. It is a pure rotation about `+Y_w` so that it
  /// cannot disturb the gravity lock that pitch and roll depend on.
  ///
  /// **The polar case is real, not hypothetical.** A session may legitimately
  /// begin with the tablet pointed at the zenith — the plan contains two shots
  /// there — and at a pole the optical axis is `±Y_w`, whose yaw is
  /// `atan2(0, 0)`: undefined. [headingOf] falls back to the screen-up
  /// direction, which is horizontal exactly there, using the same polar limit
  /// [SphericalConventions.aimingDeviceToWorld] takes.
  static Quaternion yawOffsetFor(Quaternion deviceToWorld) =>
      Quaternion.axisAngle(Vector3(0, 1, 0), -headingOf(deviceToWorld));

  /// The heading [yawOffsetFor] cancels: the optical axis's yaw, or — when the
  /// device is aimed within [_polarEpsilon] of a pole — the heading the
  /// screen-up direction implies.
  ///
  /// The two poles need opposite signs, and the reason is worth stating because
  /// getting it wrong is a silent π. Substituting `pitch = ±π/2` into
  /// [SphericalConventions.aimingDeviceToWorld]'s closed form for screen-up
  /// gives `u = −horizontal(yaw)` at the zenith and `u = +horizontal(yaw)` at
  /// the nadir: standing under the zenith the top of the screen points back the
  /// way you came, and standing over the nadir it points the way you face.
  /// Negating for the zenith recovers the heading in both cases.
  static double headingOf(Quaternion deviceToWorld) {
    final forward = QuaternionUtils.rotate(deviceToWorld, Vector3(0, 0, -1));
    final horizontal = math.sqrt(
      forward.x * forward.x + forward.z * forward.z,
    );
    if (horizontal >= _polarEpsilon) return SphericalConventions.yawOf(forward);
    final screenUp = QuaternionUtils.rotate(deviceToWorld, Vector3(0, 1, 0));
    return SphericalConventions.yawOf(
      forward.y >= 0 ? -screenUp : screenUp,
    );
  }

  /// Composes the latched offset onto a raw world-frame attitude.
  static Quaternion applyYawOffset(Quaternion offset, Quaternion deviceToWorld) =>
      (offset * deviceToWorld)..normalize();

  /// Below this horizontal component of the optical axis, the heading is taken
  /// from the screen-up direction instead. `sin(1°)`: small enough that no
  /// realistic aim uses the fallback, large enough that the `atan2` it replaces
  /// is never evaluated on numerical dust.
  static const double _polarEpsilon = 0.0174524;
}
