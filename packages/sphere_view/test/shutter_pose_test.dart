import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:sphere_view/src/utils/quaternion_utils.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart';

/// Pins deliverable 5: the pose attached to a bracket is the one interpolated
/// to the **0 EV** shutter.
///
/// A bracket is three frames spread over a few hundred milliseconds, and Phase
/// 05 fuses the other two *onto* the 0 EV frame — so the fused output inherits
/// that frame's geometry and nothing else's. At the 60°/s pan Phase 07 keeps
/// quoting, a ±150 ms neighbour is 9° away. Attaching the burst's first frame,
/// or its midpoint, would describe a frame that does not exist.
void main() {
  const degrees = math.pi / 180;

  /// A pose stream panning right at 60°/s, one sample every 10 ms.
  PoseBuffer panningBuffer({int fromUs = 1000000, int samples = 400}) {
    final buffer = PoseBuffer(capacity: samples);
    for (var i = 0; i < samples; i++) {
      final t = fromUs + i * 10000;
      final yaw = -60 * degrees * (t - fromUs) / 1e6;
      buffer.add(
        DevicePose(
          deviceToWorld: SphericalConventions.aimingOrientation(yaw, 0),
          gravityWorld: Vector3(0, 1, 0),
          timestampUs: t,
          angularSpeedRadPerSec: 60 * degrees,
        ),
      );
    }
    return buffer;
  }

  PlatformFrame frame(double evBias, int timestampUs) => PlatformFrame(
    filePath: '/tmp/pos0_${evBias}ev.jpg',
    evBias: evBias,
    timestampUs: timestampUs,
    byteCount: 1234,
  );

  BracketCapture bracket(List<PlatformFrame> frames) => BracketCapture(
    frames: frames,
    burstWallClockMs: 420,
    shutterToShutterMs: const [140, 140],
    mode: BracketMode.manualExposureBurst,
    clampedExposure: false,
    clampedIso: false,
    deferredEncodeMs: 0,
  );

  double yawOf(DevicePose p) => SphericalConventions.yawOf(
    QuaternionUtils.rotate(p.deviceToWorld, Vector3(0, 0, -1)),
  );

  group('the 0 EV shot is the reference', () {
    test('not the first frame of the burst, and the difference is degrees', () {
      final buffer = panningBuffer();
      // A −2 EV first shot, 0 EV 150 ms later, +2 EV 150 ms after that.
      final capture = bracket([
        frame(-2.0, 1500000),
        frame(0.0, 1650000),
        frame(2.0, 1800000),
      ]);

      final resolved = ShutterPoseResolver(buffer).resolve(capture);
      expect(resolved.isResolved, isTrue);
      expect(resolved.exact, isTrue);
      expect(resolved.referenceFrame!.evBias, 0.0);
      expect(resolved.pose!.timestampUs, 1650000);

      // 650 ms into a 60°/s pan is 39°, and turning right lowers yaw.
      expect(yawOf(resolved.pose!), closeTo(-39 * degrees, 1e-9));
      // The frame the burst *started* with is 9° away — which is why this
      // matters at all.
      expect(yawOf(buffer.at(1500000)!), closeTo(-30 * degrees, 1e-9));
    });

    test('picks it by requested bias, whatever order the frames arrive in', () {
      final resolved = ShutterPoseResolver(panningBuffer()).resolve(
        bracket([
          frame(2.0, 1200000),
          frame(0.0, 1210000),
          frame(-2.0, 1220000),
        ]),
      );
      expect(resolved.referenceFrame!.timestampUs, 1210000);
    });

    test('a single locked exposure is its own reference', () {
      final resolved = ShutterPoseResolver(
        panningBuffer(),
      ).resolve(bracket([frame(0.0, 1300000)]));
      expect(resolved.isResolved, isTrue);
      expect(resolved.exact, isTrue);
    });

    test('a bracket with no 0 EV frame falls back, and says it fell back', () {
      // `CapturedPosition.baseShot` uses exactly this rule — 0 EV, else the
      // first — so the pose written into the bundle and the shot the bundle
      // calls its base can never disagree. `exact` records which happened.
      final resolved = ShutterPoseResolver(panningBuffer()).resolve(
        bracket([frame(-1.0, 1400000), frame(1.0, 1410000)]),
      );
      expect(resolved.isResolved, isTrue);
      expect(resolved.exact, isFalse);
      expect(resolved.referenceFrame!.evBias, -1.0);
    });

    test('interpolates rather than snapping to the nearest sample', () {
      // The shutter lands 3.7 ms into a 10 ms gap. Nearest-sample lookup would
      // be up to 5 ms out, which at 60°/s is 0.3°; §3's whole argument.
      //
      // The tolerance is 1e-7 rad rather than 1e-9 because SLERP falls back to
      // a normalised lerp once the arc is under ~3.6°, and at 100 Hz every arc
      // is. The two differ by ~3e-9 rad here — 2e-7 degrees, or 7e-4 px at a
      // 6144-wide equirect — so the fallback is the right trade and the number
      // is worth writing down rather than hiding behind a loose bound.
      final resolved = ShutterPoseResolver(
        panningBuffer(),
      ).resolve(bracket([frame(0.0, 1500000 + 3700)]));
      expect(yawOf(resolved.pose!), closeTo(-60 * degrees * 0.5037, 1e-7));
    });
  });

  group('a shutter outside the buffered window is refused, with a reason', () {
    // Architecture §8: no compromise is silent. Phase 08 re-queues the target,
    // and the three ways this can miss have three different fixes — so the
    // resolver says which one happened rather than returning a bare null.

    test('older than the buffer: the burst outran the history', () {
      final buffer = panningBuffer(fromUs: 5000000);
      final resolved = ShutterPoseResolver(
        buffer,
      ).resolve(bracket([frame(0.0, 4200000)]));
      expect(resolved.isResolved, isFalse);
      expect(resolved.reason, contains('800 ms older'));
      expect(resolved.reason, contains('buffer is long'));
      expect(
        resolved.referenceFrame,
        isNotNull,
        reason: 'the caller still needs to know which frame it was about',
      );
    });

    test('newer than the buffer: a stalled stream, or two different clocks', () {
      final buffer = panningBuffer(fromUs: 1000000, samples: 100);
      final resolved = ShutterPoseResolver(
        buffer,
      ).resolve(bracket([frame(0.0, 3000000)]));
      expect(resolved.isResolved, isFalse);
      expect(resolved.reason, contains('newer'));
      expect(
        resolved.reason,
        contains('not the same clock'),
        reason:
            'this is the shape a Phase 06 §2.5 / Phase 07 §6 pitfall 1 clock '
            'mismatch takes, and the message should send the reader there',
      );
    });

    test('an empty buffer: sampling never started, or is still warming up', () {
      final resolved = ShutterPoseResolver(
        PoseBuffer(capacity: 8),
      ).resolve(bracket([frame(0.0, 1000000)]));
      expect(resolved.isResolved, isFalse);
      expect(resolved.reason, contains('warm-up'));
    });

    test('an empty bracket', () {
      final resolved = ShutterPoseResolver(panningBuffer()).resolve(bracket([]));
      expect(resolved.isResolved, isFalse);
      expect(resolved.reason, contains('no frames'));
    });
  });

  test('the resolved pose slots straight into a CapturedPosition', () {
    // The end of deliverable 5: this is the object that reaches `bundle.json`,
    // and its `baseShot` must be the frame the pose was interpolated to.
    final buffer = panningBuffer();
    final capture = bracket([
      frame(-2.0, 1500000),
      frame(0.0, 1650000),
      frame(2.0, 1800000),
    ]);
    final resolved = ShutterPoseResolver(buffer).resolve(capture);

    final position = CapturedPosition(
      targetIndex: 7,
      pose: resolved.pose!,
      shots: [
        for (final f in capture.frames)
          ExposureShot(
            filePath: 'pos7_${f.evBias}.jpg',
            evBias: f.evBias,
            timestampUs: f.timestampUs,
          ),
      ],
      sharpness: 210,
      steadinessRadPerSec: resolved.pose!.angularSpeedRadPerSec,
    );

    expect(position.baseShot.evBias, 0.0);
    expect(
      position.baseShot.timestampUs,
      position.pose.timestampUs,
      reason:
          'the bundle calls this shot its base and the pose claims to describe '
          'that instant; if these ever differ the two are describing different '
          'frames',
    );
  });
}
