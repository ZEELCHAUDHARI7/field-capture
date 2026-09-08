// The 48px floor.
//
// "Touch targets never below 48px" is STATED in the prototype documentation,
// which makes it a spec item rather than a nicety. Several controls are drawn
// smaller than that on purpose — the Today/All filter is 36px tall, the
// coverage pill 36, the camera chip 38 — so they are wrapped in MinTapTarget,
// which grows the hit area without changing what is painted.
//
// These tests assert the floor holds, and that the growth is actually usable:
// a touch in the grown margin has to reach the control, and on a control with
// several children in a row it has to reach the *nearest* one.

import 'package:field_capture/core/constants/app_sizes.dart';
import 'package:field_capture/core/widgets/chip_selector.dart';
import 'package:field_capture/core/widgets/min_tap_target.dart';
import 'package:field_capture/core/widgets/pill_toggle.dart';
import 'package:field_capture/core/widgets/segmented_toggle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _host(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(home: Scaffold(body: Center(child: child))),
  );
}

void main() {
  group('MinTapTarget', () {
    testWidgets('grows the hit area but not the painted child',
        (WidgetTester tester) async {
      const Key painted = Key('painted');
      await _host(
        tester,
        const MinTapTarget(
          child: SizedBox(key: painted, height: 20, width: 20),
        ),
      );

      expect(
        tester.getSize(find.byType(MinTapTarget)),
        const Size(AppSizes.minTouchTarget, AppSizes.minTouchTarget),
      );
      // The child still paints at its own size — this is a hit-test change,
      // not a layout change.
      expect(tester.getSize(find.byKey(painted)), const Size(20, 20));
    });

    testWidgets('a touch in the grown margin reaches the child',
        (WidgetTester tester) async {
      int taps = 0;
      await _host(
        tester,
        MinTapTarget(
          child: GestureDetector(
            // Opaque, because an empty SizedBox is not hit-testable and a
            // GestureDetector defers to its child by default. Without this the
            // test measures the fixture rather than MinTapTarget: even a tap
            // dead on the centre of the child registers nothing.
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox(height: 20, width: 20),
          ),
        ),
      );

      final Rect box = tester.getRect(find.byType(MinTapTarget));
      // 4px below the top edge is inside the grown box and well outside the
      // 20px child, which is centred.
      await tester.tapAt(Offset(box.center.dx, box.top + 4));
      await tester.pump();

      expect(taps, 1, reason: 'the margin has to be tappable, not dead space');
    });

    testWidgets('the margin resolves to the nearest child, not the centre',
        (WidgetTester tester) async {
      // The reason MinTapTarget clamps rather than forwarding to the centre
      // the way Material's own input padding does: a segmented control puts
      // several children in a row, and the centre would send every near-miss
      // to the middle segment.
      String? picked;
      await _host(
        tester,
        SegmentedToggle<String>(
          values: const <String>['Today', 'All'],
          selected: 'Today',
          labelOf: (String v) => v,
          onChanged: (String v) => picked = v,
        ),
      );

      final Rect box = tester.getRect(find.byType(MinTapTarget));
      final double allX = tester.getCenter(find.text('All')).dx;

      await tester.tapAt(Offset(allX, box.top + 2));
      await tester.pump();

      expect(picked, 'All');
    });
  });

  group('controls drawn below the floor still meet it', () {
    testWidgets('SegmentedToggle — drawn 36', (WidgetTester tester) async {
      await _host(
        tester,
        SegmentedToggle<String>(
          values: const <String>['Today', 'All'],
          selected: 'Today',
          labelOf: (String v) => v,
          onChanged: (_) {},
        ),
      );
      expect(
        tester.getSize(find.byType(MinTapTarget)).height,
        greaterThanOrEqualTo(AppSizes.minTouchTarget),
      );
    });

    testWidgets('PillToggle — drawn 36', (WidgetTester tester) async {
      await _host(
        tester,
        PillToggle(
          label: 'Coverage',
          icon: Icons.visibility_outlined,
          onPressed: () {},
        ),
      );
      final Size size = tester.getSize(find.byType(MinTapTarget));
      expect(size.height, greaterThanOrEqualTo(AppSizes.minTouchTarget));
      expect(size.width, greaterThanOrEqualTo(AppSizes.minTouchTarget));
    });

    testWidgets('ChipSelector — drawn 40', (WidgetTester tester) async {
      await _host(
        tester,
        ChipSelector<String>(
          values: const <String>['Access', 'Safety', 'Other'],
          selected: 'Access',
          labelOf: (String v) => v,
          onChanged: (_) {},
        ),
      );

      for (final Element chip in find.byType(MinTapTarget).evaluate()) {
        final Size size = (chip.renderObject! as RenderBox).size;
        expect(size.height, greaterThanOrEqualTo(AppSizes.minTouchTarget));
        expect(size.width, greaterThanOrEqualTo(AppSizes.minTouchTarget));
      }
    });
  });

  test('the status strip cannot be shorter than the floor it hosts', () {
    // The strip carries the connectivity pill. A strip below the floor caps
    // the pill's hit area however much the pill asks for.
    expect(
      AppSizes.statusStripHeight,
      greaterThanOrEqualTo(AppSizes.minTouchTarget),
    );
  });
}
