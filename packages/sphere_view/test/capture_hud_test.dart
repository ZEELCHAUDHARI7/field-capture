import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'hud_fixtures.dart';

/// Phase 09 §6, the painter half: what is on screen, where, and how much of it
/// gets rebuilt to put it there.
///
/// These assert against **pixels** wherever the claim is about pixels. A test
/// that only read widget properties would pass for a painter that drew nothing,
/// and "the dot is where the target is" is the one promise this whole interface
/// rests on — put the dot in the ring is a statement about the world, not a
/// metaphor, and it is only true if the projection actually lands there.
void main() {
  late CapturePlan plan;

  setUpAll(() => plan = buildFixturePlan());

  const size = Size(400, 800);
  // Portrait 3:4, so the cover-fitted preview is 600 × 800 on a 400 × 800
  // canvas: wider than the screen, which is exactly the crop a real tablet
  // shows and the reason the dot cannot simply be placed against the canvas.
  const previewAspect = 3 / 4;
  const centreX = 200.0;
  const centreY = 400.0;
  const previewHalfWidth = 300.0;
  const previewHalfHeight = 400.0;

  CaptureHudModel modelWith(SessionState state) =>
      CaptureHudModel(plan: plan, state: state);

  CaptureHudPainter painterFor(
    CaptureHudModel model, {
    CaptureHudCache? cache,
  }) => CaptureHudPainter(
    model: model,
    cache: cache ?? CaptureHudCache(),
    previewAspectRatio: previewAspect,
  );

  /// Rasterises the overlay.
  ///
  /// Through [WidgetTester.runAsync] because `Picture.toImage` is completed by
  /// the engine, and a `testWidgets` body runs in fake async where an engine
  /// future never resolves — the test would hang rather than fail, which is the
  /// worst way for a test to be wrong.
  Future<RenderedPainter> render(
    WidgetTester tester,
    CaptureHudPainter painter,
  ) async => (await tester.runAsync(() => RenderedPainter.of(painter, size)))!;

  Future<CaptureHudState> pumpHud(
    WidgetTester tester,
    CaptureHudModel model,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: size),
          child: CaptureHud(
            model: model,
            previewAspectRatio: previewAspect,
            safeArea: EdgeInsets.zero,
          ),
        ),
      ),
    );
    return tester.state<CaptureHudState>(find.byType(CaptureHud));
  }

  group('the instruction line', () {
    test('every hint has exactly one sentence, and it is the right one', () {
      // Phase 09 §2's table, verbatim. The strings live in one place so the
      // copy can be localised and so a test can enumerate them; the enum is
      // what the guidance engine actually decides.
      const expected = {
        GuidanceHint.turnRight: 'Turn right',
        GuidanceHint.turnLeft: 'Turn left',
        GuidanceHint.tiltUp: 'Tilt up',
        GuidanceHint.tiltDown: 'Tilt down',
        GuidanceHint.holdSteady: 'Hold steady',
        GuidanceHint.rollDevice: 'Turn the tablet sideways',
      };
      for (final entry in expected.entries) {
        final directional =
            entry.key == GuidanceHint.turnRight ||
            entry.key == GuidanceHint.turnLeft ||
            entry.key == GuidanceHint.tiltUp ||
            entry.key == GuidanceHint.tiltDown;
        final state = sessionState(
          plan: plan,
          // The middle-row targets never open a ring, so a directional hint
          // here is the plain form rather than "Now tilt up".
          currentTarget: plan.targets[3],
          guidance: guidanceState(
            hint: entry.key,
            withinAimTolerance: !directional,
            steady: entry.key != GuidanceHint.holdSteady,
          ),
        );
        expect(
          CaptureInstructions.forState(state, plan: plan),
          entry.value,
          reason: 'hint ${entry.key.name}',
        );
      }
    });

    test('on target and steady, the ring is the feedback and there is no text', () {
      final state = sessionState(
        plan: plan,
        guidance: guidanceState(dwellProgress: 0.4),
      );
      expect(CaptureInstructions.forState(state, plan: plan), isNull);
    });

    test('a roll past 12° asks for the tablet to be levelled', () {
      GuidanceState rolled(double degrees) => guidanceState(
        rollErrorRadians: degrees * math.pi / 180,
      );
      expect(
        CaptureInstructions.forState(
          sessionState(plan: plan, guidance: rolled(11)),
          plan: plan,
        ),
        isNull,
      );
      expect(
        CaptureInstructions.forState(
          sessionState(plan: plan, guidance: rolled(14)),
          plan: plan,
        ),
        'Level the tablet',
      );
      // Negative roll is the same nudge; the user is not told which way, because
      // "level" is unambiguous and a direction here would be one more thing to
      // read.
      expect(
        CaptureInstructions.forState(
          sessionState(plan: plan, guidance: rolled(-14)),
          plan: plan,
        ),
        'Level the tablet',
      );
    });

    test('aiming outranks the roll nudge; a rejection outranks everything', () {
      final turning = sessionState(
        plan: plan,
        guidance: guidanceState(
          hint: GuidanceHint.turnRight,
          withinAimTolerance: false,
          rollErrorRadians: 30 * math.pi / 180,
        ),
      );
      expect(CaptureInstructions.forState(turning, plan: plan), 'Turn right');

      final rejected = sessionState(
        plan: plan,
        message: FrameRejection.blurred.message,
        guidance: guidanceState(
          hint: GuidanceHint.turnRight,
          withinAimTolerance: false,
        ),
      );
      expect(
        CaptureInstructions.forState(rejected, plan: plan),
        'Too blurry — hold still',
      );
    });

    test('entering a new row says the row moved', () {
      // The first target of the second ring, reached while still off-axis and
      // below it. Phase 08 shoots the equator first and then climbs, so this is
      // the transition a real session hits at position 12.
      final opener = plan.targets.firstWhere(
        (t) => t.indexInRing == 0 && t.ringIndex == 1,
      );
      final state = sessionState(
        plan: plan,
        currentTarget: opener,
        guidance: guidanceState(
          hint: GuidanceHint.tiltUp,
          withinAimTolerance: false,
        ),
      );
      expect(CaptureInstructions.forState(state, plan: plan), 'Now tilt up');
      expect(plan.targets[opener.index - 1].pitch, lessThan(opener.pitch));
    });

    testWidgets('the HUD shows one sentence, and it is the resolved one', (
      tester,
    ) async {
      final model = modelWith(
        sessionState(
          plan: plan,
          guidance: guidanceState(
            hint: GuidanceHint.turnLeft,
            withinAimTolerance: false,
          ),
        ),
      );
      addTearDown(model.dispose);
      // Disposed by hand rather than in a tear-down: `WidgetTester` verifies
      // that no semantics handle outlives the test body, and it runs that check
      // before tear-downs.
      final semantics = tester.ensureSemantics();
      await pumpHud(tester, model);
      expect(find.bySemanticsLabel('Turn left'), findsOneWidget);
      // Not two: the whole screen carries exactly one live region, so there is
      // never a second instruction competing for the same glance.
      expect(find.bySemanticsLabel('Hold steady'), findsNothing);

      model.state = sessionState(
        plan: plan,
        guidance: guidanceState(hint: GuidanceHint.holdSteady, steady: false),
      );
      await tester.pump();
      expect(find.bySemanticsLabel('Hold steady'), findsOneWidget);
      expect(find.bySemanticsLabel('Turn left'), findsNothing);
      semantics.dispose();
    });
  });

  group('the target dot', () {
    testWidgets('lands exactly where targetScreenOffset says it is', (
      tester,
    ) async {
      final model = modelWith(
        sessionState(
          plan: plan,
          guidance: guidanceState(offsetX: 0.5, offsetY: -0.25),
        ),
      );
      addTearDown(model.dispose);
      final state = await pumpHud(tester, model);

      final layout = state.cache.layout(
        size: size,
        safeArea: EdgeInsets.zero,
        previewAspectRatio: previewAspect,
        plan: plan,
      );
      // Offsets are fractions of the *preview's* half-extent, not the screen's.
      // On this canvas the cover-fitted preview is 600 wide, so half a frame to
      // the right is 150 px, not 100 — getting this wrong would put the dot
      // several degrees off the thing it points at on every device whose
      // display and sensor aspect ratios differ.
      expect(layout.dotX(0.5), closeTo(centreX + 0.5 * previewHalfWidth, 1e-9));
      expect(
        layout.dotY(-0.25),
        closeTo(centreY - 0.25 * previewHalfHeight, 1e-9),
      );

      final rendered = await render(tester, painterFor(model, cache: state.cache));
      // 200 + 0.5 × 300 = 350, and 400 − 0.25 × 400 = 300.
      expect(rendered.alphaAt(350, 300), greaterThan(200));
      expect(rendered.redAt(350, 300), greaterThan(200));
      // And nowhere else: a dot drawn against the screen instead of against the
      // preview would land at 300, 300.
      expect(rendered.anythingNear(300, 300, radius: 2), isFalse);
    });

    testWidgets('a target behind the camera draws an arrow and no dot', (
      tester,
    ) async {
      final model = modelWith(
        sessionState(
          plan: plan,
          guidance: guidanceState(
            // Phase 08 returns null offsets when there is no projection at all.
            offsetX: null,
            offsetY: null,
            hint: GuidanceHint.turnRight,
            withinAimTolerance: false,
            angularErrorRadians: 2.6,
            edgeArrowRadians: 0,
          ),
        ),
      );
      addTearDown(model.dispose);
      final state = await pumpHud(tester, model);
      final rendered = await render(tester, painterFor(model, cache: state.cache));

      // Nothing at the centre, where a dot clamped to "straight ahead" would
      // sit. §2: a dot at the edge implies "nearly there" when the user has to
      // turn 150°, which is the single most confusing thing this UI could do.
      expect(rendered.anythingNear(centreX, centreY, radius: 4), isFalse);
      // An arrow pinned to the right-hand edge instead.
      expect(rendered.anythingNear(370 - 15, centreY, radius: 12), isTrue);
      // And exactly one arrow: nothing at the top edge, clear of the progress
      // bar, where a second one would be if the painter drew both the offsets
      // and the arrow.
      expect(rendered.anythingNear(centreX, 120, radius: 20), isFalse);
    });

    testWidgets('an on-preview target cropped off screen gets the arrow', (
      tester,
    ) async {
      // The cover-fitted preview is wider than the screen, so a target at 0.9 of
      // the frame's half-width is inside the preview and outside the display.
      // Guidance reports no arrow — it works in the sensor's frame and cannot
      // know about the crop — so the painter has to, from the one visibility
      // rule.
      final model = modelWith(
        sessionState(
          plan: plan,
          guidance: guidanceState(offsetX: 0.9, offsetY: 0),
        ),
      );
      addTearDown(model.dispose);
      final state = await pumpHud(tester, model);
      final rendered = await render(tester, painterFor(model, cache: state.cache));
      expect(rendered.anythingNear(370 - 15, centreY, radius: 14), isTrue);
    });
  });

  group('the centre ring', () {
    /// The whole interaction, as pixels: the ring is a grey track that goes
    /// white clockwise from twelve o'clock as the dwell fills.
    ///
    /// The arc is drawn **on** the ring rather than on a second circle outside
    /// it, so filled and unfilled differ by *colour* and not by presence — the
    /// ring is drawn all the way round at every dwell. That is why these sample
    /// `redAt` at an exact radius rather than asking `anythingNear`: "nothing is
    /// drawn at the bottom of the ring yet" is no longer the claim, and a test
    /// that still asked it would pass for a painter that had lost the track.
    ///
    /// The ring also contracts as it fills, so every sample is taken at the
    /// radius that dwell actually draws at — `layout.ringRadiusFor` is the same
    /// lookup the painter uses.
    testWidgets('fills white clockwise from twelve o’clock across the dwell', (
      tester,
    ) async {
      final model = modelWith(
        sessionState(plan: plan, guidance: guidanceState()),
      );
      addTearDown(model.dispose);
      final state = await pumpHud(tester, model);
      final cache = state.cache;
      final layout = cache.layout(
        size: size,
        safeArea: EdgeInsets.zero,
        previewAspectRatio: previewAspect,
        plan: plan,
      );

      Offset top(double d) => Offset(centreX, centreY - layout.ringRadiusFor(d));
      Offset right(double d) =>
          Offset(centreX + layout.ringRadiusFor(d), centreY);
      Offset bottom(double d) =>
          Offset(centreX, centreY + layout.ringRadiusFor(d));
      Offset left(double d) =>
          Offset(centreX - layout.ringRadiusFor(d), centreY);

      Future<RenderedPainter> at(double dwell) async {
        model.state = sessionState(
          plan: plan,
          guidance: guidanceState(dwellProgress: dwell),
        );
        return render(tester, painterFor(model, cache: cache));
      }

      // The track composites to about 150 on the red channel and the arc to
      // 255, so 230 sits in the gap with both well clear of it. If this ever
      // gets tight the fix is a brighter arc or a darker track, not a looser
      // threshold: §4 is explicit that legibility here is correctness.
      bool filled(RenderedPainter r, Offset p) => r.redAt(p.dx, p.dy) > 230;
      bool track(RenderedPainter r, Offset p) {
        final red = r.redAt(p.dx, p.dy);
        return red > 60 && red <= 230;
      }

      // At rest the ring is present all the way round, and nowhere white.
      final empty = await at(0);
      for (final point in [top(0), right(0), bottom(0), left(0)]) {
        expect(track(empty, point), isTrue);
      }

      final quarter = await at(0.25);
      expect(filled(quarter, top(0.25)), isTrue);
      expect(filled(quarter, right(0.25)), isTrue);
      // Clockwise, not anticlockwise and not both ways at once: a quarter turn
      // past twelve reaches three o'clock and nothing further.
      expect(track(quarter, bottom(0.25)), isTrue);
      expect(track(quarter, left(0.25)), isTrue);

      final threeQuarters = await at(0.75);
      expect(filled(threeQuarters, bottom(0.75)), isTrue);
      expect(filled(threeQuarters, left(0.75)), isTrue);

      final full = await at(1);
      for (final point in [top(1), right(1), bottom(1), left(1)]) {
        expect(filled(full, point), isTrue);
      }

      // Monotonic, not just right at the ends: the fill is what makes the
      // auto-shutter feel deliberate rather than arbitrary, and a fill that
      // jumped would not.
      final half = await at(0.5);
      expect(half.drawnPixelCount, greaterThan(quarter.drawnPixelCount));
      expect(full.drawnPixelCount, greaterThan(half.drawnPixelCount));
    });

    testWidgets('keeps its grey track while the arc fills over it', (
      tester,
    ) async {
      // The claim the whole design rests on, and the mistake it is guarding
      // against. Whitening the whole ring on arrival was tried, and it spends
      // the contrast the arc needs — the thing reporting progress ends up white
      // on white. So: the unswept remainder stays grey at *every* dwell, and it
      // is the arc that is white.
      final model = modelWith(
        sessionState(plan: plan, guidance: guidanceState()),
      );
      addTearDown(model.dispose);
      final state = await pumpHud(tester, model);
      final cache = state.cache;
      final layout = cache.layout(
        size: size,
        safeArea: EdgeInsets.zero,
        previewAspectRatio: previewAspect,
        plan: plan,
      );

      for (final dwell in [0.1, 0.3, 0.5, 0.7, 0.9]) {
        model.state = sessionState(
          plan: plan,
          guidance: guidanceState(dwellProgress: dwell),
        );
        final rendered = await render(tester, painterFor(model, cache: cache));
        final radius = layout.ringRadiusFor(dwell);
        // Just *behind* twelve o'clock going clockwise — i.e. the last place the
        // arc will reach, whatever the dwell.
        final angle = -math.pi / 2 - 0.25;
        final unswept = Offset(
          centreX + radius * math.cos(angle),
          centreY + radius * math.sin(angle),
        );
        final red = rendered.redAt(unswept.dx, unswept.dy);
        expect(
          red,
          greaterThan(60),
          reason: 'the track has gone missing at dwell $dwell',
        );
        expect(
          red,
          lessThan(230),
          reason: 'the track has gone white at dwell $dwell',
        );
      }
    });
  });

  group('the progress bar', () {
    testWidgets('has one segment per target, gapped at every ring boundary', (
      tester,
    ) async {
      final model = modelWith(sessionState(plan: plan, capturedCount: 7));
      addTearDown(model.dispose);
      final state = await pumpHud(tester, model);
      final layout = state.cache.layout(
        size: size,
        safeArea: EdgeInsets.zero,
        previewAspectRatio: previewAspect,
        plan: plan,
      );

      expect(layout.segments.length, plan.targets.length);
      expect(plan.targets.length, 29);

      for (var i = 1; i < plan.targets.length; i++) {
        final gap = layout.segments[i].left - layout.segments[i - 1].right;
        final boundary =
            plan.targets[i].ringIndex != plan.targets[i - 1].ringIndex;
        expect(
          gap,
          closeTo(
            boundary
                ? CaptureHudMetrics.progressRingGap
                : CaptureHudMetrics.progressSegmentGap,
            1e-9,
          ),
          reason: 'gap before target $i (${plan.targets[i].ringLabel})',
        );
      }
      // Five rings in the worked example — three rings and the zenith pair —
      // so four wider gaps, which is the only structure the bar carries.
      final boundaries = [
        for (var i = 1; i < plan.targets.length; i++)
          if (plan.targets[i].ringIndex != plan.targets[i - 1].ringIndex) i,
      ];
      expect(boundaries.length, plan.ringIndices.length - 1);
    });

    testWidgets('fills as positions are captured', (tester) async {
      final model = modelWith(sessionState(plan: plan));
      addTearDown(model.dispose);
      final state = await pumpHud(tester, model);
      final layout = state.cache.layout(
        size: size,
        safeArea: EdgeInsets.zero,
        previewAspectRatio: previewAspect,
        plan: plan,
      );
      final first = layout.segments.first;
      final third = layout.segments[2];

      final none = await render(tester, painterFor(model, cache: state.cache));
      expect(none.redAt(first.center.dx, first.center.dy), lessThan(80));

      model.state = sessionState(plan: plan, capturedCount: 2);
      final two = await render(tester, painterFor(model, cache: state.cache));
      expect(two.redAt(first.center.dx, first.center.dy), greaterThan(200));
      expect(two.redAt(third.center.dx, third.center.dy), lessThan(80));
    });
  });

  group('the painter allocates nothing per frame', () {
    test('100 frames of moving dot, filling ring and flash build nothing', () {
      // Phase 09 §5. The overlay repaints on every pose sample — ~100 Hz — while
      // the device is also running a camera preview, a sensor stream and a JPEG
      // burst, so a garbage collection here is a dropped frame in the one place
      // the user is looking while turning.
      //
      // `buildCount` counts every object the paint path can create: the layout
      // and the four paragraphs. Everything else — paints, the arrow path, the
      // flash ramp — is built in the cache's constructor before any frame, and
      // the paint methods construct no `Offset`, `Rect` or `Color` at all
      // (canvas translation and pre-quantised paints instead).
      final model = CaptureHudModel(
        plan: plan,
        state: sessionState(
          plan: plan,
          capturedCount: 7,
          guidance: guidanceState(hint: GuidanceHint.turnRight),
        ),
      );
      addTearDown(model.dispose);
      final cache = CaptureHudCache();
      addTearDown(cache.dispose);
      final painter = CaptureHudPainter(
        model: model,
        cache: cache,
        previewAspectRatio: previewAspect,
      );

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Offset.zero & size);
      painter.paint(canvas, size);
      final afterFirstFrame = cache.buildCount;
      expect(afterFirstFrame, greaterThan(0), reason: 'the first frame builds');

      for (var frame = 1; frame <= 100; frame++) {
        final t = frame / 100;
        model.state = sessionState(
          plan: plan,
          capturedCount: 7,
          guidance: guidanceState(
            offsetX: math.cos(t * math.pi) * 0.8,
            offsetY: math.sin(t * math.pi) * 0.8,
            hint: GuidanceHint.turnRight,
            withinAimTolerance: false,
            dwellProgress: t,
          ),
        );
        model.flashOpacity = 1 - t;
        painter.paint(canvas, size);
      }
      recorder.endRecording().dispose();

      expect(
        cache.buildCount,
        afterFirstFrame,
        reason: '100 frames must build nothing beyond the first',
      );
    });

    test('a changed counter or sentence rebuilds once, not once per frame', () {
      final model = CaptureHudModel(
        plan: plan,
        state: sessionState(plan: plan, guidance: guidanceState()),
      );
      addTearDown(model.dispose);
      final cache = CaptureHudCache();
      addTearDown(cache.dispose);
      final painter = CaptureHudPainter(
        model: model,
        cache: cache,
        previewAspectRatio: previewAspect,
      );
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Offset.zero & size);
      painter.paint(canvas, size);
      final baseline = cache.buildCount;

      model.state = sessionState(
        plan: plan,
        capturedCount: 1,
        guidance: guidanceState(
          hint: GuidanceHint.turnRight,
          withinAimTolerance: false,
        ),
      );
      painter.paint(canvas, size);
      // Two paragraphs for the counter, two for the sentence — and then nothing
      // for as long as both stay the same, which is the 29-times-a-session rate
      // rather than the 100-times-a-second one.
      final afterChange = cache.buildCount;
      expect(afterChange, baseline + 2);
      for (var i = 0; i < 20; i++) {
        painter.paint(canvas, size);
      }
      expect(cache.buildCount, afterChange);
      recorder.endRecording().dispose();
    });
  });
}
