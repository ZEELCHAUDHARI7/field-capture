import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'capture_fixtures.dart';

/// Phase 08 §6, tests 10–13: the shutter gate and the frame gate.
///
/// Time is passed in rather than read, so a 340 ms dwell and a 360 ms dwell are
/// two deterministic assertions instead of two sleeps. The timestamps are the
/// pose clock's — the same monotonic microseconds the camera stamps frames
/// with — which is also what the real session feeds it.
void main() {
  // A bracket, named rather than inherited: the default is now
  // `ExposureStrategy.auto` (one frame), and test 13 below is specifically
  // about a bracket that came back short.
  const config = SphereCaptureConfig(
    exposure: ExposureStrategy.bracket3(evSpread: 2.0),
  );
  const millisecond = 1000;

  /// A guidance state with the aim, steadiness and roll set directly, so the
  /// gate can be exercised without going through the engine.
  GuidanceState state({
    double errorDegrees = 0,
    bool steady = true,
    bool rollWithinTolerance = true,
  }) => GuidanceState(
    angularErrorRadians: errorDegrees * deg,
    targetScreenOffsetX: 0,
    targetScreenOffsetY: 0,
    hint: GuidanceHint.onTarget,
    withinAimTolerance: errorDegrees <= config.aimToleranceDegrees,
    steady: steady,
    dwellProgress: 0,
    rollWithinTolerance: rollWithinTolerance,
  );

  group('test 10 — it fires only when all three conditions hold', () {
    test('aim alone does not fire, however long it is held', () {
      final gate = ShutterGate(config);
      for (var t = 0; t < 3000; t += 10) {
        expect(
          gate.update(state(steady: false), t * millisecond),
          isFalse,
          reason: 'fired while the device was still moving at $t ms',
        );
      }
    });

    test('steadiness alone does not fire', () {
      final gate = ShutterGate(config);
      for (var t = 0; t < 3000; t += 10) {
        expect(gate.update(state(errorDegrees: 20), t * millisecond), isFalse);
      }
    });

    test('aim and steadiness without the dwell do not fire', () {
      final gate = ShutterGate(config);
      expect(gate.update(state(), 0), isFalse);
      expect(gate.update(state(), 100 * millisecond), isFalse);
      expect(gate.dwellProgress, closeTo(100 / 350, 1e-9));
    });

    test('all three together fire, exactly once', () {
      final gate = ShutterGate(config);
      expect(gate.update(state(), 0), isFalse);
      expect(gate.update(state(), 400 * millisecond), isTrue);
      // Never twice: the second bracket would go into the same position while
      // the first was still being written.
      expect(gate.update(state(), 500 * millisecond), isFalse);
      expect(gate.update(state(), 900 * millisecond), isFalse);
      gate.reset();
      expect(gate.update(state(), 1000 * millisecond), isFalse);
      expect(gate.update(state(), 1400 * millisecond), isTrue);
    });

    test('a wobble through the target resets the dwell', () {
      // The dwell exists precisely to reject this: a pan that happens to sweep
      // across the target for 200 ms is not the user aiming at it.
      final gate = ShutterGate(config);
      expect(gate.update(state(), 0), isFalse);
      expect(gate.update(state(), 200 * millisecond), isFalse);
      expect(gate.update(state(errorDegrees: 30), 250 * millisecond), isFalse);
      expect(gate.dwellProgress, 0);
      // The clock restarts from here, so 400 ms after the *original* start is
      // still too early.
      expect(gate.update(state(), 400 * millisecond), isFalse);
      expect(gate.update(state(), 760 * millisecond), isTrue);
    });

    test('roll blocks the shutter at a polar target', () {
      final gate = ShutterGate(config);
      expect(gate.update(state(rollWithinTolerance: false), 0), isFalse);
      expect(
        gate.update(state(rollWithinTolerance: false), 5000 * millisecond),
        isFalse,
      );
      expect(gate.update(state(), 5000 * millisecond), isFalse);
      expect(gate.update(state(), 5400 * millisecond), isTrue);
    });
  });

  group('test 11 — 340 ms does not fire, 360 ms does', () {
    test('339 ms of dwell is not enough', () {
      final gate = ShutterGate(config);
      expect(gate.update(state(), 0), isFalse);
      expect(gate.update(state(), 340 * millisecond), isFalse);
      expect(gate.dwellProgress, closeTo(340 / 350, 1e-9));
    });

    test('360 ms is', () {
      final gate = ShutterGate(config);
      expect(gate.update(state(), 0), isFalse);
      expect(gate.update(state(), 360 * millisecond), isTrue);
      expect(gate.dwellProgress, 1.0);
    });

    test('the boundary is exactly the configured dwell', () {
      final gate = ShutterGate(config);
      expect(gate.update(state(), 0), isFalse);
      expect(gate.update(state(), 349999), isFalse);
      expect(gate.update(state(), 350000), isTrue);
    });

    test('dwellProgress is what fills the reticle, and it is clamped', () {
      final gate = ShutterGate(config);
      expect(gate.dwellProgress, 0);
      gate.update(state(), 0);
      expect(gate.dwellProgress, 0);
      gate.update(state(), 175 * millisecond);
      expect(gate.dwellProgress, closeTo(0.5, 1e-9));
      gate.update(state(), 1000 * millisecond);
      expect(gate.dwellProgress, 1.0);
    });
  });

  group('test 12 — adaptive relaxation engages after ~8 s, and says so', () {
    test('the tolerance is the configured one until 8 s have passed', () {
      final gate = ShutterGate(config);
      gate.update(state(errorDegrees: 6), 0);
      for (final seconds in [0, 1, 4, 7]) {
        expect(
          gate.aimToleranceRadiansAt(seconds * 1000 * millisecond),
          closeTo(config.aimToleranceRadians, 1e-12),
          reason: 'relaxed early, at $seconds s',
        );
        expect(gate.isRelaxedAt(seconds * 1000 * millisecond), isFalse);
      }
    });

    test('then it widens in steps, toward 7° and never past it', () {
      final gate = ShutterGate(config);
      gate.update(state(errorDegrees: 6), 0);
      expect(gate.aimToleranceRadiansAt(8000 * millisecond) / deg, closeTo(5, 1e-9));
      expect(gate.aimToleranceRadiansAt(10000 * millisecond) / deg, closeTo(6, 1e-9));
      expect(gate.aimToleranceRadiansAt(12000 * millisecond) / deg, closeTo(7, 1e-9));
      // The ceiling holds however long the user struggles: 7° is a worse seed
      // bundle adjustment can absorb, and anything past it is not.
      expect(gate.aimToleranceRadiansAt(60000 * millisecond) / deg, closeTo(7, 1e-9));
      expect(gate.isRelaxedAt(8000 * millisecond), isTrue);
    });

    test('an aim that never fires at 4° does fire once the ladder reaches '
        'it', () {
      // Each rung admits the aims it is wide enough for and no others, so a
      // user who is nearly there is helped first and a user who is well out
      // waits for the step that actually covers them.
      for (final (error, firesAtMs) in [(4.5, 8000), (5.5, 10000), (6.5, 12000)]) {
        final gate = ShutterGate(config);
        // Steady the whole time and still refused: unreachable at 4°.
        for (var t = 0; t <= firesAtMs - 1000; t += 100) {
          expect(
            gate.update(state(errorDegrees: error), t * millisecond),
            isFalse,
            reason: '$error° fired before the ladder reached it, at $t ms',
          );
        }
        expect(
          gate.update(state(errorDegrees: error), firesAtMs * millisecond),
          isFalse,
          reason: '$error° fired without dwelling',
        );
        expect(
          gate.update(
            state(errorDegrees: error),
            (firesAtMs + 400) * millisecond,
          ),
          isTrue,
          reason: '$error° never fired',
        );
        // And it is reported, so the UI can say "close enough — capturing".
        // Architecture §8: no compromise is silent.
        expect(gate.firedUnderRelaxedAim, isTrue);
      }
    });

    test('a shot taken inside the strict tolerance is not reported as '
        'relaxed', () {
      final gate = ShutterGate(config);
      gate.update(state(), 0);
      expect(gate.update(state(), 400 * millisecond), isTrue);
      expect(gate.firedUnderRelaxedAim, isFalse);
    });

    test('relaxation never touches steadiness', () {
      // §4 is explicit, and it is the difference between a worse frame and an
      // unusable one: motion blur removes detail no operator puts back, and
      // rolling-shutter skew is a per-row distortion no rotation undoes.
      final gate = ShutterGate(config);
      for (var t = 0; t < 60000; t += 100) {
        expect(
          gate.update(state(errorDegrees: 6, steady: false), t * millisecond),
          isFalse,
          reason: 'relaxed the steadiness gate at $t ms',
        );
      }
    });

    test('the relaxation clock restarts with each target', () {
      // Otherwise one slow target spends the allowance of every target after
      // it, and the last twenty positions all fire at 7°.
      final gate = ShutterGate(config);
      gate.update(state(errorDegrees: 6), 0);
      expect(gate.isRelaxedAt(9000 * millisecond), isTrue);
      gate.reset();
      gate.update(state(errorDegrees: 6), 9000 * millisecond);
      expect(gate.isRelaxedAt(9000 * millisecond), isFalse);
      expect(gate.isRelaxedAt(17000 * millisecond), isTrue);
    });
  });

  group('test 13 — the frame gate rejects what the shutter gate cannot see', () {
    const gate = FrameGate(config);

    CapturedPosition position({
      double sharpness = 100,
      double steadiness = 0.01,
      int shots = 3,
    }) => CapturedPosition(
      targetIndex: 0,
      pose: poseAimedAt(0, 0),
      shots: [
        for (var i = 0; i < shots; i++)
          ExposureShot(
            filePath: 'pos_000_ev$i.jpg',
            evBias: i - 1.0,
            timestampUs: 1000000 + i,
          ),
      ],
      sharpness: sharpness,
      steadinessRadPerSec: steadiness,
    );

    test('a sharp, still, complete bracket is accepted', () {
      expect(gate.evaluate(position()), isNull);
    });

    test('a blurred frame is rejected, with a sentence for the user', () {
      final rejection = gate.evaluate(position(sharpness: 10));
      expect(rejection, FrameRejection.blurred);
      expect(rejection!.message, contains('hold still'));
    });

    test('a frame shot while turning is rejected as moving, not as blurred', () {
      // The two have different fixes and different explanations, and a rolling
      // shutter skews a frame whether or not it also reads sharp.
      expect(
        gate.evaluate(position(steadiness: 0.5, sharpness: 1000)),
        FrameRejection.moving,
      );
    });

    test('a short bracket is rejected — unless that is all the device has', () {
      expect(gate.evaluate(position(shots: 2)), FrameRejection.incompleteBracket);
      // A single-shot camera returning one frame has done everything asked of
      // it; failing it here would make such a device unable to capture at all.
      expect(
        gate.evaluate(position(shots: 1), expectedShotCount: 1),
        isNull,
      );
    });

    test('the sharpness floor is exactly the configured one', () {
      expect(gate.evaluate(position(sharpness: 40)), isNull);
      expect(gate.evaluate(position(sharpness: 39.999)), FrameRejection.blurred);
    });
  });
}
