import 'dart:ui';

import 'package:field_capture/features/plan/data/mock_plan_geometry.dart';
import 'package:field_capture/features/plan/models/plan_space.dart';
import 'package:flutter_test/flutter_test.dart';

/// Plan space is the load-bearing idea in the workspace: the prototype states
/// that "pin coordinates are plan-space, so they survive zoom and pan", and
/// that a grid reference is "derived from the pin, not typed by the user".
/// Both are pure functions, so both are testable without a device.
void main() {
  group('PlanTransform', () {
    const Size plan = Size(26, 32);

    test('contain-fits the sheet inside the viewport', () {
      final PlanTransform t = PlanTransform.fit(
        viewport: const Size(390, 520),
        planSize: plan,
        margin: 12,
      );

      // Width binds on a phone: (390 - 24) / 26 = 14.077 px per metre, which
      // is smaller than the height fit of (520 - 24) / 32 = 15.5.
      expect(t.scale, closeTo(366 / 26, 0.001));

      final Offset bottomRight = t.toCanvas(const PlanPoint(26, 32));
      expect(bottomRight.dx, lessThanOrEqualTo(390));
      expect(bottomRight.dy, lessThanOrEqualTo(520));
    });

    test('centres horizontally and aligns to the top, as the deck frames it',
        () {
      final PlanTransform t = PlanTransform.fit(
        viewport: const Size(390, 520),
        planSize: plan,
        margin: 12,
      );

      expect(t.origin.dy, 12);

      final double drawnWidth = plan.width * t.scale;
      expect(t.origin.dx, closeTo((390 - drawnWidth) / 2, 0.001));
    });

    test('round-trips a point through canvas space and back', () {
      final PlanTransform t = PlanTransform.fit(
        viewport: const Size(390, 520),
        planSize: plan,
      );

      const PlanPoint original = PlanPoint(13.1, 25.9);
      final PlanPoint returned = t.toPlan(t.toCanvas(original));

      expect(returned.x, closeTo(original.x, 0.0001));
      expect(returned.y, closeTo(original.y, 0.0001));
    });

    test('survives a degenerate viewport instead of dividing by zero', () {
      final PlanTransform t = PlanTransform.fit(
        viewport: Size.zero,
        planSize: plan,
      );
      expect(t.scale.isFinite, isTrue);
      expect(t.scale, greaterThan(0));
    });
  });

  group('PlanGrid.referenceFor', () {
    const PlanGrid grid = MockPlanGeometry.grid;

    test('derives B-2 for the scaffold-strike issue, as the deck prints it', () {
      expect(grid.referenceFor(const PlanPoint(9.25, 15.9)), 'B-2');
    });

    test('labels rows A–D top to bottom', () {
      expect(grid.referenceFor(PlanPoint(grid.columnX(0), grid.rowY(0))), 'A-1');
      expect(grid.referenceFor(PlanPoint(grid.columnX(1), grid.rowY(1))), 'B-2');
      expect(grid.referenceFor(PlanPoint(grid.columnX(2), grid.rowY(2))), 'C-3');
      expect(grid.referenceFor(PlanPoint(grid.columnX(0), grid.rowY(3))), 'D-1');
    });

    test('snaps to the nearest gridline rather than the enclosing bay', () {
      // Just past halfway between rows A (y=6) and B (y=13.5).
      expect(grid.referenceFor(const PlanPoint(5, 9.7)), 'A-1');
      expect(grid.referenceFor(const PlanPoint(5, 10.0)), 'B-1');
    });

    test('clamps points outside the grid instead of inventing a label', () {
      expect(grid.referenceFor(const PlanPoint(-40, -40)), 'A-1');
      expect(grid.referenceFor(const PlanPoint(999, 999)), 'D-3');
    });
  });
}
