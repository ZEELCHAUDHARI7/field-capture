import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart';

import 'capture_fixtures.dart';

/// Phase 08 §6, tests 6–9: the guidance engine.
///
/// A pure function of one pose, one target and the measured intrinsics, which
/// is why it can be pinned this hard. The dot's position is the part that has
/// to be *geometrically truthful* — it is projected through the real focal
/// length so that it sits where the target actually is in the preview, and "put
/// the dot in the ring" is then a statement about the world rather than a
/// metaphor. With a guessed focal it drifts against the scene as the user
/// turns, and the interaction feels broken in a way nobody can articulate.
void main() {
  const engine = GuidanceEngine();
  const config = SphereCaptureConfig();

  // Deliberately not square and not centred on a round number, so a swapped
  // axis or a dropped principal point is visible rather than cancelling out.
  const intrinsics = CameraIntrinsics(
    fx: 1000,
    fy: 1000,
    cx: 500,
    cy: 700,
    imageSize: ImageSize(1000, 1400),
    source: IntrinsicsSource.derivedFromPhysics,
  );

  CaptureTarget targetAt(double yawDegrees, double pitchDegrees) => CaptureTarget(
    index: 0,
    ringIndex: 0,
    indexInRing: 0,
    yaw: yawDegrees * deg,
    pitch: pitchDegrees * deg,
    ringLabel: 'middle row',
  );

  GuidanceState evaluate(
    DevicePose pose,
    CaptureTarget target, {
    double? aimToleranceRadians,
  }) => engine.evaluate(
    pose: pose,
    target: target,
    config: config,
    intrinsics: intrinsics,
    aimToleranceRadians: aimToleranceRadians,
  );

  group('test 6 — a target dead ahead', () {
    test('zero error, on target, dot at the centre', () {
      final state = evaluate(poseAimedAt(0, 0), targetAt(0, 0));
      expect(state.angularErrorRadians, closeTo(0, 1e-12));
      expect(state.withinAimTolerance, isTrue);
      expect(state.steady, isTrue);
      expect(state.hint, GuidanceHint.onTarget);
      expect(state.targetScreenOffsetX, closeTo(0, 1e-12));
      expect(state.targetScreenOffsetY, closeTo(0, 1e-12));
      expect(state.edgeArrowRadians, isNull);
      expect(state.targetOffScreen, isFalse);
      expect(state.targetBehind, isFalse);
    });

    test('dead ahead but still moving is holdSteady, not onTarget', () {
      // The steadiness gate is doing double duty: motion blur *and*
      // rolling-shutter skew, which no rotation can undo afterwards.
      final state = evaluate(
        poseAimedAt(0, 0, angularSpeedRadPerSec: 0.2),
        targetAt(0, 0),
      );
      expect(state.withinAimTolerance, isTrue);
      expect(state.steady, isFalse);
      expect(state.hint, GuidanceHint.holdSteady);
    });

    test('just inside and just outside the 4° tolerance', () {
      expect(
        evaluate(poseAimedAt(0, 0), targetAt(3.9, 0)).withinAimTolerance,
        isTrue,
      );
      final outside = evaluate(poseAimedAt(0, 0), targetAt(4.1, 0));
      expect(outside.withinAimTolerance, isFalse);
      expect(outside.hint, GuidanceHint.turnLeft);
      // The relaxed tolerance the shutter gate hands in must move the line.
      expect(
        evaluate(
          poseAimedAt(0, 0),
          targetAt(4.1, 0),
          aimToleranceRadians: 7 * deg,
        ).withinAimTolerance,
        isTrue,
      );
    });

    test('the error is an angle between directions, not yaw plus pitch', () {
      // §7 pitfall 3. At the zenith every yaw names the same direction, so a
      // decomposed error is degenerate exactly where the polar shots live.
      final zenith = CaptureTarget(
        index: 0,
        ringIndex: 0,
        indexInRing: 0,
        yaw: -math.pi / 2,
        pitch: math.pi / 2,
        ringLabel: 'zenith',
      );
      // Aimed straight up, but rolled to the *other* polar frame's angle: the
      // direction is perfect and the yaw difference is 90°.
      final state = evaluate(poseAimedAt(0, math.pi / 2), zenith);
      expect(state.angularErrorRadians, closeTo(0, 1e-9));
      expect(state.withinAimTolerance, isTrue);
    });
  });

  group('test 7 — a target 90° to the right', () {
    test('turn right, dot off screen, arrow shown', () {
      // Turning right is yaw decreasing (Math §3), so a target to the right is
      // at negative yaw.
      final state = evaluate(poseAimedAt(0, 0), targetAt(-90, 0));
      expect(state.angularErrorRadians, closeTo(math.pi / 2, 1e-9));
      expect(state.withinAimTolerance, isFalse);
      expect(state.hint, GuidanceHint.turnRight);
      expect(state.targetOffScreen, isTrue);
      expect(state.edgeArrowRadians, isNotNull);
      // 0 rad points to the screen's right edge.
      expect(state.edgeArrowRadians, closeTo(0, 1e-9));
    });

    test('at 89° the dot projects, and is far outside the frame', () {
      // Still in front, so there *is* a projection — and it is ~57 half-widths
      // off the edge. Reporting it unclamped is the honest thing to do; the
      // arrow is what the UI draws.
      final state = evaluate(poseAimedAt(0, 0), targetAt(-89, 0));
      expect(state.targetBehind, isFalse);
      expect(state.targetScreenOffsetX, greaterThan(50));
      expect(state.targetOffScreen, isTrue);
      expect(state.hint, GuidanceHint.turnRight);
    });

    test('and 90° to the left is the mirror of it', () {
      final state = evaluate(poseAimedAt(0, 0), targetAt(90, 0));
      expect(state.hint, GuidanceHint.turnLeft);
      expect(state.edgeArrowRadians!.abs(), closeTo(math.pi, 1e-9));
    });

    test('vertical targets pick the vertical hint', () {
      expect(
        evaluate(poseAimedAt(0, 0), targetAt(0, 40)).hint,
        GuidanceHint.tiltUp,
      );
      expect(
        evaluate(poseAimedAt(0, 0), targetAt(0, -40)).hint,
        GuidanceHint.tiltDown,
      );
      // Screen y grows downward, so "up" is a negative angle.
      expect(
        evaluate(poseAimedAt(0, 0), targetAt(0, 80)).edgeArrowRadians,
        closeTo(-math.pi / 2, 1e-9),
      );
      expect(
        evaluate(poseAimedAt(0, 0), targetAt(0, -80)).edgeArrowRadians,
        closeTo(math.pi / 2, 1e-9),
      );
    });
  });

  group('test 8 — a target behind the device', () {
    test('an arrow, and no dot at all — never a clamped one', () {
      // A dot pinned to the edge implies "nearly there" when the user has to
      // turn 150°, which is the single most confusing thing a guided capture
      // can show. So there is no dot: the offsets are null and the UI has
      // nothing to clamp.
      final state = evaluate(poseAimedAt(0, 0), targetAt(-150, 0));
      expect(state.targetBehind, isTrue);
      expect(state.targetScreenOffsetX, isNull);
      expect(state.targetScreenOffsetY, isNull);
      expect(state.targetOffScreen, isTrue);
      expect(state.edgeArrowRadians, closeTo(0, 1e-9));
      expect(state.hint, GuidanceHint.turnRight);
      expect(state.angularErrorRadians, closeTo(150 * deg, 1e-9));
    });

    test('exactly 180° behind still produces a stable arrow', () {
      // Every screen direction is equally correct here, so the only wrong
      // answer is a NaN or an arrow that spins with rounding noise.
      final state = evaluate(poseAimedAt(0, 0), targetAt(180, 0));
      expect(state.angularErrorRadians, closeTo(math.pi, 1e-9));
      expect(state.targetBehind, isTrue);
      expect(state.edgeArrowRadians, isNotNull);
      expect(state.edgeArrowRadians!.isFinite, isTrue);
    });

    test('behind and below points the arrow down', () {
      final state = evaluate(poseAimedAt(0, 0), targetAt(180, -30));
      expect(state.targetBehind, isTrue);
      expect(state.edgeArrowRadians, closeTo(math.pi / 2, 1e-9));
      expect(state.hint, GuidanceHint.tiltDown);
    });
  });

  group('test 9 — the projected dot, against hand-computed values', () {
    // With the camera at yaw 0 / pitch 0, `aimingDeviceToWorld` is
    // diag(−1, 1, −1) (Math §3's sanity check), so for a target at yaw θ on the
    // horizon the device-frame ray is (−sin θ, 0, −cos θ) and the pinhole gives
    //     u = cx − fx·tan θ ,  v = cy
    // i.e. offsetX = −(fx/(W/2))·tan θ = −2·tan θ for these intrinsics.
    test('pose 1: camera level, target 10° to the left', () {
      final state = evaluate(poseAimedAt(0, 0), targetAt(10, 0));
      const expectedU = 500 - 1000 * 0.17632698070846498;
      expect(
        state.targetScreenOffsetX,
        closeTo((expectedU - 500) / 500, 1e-9),
      );
      expect(state.targetScreenOffsetX, closeTo(-0.35265396141693, 1e-9));
      expect(state.targetScreenOffsetY, closeTo(0, 1e-12));
      expect(state.hint, GuidanceHint.turnLeft);
    });

    test('pose 2: camera level, target 10° above', () {
      // v = cy − fy·tan(10°) = 700 − 176.32698…, so the dot is above centre and
      // the offset is negative because screen y grows downward.
      final state = evaluate(poseAimedAt(0, 0), targetAt(0, 10));
      const expectedV = 700 - 1000 * 0.17632698070846498;
      expect(
        state.targetScreenOffsetY,
        closeTo((expectedV - 700) / 700, 1e-9),
      );
      expect(state.targetScreenOffsetY, closeTo(-0.2518956867263785, 1e-9));
      expect(state.targetScreenOffsetX, closeTo(0, 1e-12));
    });

    test('pose 3: camera at yaw 30° pitch 20°, target at yaw 45° pitch 10°', () {
      // Derived independently of the engine, straight from the frame
      // definitions of Math §1: the device basis in world coordinates is
      // Z_d = −f, Y_d = u (screen up), X_d = f × u, so a world direction d has
      // device components (d·X_d, d·Y_d, d·Z_d), and the pinhole of §4 then
      // gives the pixel. Nothing here shares a line of code with the engine.
      const cameraYaw = 30 * deg;
      const cameraPitch = 20 * deg;
      final target = targetAt(45, 10);

      final f = SphericalConventions.directionOf(cameraYaw, cameraPitch);
      final up = Vector3(
        -math.sin(cameraPitch) * math.sin(cameraYaw),
        math.cos(cameraPitch),
        -math.sin(cameraPitch) * math.cos(cameraYaw),
      );
      final right = f.cross(up);
      final d = target.direction;

      final forwardComponent = d.dot(f);
      final u = 1000 * (d.dot(right) / forwardComponent) + 500;
      final v = 1000 * (-d.dot(up) / forwardComponent) + 700;

      final state = evaluate(poseAimedAt(cameraYaw, cameraPitch), target);
      expect(state.targetScreenOffsetX, closeTo((u - 500) / 500, 1e-9));
      expect(state.targetScreenOffsetY, closeTo((v - 700) / 700, 1e-9));
      // And the angle, independently: acos of the dot product.
      expect(
        state.angularErrorRadians,
        closeTo(math.acos(d.dot(f).clamp(-1.0, 1.0)), 1e-9),
      );
      expect(state.targetOffScreen, isFalse);
    });

    test('the dot moves with the measured focal, not a guessed one', () {
      // The whole reason Phase 06 comes first. Two cameras, same target, same
      // pose: the dot must land in different places, because it does in the
      // preview.
      final narrow = engine.evaluate(
        pose: poseAimedAt(0, 0),
        target: targetAt(10, 0),
        config: config,
        intrinsics: CameraIntrinsics.fromHorizontalFov(
          hfovRadians: 46 * deg,
          imageSize: const ImageSize(1000, 1400),
        ),
      );
      final wide = engine.evaluate(
        pose: poseAimedAt(0, 0),
        target: targetAt(10, 0),
        config: config,
        intrinsics: CameraIntrinsics.fromHorizontalFov(
          hfovRadians: 56 * deg,
          imageSize: const ImageSize(1000, 1400),
        ),
      );
      expect(
        narrow.targetScreenOffsetX!.abs(),
        greaterThan(wide.targetScreenOffsetX!.abs()),
      );
      // A 22% focal difference is a 22% difference in where the dot sits — the
      // drift a hard-coded 52° HFOV would have baked in on every device.
      expect(
        narrow.targetScreenOffsetX! / wide.targetScreenOffsetX!,
        closeTo(
          math.tan(56 * deg / 2) / math.tan(46 * deg / 2),
          1e-9,
        ),
      );
    });

    test('the offset is relative to the frame centre, so an off-centre '
        'principal point shows', () {
      const offCentre = CameraIntrinsics(
        fx: 1000,
        fy: 1000,
        cx: 520,
        cy: 700,
        imageSize: ImageSize(1000, 1400),
        source: IntrinsicsSource.platformCalibration,
      );
      final state = engine.evaluate(
        pose: poseAimedAt(0, 0),
        target: targetAt(0, 0),
        config: config,
        intrinsics: offCentre,
      );
      // Dead ahead is the optical axis, which is 20 px right of the frame
      // centre on this camera — and that is where the dot belongs.
      expect(state.targetScreenOffsetX, closeTo(20 / 500, 1e-12));
      expect(state.angularErrorRadians, closeTo(0, 1e-12));
    });
  });

  group('roll, which is only a gate at the poles', () {
    final zenithA = CaptureTarget(
      index: 0,
      ringIndex: 0,
      indexInRing: 0,
      yaw: 0,
      pitch: math.pi / 2,
      ringLabel: 'zenith',
    );
    final zenithB = CaptureTarget(
      index: 1,
      ringIndex: 0,
      indexInRing: 1,
      yaw: -math.pi / 2,
      pitch: math.pi / 2,
      ringLabel: 'zenith',
    );

    test('the first zenith frame is satisfied by pointing up', () {
      final state = evaluate(poseAimedAt(0, math.pi / 2), zenithA);
      expect(state.angularErrorRadians, closeTo(0, 1e-9));
      expect(state.rollErrorRadians.abs(), lessThan(1e-9));
      expect(state.rollWithinTolerance, isTrue);
      expect(state.hint, GuidanceHint.onTarget);
    });

    test('the second needs the tablet turned, or the two frames are '
        'duplicates', () {
      // Math §8's correction: two frames per pole, the second rolled 90°. If
      // roll were not gated the shutter would fire twice on one view and the
      // redundancy those frames exist for would not exist.
      final atFirstRoll = evaluate(poseAimedAt(0, math.pi / 2), zenithB);
      expect(atFirstRoll.angularErrorRadians, closeTo(0, 1e-9));
      expect(atFirstRoll.rollErrorRadians.abs(), closeTo(math.pi / 2, 1e-9));
      expect(atFirstRoll.rollWithinTolerance, isFalse);
      expect(atFirstRoll.hint, GuidanceHint.rollDevice);

      final turned = evaluate(poseAimedAt(-math.pi / 2, math.pi / 2), zenithB);
      expect(turned.rollErrorRadians.abs(), lessThan(1e-9));
      expect(turned.rollWithinTolerance, isTrue);
      expect(turned.hint, GuidanceHint.onTarget);
    });

    test('away from the poles roll is reported but never gates', () {
      // A rolled frame is still stitchable — bundle adjustment handles it — so
      // it is worth one nudge in the UI and not a stalled capture.
      final rolled = evaluate(
        poseAimedAt(0, 0, rollRadians: 30 * deg),
        targetAt(0, 0),
      );
      expect(rolled.rollErrorRadians.abs(), closeTo(30 * deg, 1e-9));
      expect(rolled.rollWithinTolerance, isTrue);
      expect(rolled.hint, GuidanceHint.onTarget);
    });
  });

  group('degenerate inputs do not produce NaN', () {
    test('a zero quaternion reports the worst aim rather than a NaN', () {
      final broken = DevicePose(
        deviceToWorld: Quaternion(0, 0, 0, 0),
        gravityWorld: Vector3(0, 1, 0),
        timestampUs: 0,
        angularSpeedRadPerSec: 0,
      );
      final state = evaluate(broken, targetAt(0, 0));
      expect(state.angularErrorRadians, math.pi);
      expect(state.withinAimTolerance, isFalse);
      expect(state.targetScreenOffsetX, isNull);
    });

    test('every state round-trips through JSON', () {
      for (final target in [targetAt(0, 0), targetAt(-150, 0), targetAt(0, 80)]) {
        final state = evaluate(poseAimedAt(0, 0), target);
        expect(GuidanceState.fromJson(state.toJson()), state);
      }
    });
  });
}
