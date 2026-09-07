import 'dart:math' as math;
import 'dart:ui';

import 'package:field_capture/features/perspective/models/perspective_camera.dart';
import 'package:field_capture/features/perspective/models/trajectory_walk.dart';
import 'package:field_capture/features/plan/models/plan_space.dart';
import 'package:field_capture/features/plan/models/trajectory.dart';
import 'package:flutter_test/flutter_test.dart';

/// The 3D view has no model and no engine behind it, so the renderer itself
/// cannot be trusted by inspection — but the two things it stands on, the
/// camera projection and the walk sampling, are pure functions.
void main() {
  const Size viewport = Size(390, 600);

  PerspectiveCamera cameraAt({
    PlanPoint position = const PlanPoint(10, 10),
    double yaw = 0,
  }) =>
      PerspectiveCamera(position: position, yaw: yaw, viewport: viewport);

  group('PerspectiveCamera.toCamera', () {
    test('a point straight ahead is pure forward', () {
      final CameraPoint p = cameraAt().toCamera(const PlanPoint(15, 10));
      expect(p.forward, closeTo(5, 0.0001));
      expect(p.right, closeTo(0, 0.0001));
    });

    test('facing +x, the plan\'s +y is on the viewer\'s right', () {
      final CameraPoint p = cameraAt().toCamera(const PlanPoint(10, 13));
      expect(p.right, closeTo(3, 0.0001));
      expect(p.forward, closeTo(0, 0.0001));
    });

    test('a point behind the camera reports itself as behind', () {
      final CameraPoint p = cameraAt().toCamera(const PlanPoint(4, 10));
      expect(p.forward, closeTo(-6, 0.0001));
      expect(p.isBehind, isTrue);
    });

    test('yaw rotates the world, not the point', () {
      // Turn 90° so the viewer now faces +y; a point at +y is straight ahead.
      final CameraPoint p =
          cameraAt(yaw: math.pi / 2).toCamera(const PlanPoint(10, 14));
      expect(p.forward, closeTo(4, 0.0001));
      expect(p.right, closeTo(0, 0.0001));
    });
  });

  group('PerspectiveCamera.project', () {
    test('a point dead ahead at eye height lands on the principal point', () {
      final PerspectiveCamera camera = cameraAt();
      final Offset? p = camera.project(const PlanPoint(20, 10), 1.6);

      expect(p, isNotNull);
      expect(p!.dx, closeTo(viewport.width / 2, 0.0001));
      expect(p.dy, closeTo(viewport.height / 2, 0.0001));
    });

    test('the floor projects below the horizon, the ceiling above', () {
      final PerspectiveCamera camera = cameraAt();
      final Offset floor = camera.project(const PlanPoint(20, 10), 0)!;
      final Offset ceiling = camera.project(const PlanPoint(20, 10), 2.8)!;

      expect(floor.dy, greaterThan(camera.horizonY));
      expect(ceiling.dy, lessThan(camera.horizonY));
    });

    test('symmetric points land symmetrically about the centre', () {
      final PerspectiveCamera camera = cameraAt();
      final Offset left = camera.project(const PlanPoint(20, 8), 1.6)!;
      final Offset right = camera.project(const PlanPoint(20, 12), 1.6)!;
      final double centre = viewport.width / 2;

      expect(centre - left.dx, closeTo(right.dx - centre, 0.0001));
    });

    test('the same wall looks smaller further away', () {
      final PerspectiveCamera camera = cameraAt();
      final double near = camera.project(const PlanPoint(15, 10), 0)!.dy;
      final double far = camera.project(const PlanPoint(30, 10), 0)!.dy;

      // Both below the horizon, but the far one is closer to it.
      expect(far, lessThan(near));
      expect(far, greaterThan(camera.horizonY));
    });

    test('nothing behind the near plane is projected', () {
      expect(cameraAt().project(const PlanPoint(5, 10), 1.6), isNull);
      expect(cameraAt().project(const PlanPoint(10, 10), 1.6), isNull);
    });
  });

  group('PerspectiveCamera.clipToNearPlane', () {
    final PerspectiveCamera camera = cameraAt();

    test('a fully visible segment passes through untouched', () {
      const CameraPoint a = CameraPoint(5, -2);
      const CameraPoint b = CameraPoint(9, 3);
      final (CameraPoint, CameraPoint)? clipped = camera.clipToNearPlane(a, b);

      expect(clipped, isNotNull);
      expect(clipped!.$1.forward, 5);
      expect(clipped.$2.forward, 9);
    });

    test('a fully hidden segment is dropped', () {
      expect(
        camera.clipToNearPlane(
          const CameraPoint(-3, 0),
          const CameraPoint(-1, 1),
        ),
        isNull,
      );
    });

    test('a crossing segment is pulled onto the near plane', () {
      // Crosses forward = 0 halfway, so at the near plane it is just past that.
      final (CameraPoint, CameraPoint)? clipped = camera.clipToNearPlane(
        const CameraPoint(-2, 0),
        const CameraPoint(2, 4),
      );

      expect(clipped, isNotNull);
      expect(clipped!.$1.forward, closeTo(camera.nearPlane, 0.0001));
      expect(clipped.$1.forward, greaterThan(0));
      // Interpolated, not snapped to an endpoint.
      expect(clipped.$1.right, greaterThan(0));
      expect(clipped.$1.right, lessThan(4));
      expect(clipped.$2.forward, 2);
    });

    test('the clipped end is always projectable', () {
      final (CameraPoint, CameraPoint)? clipped = camera.clipToNearPlane(
        const CameraPoint(-5, -1),
        const CameraPoint(1, 1),
      );
      expect(camera.projectCamera(clipped!.$1, 0), isNotNull);
    });
  });

  group('TrajectoryWalk', () {
    /// The prototype's Level 03 walk: three pins, recorded as 23 m even though
    /// the straight lines through its pins measure about 13 m.
    final Trajectory deckWalk = Trajectory(
      id: 't1',
      name: 'L03_Walk_2026-07-03_09',
      recordedAt: DateTime(2026, 7, 3, 9),
      lengthMetres: 23,
      nodes: const <TrajectoryNode>[
        TrajectoryNode(kind: TrajectoryNodeKind.start, at: PlanPoint(13.1, 25.9)),
        TrajectoryNode(
          kind: TrajectoryNodeKind.waypoint,
          at: PlanPoint(14.0, 21.1),
          sequence: 1,
        ),
        TrajectoryNode(kind: TrajectoryNodeKind.end, at: PlanPoint(20.5, 15.9)),
      ],
    );

    test('the ends of the scrub are the start and end pins', () {
      final TrajectoryWalk walk = TrajectoryWalk(deckWalk);

      expect(walk.positionAt(0), const PlanPoint(13.1, 25.9));
      expect(walk.positionAt(1).x, closeTo(20.5, 0.0001));
      expect(walk.positionAt(1).y, closeTo(15.9, 0.0001));
    });

    test('the polyline is shorter than the recorded track, as the deck implies',
        () {
      final TrajectoryWalk walk = TrajectoryWalk(deckWalk);

      expect(walk.polylineLength, closeTo(13.2, 0.2));
      expect(walk.recordedLength, 23);
      expect(walk.polylineLength, lessThan(walk.recordedLength));
    });

    test('the displayed distance counts against the recorded length', () {
      final TrajectoryWalk walk = TrajectoryWalk(deckWalk);
      expect(walk.travelledMetres(0), 0);
      expect(walk.travelledMetres(1), 23);
      expect(walk.travelledMetres(0.5), closeTo(11.5, 0.0001));
    });

    test('scrubbing moves monotonically along the path', () {
      final TrajectoryWalk walk = TrajectoryWalk(deckWalk);
      double previous = -1;

      for (double f = 0; f <= 1.0001; f += 0.1) {
        final PlanPoint p = walk.positionAt(f);
        final double travelled = _distanceFrom(deckWalk.path.first, p);
        expect(travelled, greaterThanOrEqualTo(previous - 0.0001));
        previous = travelled;
      }
    });

    test('the fraction is clamped rather than extrapolated', () {
      final TrajectoryWalk walk = TrajectoryWalk(deckWalk);
      expect(walk.positionAt(-4), walk.positionAt(0));
      expect(walk.positionAt(9).x, closeTo(walk.positionAt(1).x, 0.0001));
    });

    test('bearing points along the leg being walked', () {
      final TrajectoryWalk walk = TrajectoryWalk(deckWalk);

      // First leg runs north-ish: y decreasing, so the bearing is negative.
      expect(walk.bearingAt(0.1), lessThan(0));
      // Last leg runs north-east: x increasing, y still decreasing.
      expect(walk.bearingAt(0.9), lessThan(0));
      expect(math.cos(walk.bearingAt(0.9)), greaterThan(0));
    });

    test('a one-pin trajectory is not walkable and does not divide by zero',
        () {
      final TrajectoryWalk walk = TrajectoryWalk(
        Trajectory(
          id: 'partial',
          name: 'partial',
          recordedAt: DateTime(2026, 7, 3),
          lengthMetres: 0,
          nodes: const <TrajectoryNode>[
            TrajectoryNode(
              kind: TrajectoryNodeKind.start,
              at: PlanPoint(4, 4),
            ),
          ],
        ),
      );

      expect(walk.isWalkable, isFalse);
      expect(walk.positionAt(0.5), const PlanPoint(4, 4));
      expect(walk.bearingAt(0.5), 0);
    });
  });
}

double _distanceFrom(PlanPoint a, PlanPoint b) {
  final double dx = b.x - a.x;
  final double dy = b.y - a.y;
  return math.sqrt(dx * dx + dy * dy);
}
