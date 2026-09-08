import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'hud_fixtures.dart';

/// Phase 09 §6's golden tests, over pure white and pure black.
///
/// **Legibility is a correctness property here, not a preference.** The two
/// backgrounds are not decoration: a construction site is a blown-out window
/// next to an unlit corner, often in the same frame, and an overlay that
/// disappears into either one is as broken as a reticle drawn in the wrong
/// place. White is the wall in direct sun; black is the ceiling void. Every
/// element has to survive both, which is why each white element carries a dark
/// outer stroke and why no element is mid-grey.
///
/// These goldens will move whenever the overlay is restyled, which is the point
/// — a restyle that quietly drops the outline strokes shows up as a diff rather
/// than as a field complaint six weeks later.
void main() {
  late CapturePlan plan;

  setUpAll(() => plan = buildFixturePlan());

  const size = Size(400, 800);

  /// One representative frame with every element on screen at once: seven of
  /// twenty-nine captured, the dot off-centre and heading for the reticle, the
  /// dwell ring part-filled, a sentence, and the world-locked dots for the
  /// targets still to shoot.
  ///
  /// The dots are in the golden deliberately: they land on top of the preview
  /// rather than on a plate, so their legibility is the hardest here to reason
  /// about and the easiest to lose in a restyle. A field photograph caught them
  /// at 3.5 dp and 60% white, which on a phone at arm's length is a speck.
  CaptureHudModel busyModel() => CaptureHudModel(
    plan: plan,
    intrinsics: plan.intrinsics,
    state: sessionState(
      plan: plan,
      capturedCount: 7,
      pose: levelPose(),
      guidance: guidanceState(
        offsetX: 0.35,
        offsetY: -0.18,
        hint: GuidanceHint.turnRight,
        withinAimTolerance: false,
        dwellProgress: 0.55,
      ),
    ),
  );

  Future<void> pumpOver(WidgetTester tester, Color background) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final model = busyModel();
    addTearDown(model.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: size),
          child: RepaintBoundary(
            key: const ValueKey('hud'),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: background),
                CaptureHud(
                  model: model,
                  previewAspectRatio: 3 / 4,
                  safeArea: EdgeInsets.zero,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('every element survives a pure white wall in sunlight', (
    tester,
  ) async {
    await pumpOver(tester, const Color(0xFFFFFFFF));
    await expectLater(
      find.byKey(const ValueKey('hud')),
      matchesGoldenFile('goldens/capture_hud_on_white.png'),
    );
  });

  testWidgets('every element survives an unlit ceiling', (tester) async {
    await pumpOver(tester, const Color(0xFF000000));
    await expectLater(
      find.byKey(const ValueKey('hud')),
      matchesGoldenFile('goldens/capture_hud_on_black.png'),
    );
  });

  testWidgets('the off-screen arrow survives both too', (tester) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final model = CaptureHudModel(
      plan: plan,
      state: sessionState(
        plan: plan,
        capturedCount: 12,
        guidance: guidanceState(
          offsetX: null,
          offsetY: null,
          hint: GuidanceHint.turnRight,
          withinAimTolerance: false,
          angularErrorRadians: 2.4,
          edgeArrowRadians: 0.6,
        ),
      ),
    );
    addTearDown(model.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: size),
          child: RepaintBoundary(
            key: const ValueKey('hud'),
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFFFFFFFF)),
                CaptureHud(
                  model: model,
                  previewAspectRatio: 3 / 4,
                  safeArea: EdgeInsets.zero,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await expectLater(
      find.byKey(const ValueKey('hud')),
      matchesGoldenFile('goldens/capture_hud_arrow_on_white.png'),
    );
  });
}
