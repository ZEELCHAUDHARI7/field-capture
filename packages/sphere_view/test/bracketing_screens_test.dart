import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'fixtures.dart';
import 'hud_fixtures.dart';

/// Phase 09 §3: the two thin screens that let the capture screen stay minimal.
///
/// The pre-capture screen exists for one sentence. "Pivot, don't walk" is the
/// parallax mitigation from architecture §3, and parallax is the limit this
/// project cannot code around — a 10 cm swing puts 97 px of irreducible
/// disparity on a wall at 1 m. Graph-cut hides it; nothing removes it. So the
/// sentence, and the diagram beside it, are load-bearing engineering, and a test
/// that they are actually on screen is not a formality.
///
/// The review screen exists for the opposite reason: to say what went wrong in
/// words a manager can act on. §3.3 states it negatively — **never** a generic
/// "stitching may be imperfect" — and that is what these assert.
void main() {
  late CapturePlan plan;

  setUpAll(() => plan = buildFixturePlan());

  Future<void> pumpScreen(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(500, 1000)),
          child: child,
        ),
      ),
    );
    await tester.pump();
  }

  group('the pre-capture screen', () {
    testWidgets('coaches the pivot, and shows what it is about to cost', (
      tester,
    ) async {
      var started = 0;
      await pumpScreen(
        tester,
        SpherePreCaptureScreen(
          plan: plan,
          onStart: () => started++,
          monopodNote: 'A clamp is in the site cabin — use it if you can.',
        ),
      );

      expect(find.text('Stand where the pin is.'), findsOneWidget);
      expect(find.text('Hold the tablet upright, arms in.'), findsOneWidget);
      expect(
        find.text('Turn your body slowly — pivot, don’t walk.'),
        findsOneWidget,
      );
      expect(find.byType(PivotDiagram), findsOneWidget);
      // 29 positions at ~3.1 s each, rounded to ten seconds — S7's budget, not
      // a guess dressed up as a measurement.
      expect(find.text('29 photos · about 90 seconds'), findsOneWidget);
      expect(
        find.text('A clamp is in the site cabin — use it if you can.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Start'));
      expect(started, 1);
    });

    test('the estimate follows the plan rather than a constant', () {
      expect(SpherePreCaptureScreen.estimateFor(29).inSeconds, 90);
      expect(
        SpherePreCaptureScreen.estimateFor(45).inSeconds,
        greaterThan(SpherePreCaptureScreen.estimateFor(29).inSeconds),
      );
    });
  });

  group('the review screen', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('sphere_review_test');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    testWidgets('says what is wrong in words, never "may be imperfect"', (
      tester,
    ) async {
      final report = StitchReport(
        rmsReprojectionErrorPx: 5.4,
        loopClosureErrorDegrees: 0.9,
        maxGainRatio: 1.12,
        coverageFraction: 0.94,
        refinedFocalPx: 3200,
        refinedIntrinsics: sampleIntrinsics,
        residualTiltDegrees: 1.4,
        droppedPositionIndices: const [3, 8, 19],
        warnings: const [
          StitchWarning(
            StitchWarningCode.bracketingUnavailable,
            detail: 'the camera reported BracketMode.singleShot',
          ),
        ],
        elapsedMs: 42000,
        tierUsed: QualityTier.mid,
      );
      var saved = 0;
      await pumpScreen(
        tester,
        SphereReviewScreen(
          bundle: sampleBundle(root),
          report: report,
          onSave: () => saved++,
        ),
      );

      // On screen, above the fold. The list is lazy, so the full set is
      // asserted on the sentences themselves rather than on which of them
      // happened to be laid out.
      // The report's own coded warnings come first — a cause explains a symptom,
      // and "this tablet cannot bracket" explains a white window three stages
      // before "brightness varies" does — so the first sentence on screen is the
      // device's own limit. The list is lazy, so everything below the fold is
      // asserted on the sentences rather than on laid-out widgets.
      expect(
        find.textContaining('cannot take a bracket of three exposures'),
        findsOneWidget,
      );

      final sentences = CaptureWarnings.sentencesForReport(report).join('\n');
      expect(sentences, contains('3 photos were too blurry'));
      expect(sentences, contains('covers 94% of the sphere'));
      expect(sentences, contains('5.4 pixels'));
      expect(sentences, contains('0.90° away from where it started'));
      expect(sentences, contains('varies by up to 12%'));
      expect(sentences, contains('off level by 1.4°'));
      expect(
        sentences,
        contains('cannot take a bracket of three exposures'),
        reason:
            'the report\'s own coded warnings reach the user too, not just the '
            'criteria derived from its numbers',
      );
      // Every sentence names a number or a specific thing to do, because a
      // warning a manager cannot act on costs them the whole capture and tells
      // them nothing.
      expect(sentences, isNot(contains('may be imperfect')));
      expect(sentences, isNot(contains('something went wrong')));
      for (final sentence in CaptureWarnings.sentencesForReport(report)) {
        // A number, or a named cause. Every sentence has to give the reader
        // something to act on rather than a shrug; the exhaustive check on the
        // whole table lives in warning_messages_test.dart.
        expect(
          RegExp(r'[0-9]').hasMatch(sentence) ||
              RegExp(r'cannot|does not|too hot|compass').hasMatch(sentence),
          isTrue,
          reason: 'not specific enough: "$sentence"',
        );
      }

      await tester.tap(find.text('Save'));
      expect(saved, 1);
    });

    testWidgets('a clean capture says so, and offers a retake list', (
      tester,
    ) async {
      final retaken = <int>[];
      await pumpScreen(
        tester,
        SphereReviewScreen(
          bundle: CaptureBundle(
            sessionId: 'clean',
            directory: root,
            plan: samplePlan,
            intrinsics: sampleIntrinsics,
            positions: [
              for (var i = 0; i < samplePlan.length; i++)
                CapturedPosition(
                  targetIndex: i,
                  pose: samplePose(),
                  shots: sampleShots,
                  sharpness: 120,
                  steadinessRadPerSec: 0.01,
                ),
            ],
            deviceInfo: const {},
          ),
          onSave: () {},
          onRetake: retaken.add,
        ),
      );

      expect(
        find.text('Nothing was compromised in this capture.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Retake position…'));
      await tester.pump();
      expect(find.text('Retake'), findsWidgets);
      await tester.tap(find.text('Retake').first);
      expect(retaken, [0]);
    });

    test('an incomplete capture describes itself rather than complaining', () {
      final bundle = CaptureBundle(
        sessionId: 'partial',
        directory: root,
        plan: plan,
        intrinsics: sampleIntrinsics,
        positions: [
          for (var i = 0; i < 12; i++)
            CapturedPosition(
              targetIndex: i,
              pose: samplePose(),
              shots: sampleShots,
              sharpness: 120,
              steadinessRadPerSec: 0.01,
            ),
        ],
        deviceInfo: const {'warnings': <String>[]},
      );
      final messages = CaptureWarnings.sentencesForBundle(bundle);
      expect(messages.single, contains('17 of 29 photos were not taken'));
      expect(messages.single, contains('rather than invented'));
    });

    test('a report that meets every target produces no warnings at all', () {
      final clean = StitchReport(
        rmsReprojectionErrorPx: 0.4,
        loopClosureErrorDegrees: 0.1,
        maxGainRatio: 1.01,
        coverageFraction: 1,
        refinedFocalPx: 3200,
        refinedIntrinsics: sampleIntrinsics,
        residualTiltDegrees: 0.05,
        droppedPositionIndices: const [],
        warnings: const [],
        elapsedMs: 30000,
        tierUsed: QualityTier.mid,
      );
      expect(clean.meetsQualityTargets, isTrue);
      expect(CaptureWarnings.forReport(clean), isEmpty);
    });
  });
}
