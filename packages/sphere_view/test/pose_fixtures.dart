/// A model of what the *platform* reports, so the Phase 07 conversion can be
/// exercised against known physical poses without a device.
///
/// Everything here is built from the platform documentation, forwards: given a
/// device physically held at a known bearing and tilt, what would
/// `TYPE_GAME_ROTATION_VECTOR` (or `CMDeviceMotion`) actually say? The
/// conversion under test then runs on that, and the assertions are about the
/// *physics* — which way yaw moves when you turn right — rather than about
/// matrix entries.
///
/// **What this can and cannot prove.** It proves the conversion is right *given
/// the documented conventions*, and it proves the reflection the phase doc's
/// own derivation produces would be caught. It cannot prove the documentation,
/// which is exactly why Phase 07 §2 sends the question to hardware and why
/// `example/integration_test/pose_device_test.dart` exists. The division is
/// deliberate: everything decidable on a laptop is decided here, so the device
/// test is left holding one question instead of ten.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:sphere_view/sphere_view.dart';
import 'package:vector_math/vector_math_64.dart';

/// The device→reference rotation a `Z`-up platform reports for a device aimed
/// at [bearing] and held with the screen upright.
///
/// Both platform reference frames are `Z`-vertical and right-handed — Android's
/// world frame is ENU, Apple's `.xArbitraryCorrectedZVertical` has an arbitrary
/// horizontal `X` — so one model covers both. The arbitrary horizontal axis is
/// unobservable anyway: the session-start yaw offset absorbs any rotation about
/// the vertical exactly.
///
/// [bearing] is measured **clockwise from `+Y_ref`**, i.e. the way a compass
/// bearing runs and the way a person turning right moves. That is the whole
/// point of this fixture: a test can say "turn right by 30°" and mean it
/// physically, then check what yaw did.
///
/// The columns are the device basis vectors in reference coordinates
/// ([Math §1.2](../phases/01_MATH_AND_CONVENTIONS.md): `+X_d` right, `+Y_d` up
/// the screen, camera along `−Z_d`):
///
/// * `f = (sin β, cos β, 0)` — where the camera points, on the horizon.
/// * `Z_d = −f`, because the device looks along `−Z_d`.
/// * `Y_d = (0, 0, 1)` — the screen's top, held upright, is the vertical.
/// * `X_d = Y_d × Z_d = (cos β, −sin β, 0)`, forced by right-handedness.
Matrix3 platformAttitudeMatrix(double bearing, {double pitch = 0}) {
  // Aim direction on the unit sphere, `pitch` above the horizon.
  final cp = math.cos(pitch);
  final f = Vector3(math.sin(bearing) * cp, math.cos(bearing) * cp, math.sin(pitch));
  // Screen-up with zero roll: the vertical with the component along `f`
  // removed. Written in closed form so it stays unit at the poles, matching
  // `SphericalConventions.aimingDeviceToWorld`'s treatment of the same 0/0.
  final sp = math.sin(pitch);
  final up = Vector3(-sp * math.sin(bearing), -sp * math.cos(bearing), math.cos(pitch));
  return Matrix3.columns(up.cross(-f), up, -f);
}

/// [platformAttitudeMatrix] as the unit quaternion a platform would report.
Quaternion platformAttitude(double bearing, {double pitch = 0}) =>
    Quaternion.fromRotation(platformAttitudeMatrix(bearing, pitch: pitch))
      ..normalize();

/// The unit "away from the earth" vector the plugin boundary would report for
/// the same physical pose.
///
/// Derived from the same attitude rather than stated independently, because
/// that is what the hardware does: the reference vertical is `+Z_ref`, and the
/// device sees it as `R⁻¹ · (0, 0, 1)`.
Vector3 platformUpDevice(double bearing, {double pitch = 0}) {
  final r = platformAttitudeMatrix(bearing, pitch: pitch);
  // Row 3 of R is column 3 of Rᵀ, i.e. Rᵀ·(0,0,1).
  return Vector3(r.entry(2, 0), r.entry(2, 1), r.entry(2, 2))..normalize();
}

