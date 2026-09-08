import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:sphere_view/src/utils/quaternion_utils.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart';

/// Pins `PoseBuffer` against values worked out by hand.
///
/// The class is small, and every one of its behaviours is a Phase 07 hazard
/// rather than a convenience: SLERP instead of Euler (§3), `null` instead of
/// extrapolation (§3), the shorter arc instead of the long way round (§6
/// pitfall 4). So the tests are about those, not about the ring mechanics.
void main() {
  const degrees = math.pi / 180;

  DevicePose poseAt({
    required int timestampUs,
    required double yaw,
    double pitch = 0,
    Vector3? up,
    double angularSpeed = 0,
    bool negate = false,
  }) {
    var q = SphericalConventions.aimingOrientation(yaw, pitch);
    if (negate) q = Quaternion(-q.x, -q.y, -q.z, -q.w);
    return DevicePose(
      deviceToWorld: q,
      gravityWorld: up ?? Vector3(0, 1, 0),
      timestampUs: timestampUs,
      angularSpeedRadPerSec: angularSpeed,
    );
  }

  double yawOf(DevicePose p) =>
      SphericalConventions.yawOf(QuaternionUtils.rotate(p.deviceToWorld, Vector3(0, 0, -1)));

  group('interpolation to an arbitrary instant', () {
    test('halfway between 0° and 90° is 45°, hand-computed', () {
      final buffer = PoseBuffer(capacity: 8)
        ..add(poseAt(timestampUs: 1000, yaw: 0))
        ..add(poseAt(timestampUs: 1010, yaw: 90 * degrees));
      final mid = buffer.at(1005)!;
      // SLERP at t = 0.5 between two rotations about the same axis is the
      // half-angle. Euler interpolation would agree here — which is why the
      // polar test below exists.
      expect(yawOf(mid), closeTo(45 * degrees, 1e-9));
      expect(mid.timestampUs, 1005, reason: 'the pose describes the instant asked for');
    });

    test('a quarter of the way is a quarter of the angle', () {
      final buffer = PoseBuffer(capacity: 8)
        ..add(poseAt(timestampUs: 0, yaw: -20 * degrees))
        ..add(poseAt(timestampUs: 100, yaw: 60 * degrees));
      expect(yawOf(buffer.at(25)!), closeTo(0 * degrees, 1e-9));
      expect(yawOf(buffer.at(50)!), closeTo(20 * degrees, 1e-9));
      expect(yawOf(buffer.at(75)!), closeTo(40 * degrees, 1e-9));
    });

    test('near the zenith, where Euler interpolation would be wrong', () {
      // §3's reason for insisting on SLERP: the zenith shot lives exactly where
      // Euler angles degenerate. Two attitudes 90° apart in yaw at 89° of
      // pitch are only ~1.4° apart as rotations of the optical axis, and the
      // interpolated axis must stay on the sphere between them rather than
      // swinging through the pole.
      final buffer = PoseBuffer(capacity: 8)
        ..add(poseAt(timestampUs: 0, yaw: 0, pitch: 89 * degrees))
        ..add(poseAt(timestampUs: 100, yaw: 90 * degrees, pitch: 89 * degrees));
      final mid = buffer.at(50)!;
      final forward = QuaternionUtils.rotate(mid.deviceToWorld, Vector3(0, 0, -1));
      expect(forward.length, closeTo(1.0, 1e-12), reason: 'stays on the sphere');
      // Both endpoints are 1° off the pole, so the interpolated axis is
      // between 1° and 1.42° off it — never at it, and never past it.
      final offPole = math.acos(forward.y.clamp(-1.0, 1.0));
      expect(offPole, greaterThan(0.9 * degrees));
      expect(offPole, lessThan(1.5 * degrees));
    });

    test('angular speed and gravity are interpolated to the same instant', () {
      final buffer = PoseBuffer(capacity: 8)
        ..add(
          poseAt(
            timestampUs: 0,
            yaw: 0,
            up: Vector3(0.02, 0.9998, 0)..normalize(),
            angularSpeed: 0.4,
          ),
        )
        ..add(
          poseAt(
            timestampUs: 100,
            yaw: 10 * degrees,
            up: Vector3(-0.02, 0.9998, 0)..normalize(),
            angularSpeed: 1.4,
          ),
        );
      final mid = buffer.at(30)!;
      expect(mid.angularSpeedRadPerSec, closeTo(0.7, 1e-12));
      expect(mid.gravityWorld.x, closeTo(0.02 * 0.4, 1e-3));
      expect(
        mid.gravityWorld.length,
        closeTo(1.0, 1e-12),
        reason:
            'gravityWorld is a direction, and Math §7 compares it against '
            "bundle adjustment's up — a non-unit vector would weight one frame "
            'more than another for no physical reason',
      );
    });

    test('an exact hit on a sample returns that sample', () {
      final buffer = PoseBuffer(capacity: 8)
        ..add(poseAt(timestampUs: 500, yaw: 0.3))
        ..add(poseAt(timestampUs: 600, yaw: 0.9));
      expect(yawOf(buffer.at(500)!), closeTo(0.3, 1e-9));
      expect(yawOf(buffer.at(600)!), closeTo(0.9, 1e-9));
    });
  });

  group('§6 pitfall 4 — the quaternion sign ambiguity', () {
    test('adjacent samples of opposite sign do not spin 360°', () {
      // `q` and `−q` are the same rotation. Interpolating without taking the
      // shorter arc sends the device the long way round between two samples
      // 10 ms apart — a full spin at 100 Hz, which no amount of downstream
      // bundle adjustment recovers from.
      final buffer = PoseBuffer(capacity: 8)
        ..add(poseAt(timestampUs: 0, yaw: 0))
        ..add(poseAt(timestampUs: 10, yaw: 10 * degrees, negate: true));
      final mid = buffer.at(5)!;
      expect(
        yawOf(mid),
        closeTo(5 * degrees, 1e-9),
        reason: 'the shorter arc is 5°, the longer one is 175° the other way',
      );
    });

    test('the interpolated rotation stays unit whichever sign arrives', () {
      for (final negate in [false, true]) {
        final buffer = PoseBuffer(capacity: 8)
          ..add(poseAt(timestampUs: 0, yaw: 0.1, pitch: 0.2))
          ..add(poseAt(timestampUs: 10, yaw: 0.4, pitch: -0.3, negate: negate));
        expect(buffer.at(7)!.deviceToWorld.length, closeTo(1.0, 1e-12));
      }
    });
  });

  group('the window is a hard boundary, never an extrapolation', () {
    late PoseBuffer buffer;
    setUp(() {
      buffer = PoseBuffer(capacity: 8)
        ..add(poseAt(timestampUs: 1000, yaw: 0))
        ..add(poseAt(timestampUs: 2000, yaw: 0.5));
    });

    test('before the oldest sample returns null', () {
      expect(buffer.at(999), isNull);
      expect(buffer.at(0), isNull);
    });

    test('after the newest sample returns null', () {
      expect(buffer.at(2001), isNull);
      // Deliberately not "close enough". A shutter one millisecond past the
      // newest pose means the pose stream stalled or the clocks disagree, and
      // both are worth rejecting a frame over — a stale pose is worse than no
      // pose because it looks like a good one.
      expect(buffer.at(3000), isNull);
    });

    test('the endpoints themselves are inside', () {
      expect(buffer.at(1000), isNotNull);
      expect(buffer.at(2000), isNotNull);
    });

    test('an empty buffer answers nothing at all', () {
      expect(PoseBuffer(capacity: 4).at(1000), isNull);
      expect(PoseBuffer(capacity: 4).window, isNull);
    });

    test('the reported window is what at() will accept', () {
      final w = buffer.window!;
      expect(w.fromUs, 1000);
      expect(w.toUs, 2000);
    });
  });

  group('the ring', () {
    test('evicts oldest-first and the window follows', () {
      final buffer = PoseBuffer(capacity: 4);
      for (var i = 0; i < 10; i++) {
        buffer.add(poseAt(timestampUs: i * 10, yaw: i * degrees));
      }
      expect(buffer.length, 4);
      expect(buffer.window, (fromUs: 60, toUs: 90));
      expect(buffer.at(50), isNull, reason: 'evicted, so no longer answerable');
      expect(yawOf(buffer.at(60)!), closeTo(6 * degrees, 1e-9));
      expect(yawOf(buffer.at(90)!), closeTo(9 * degrees, 1e-9));
    });

    test('interpolates correctly across the wrap point', () {
      // The ring's oldest sample moves through the backing list, so an
      // interpolation whose two neighbours straddle index 0 is the one that a
      // naïve implementation gets wrong.
      final buffer = PoseBuffer(capacity: 4);
      for (var i = 0; i < 7; i++) {
        buffer.add(poseAt(timestampUs: i * 100, yaw: i * 10 * degrees));
      }
      expect(buffer.window, (fromUs: 300, toUs: 600));
      expect(yawOf(buffer.at(450)!), closeTo(45 * degrees, 1e-9));
    });

    test('4 s at 100 Hz is the default, which is the point of the default', () {
      final buffer = PoseBuffer();
      for (var i = 0; i < 400; i++) {
        buffer.add(poseAt(timestampUs: i * 10000, yaw: 0));
      }
      final w = buffer.window!;
      expect((w.toUs - w.fromUs) / 1e6, closeTo(3.99, 0.01));
    });

    test('out-of-order samples are dropped and counted, not merged', () {
      // A single sensor delivers monotonically, so this counter being non-zero
      // means samples are coming from more than one source or a clock stepped —
      // either of which makes every interpolation in the session suspect.
      final buffer = PoseBuffer(capacity: 8)
        ..add(poseAt(timestampUs: 100, yaw: 0))
        ..add(poseAt(timestampUs: 90, yaw: 1))
        ..add(poseAt(timestampUs: 100, yaw: 2))
        ..add(poseAt(timestampUs: 200, yaw: 0.5));
      expect(buffer.length, 2);
      expect(buffer.outOfOrderCount, 2);
      expect(yawOf(buffer.at(100)!), closeTo(0, 1e-9), reason: 'the first won');
    });

    test('clear empties it and resets the counter', () {
      final buffer = PoseBuffer(capacity: 4)
        ..add(poseAt(timestampUs: 10, yaw: 0))
        ..add(poseAt(timestampUs: 5, yaw: 0))
        ..clear();
      expect(buffer.isEmpty, isTrue);
      expect(buffer.outOfOrderCount, 0);
      expect(buffer.latest, isNull);
    });
  });
}