/// One wire-level sample for a device at [bearing], as the platform would send
/// it.
PlatformAttitudeSample platformSample({
  required double bearing,
  required int timestampUs,
  required int sequence,
  double pitch = 0,
  double angularSpeedRadPerSec = 0,
  Vector3? upDevice,
  bool negateQuaternion = false,
}) {
  var q = platformAttitude(bearing, pitch: pitch);
  if (negateQuaternion) q = Quaternion(-q.x, -q.y, -q.z, -q.w);
  return PlatformAttitudeSample(
    deviceToReference: q,
    upDevice: upDevice ?? platformUpDevice(bearing, pitch: pitch),
    angularSpeedRadPerSec: angularSpeedRadPerSec,
    timestampUs: timestampUs,
    sequence: sequence,
    accuracy: 3,
  );
}

/// A device that can be supported.
const PoseSupport supportedPose = PoseSupport(
  hasGyroscope: true,
  hasAccelerometer: true,
  hasFusedRotation: true,
  hasGravity: true,
  usesMagnetometer: false,
  frame: PoseReferenceFrame.androidGameRotationVector,
  minDelayUs: 5000,
  detail: 'synthetic supported device',
);

/// The tablet Phase 07 §6 pitfall 3 is about: no gyroscope, so no attitude
/// source that tracks a pan, so nothing this pipeline can do.
const PoseSupport gyrolessPose = PoseSupport(
  hasGyroscope: false,
  hasAccelerometer: true,
  hasFusedRotation: false,
  hasGravity: true,
  usesMagnetometer: false,
  frame: PoseReferenceFrame.androidGameRotationVector,
  minDelayUs: 0,
  detail: 'synthetic gyroless device',
  unsupportedReason:
      'This tablet has no gyroscope, so it cannot track the rotation between '
      'shots. A 360° capture is not possible on this device — use one with a '
      'gyroscope.',
);

/// A [SpherePosePlatform] driven entirely by the test.
///
/// Exists so the warm-up, the yaw datum, the gravity cross-check and the sign
/// canonicalisation can be exercised deterministically — including the branches
/// no device in the room will ever take, which is the same argument
/// `intrinsics_resolver.dart` makes for keeping the intrinsics chain in Dart.
class FakePosePlatform implements SpherePosePlatform {
  FakePosePlatform({
    this.support = supportedPose,
    this.frame = PoseReferenceFrame.androidGameRotationVector,
    this.clock = const PoseClock(
      base: PoseClockBase.androidElapsedRealtime,
      offsetUs: 0,
      uncertaintyUs: 0,
      note: 'synthetic',
    ),
  });

  final PoseSupport support;
  final PoseReferenceFrame frame;
  final PoseClock clock;

  final _samples = StreamController<PlatformAttitudeSample>.broadcast();
  final _errors = StreamController<PosePlatformError>.broadcast();

  bool started = false;
  bool stopped = false;
  Duration? requestedPeriod;

  /// Pushes one sample as if the sensor had produced it.
  void emit(PlatformAttitudeSample sample) => _samples.add(sample);

  /// Pushes an asynchronous platform failure.
  void fail(PosePlatformError error) => _errors.add(error);

  @override
  Future<PoseSupport> capabilities() async => support;

  @override
  Future<PoseStreamStart> start(Duration samplingPeriod) async {
    if (!support.isSupported) throw PoseSourceUnsupported(support);
    started = true;
    requestedPeriod = samplingPeriod;
    return PoseStreamStart(
      frame: frame,
      clock: clock,
      samplingPeriod: samplingPeriod,
      minDelayUs: support.minDelayUs,
      note: 'synthetic',
    );
  }

  @override
  Future<void> stop() async => stopped = true;

  @override
  Stream<PlatformAttitudeSample> get samples => _samples.stream;

  @override
  Stream<PosePlatformError> get errors => _errors.stream;

  Future<void> dispose() async {
    await _samples.close();
    await _errors.close();
  }
}
