import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'capture_fixtures.dart';

/// Phase 09 §6, the screen half: the capture view driven by a real
/// [SphereCaptureSession] over the Phase 08 fakes.
///
/// A real session rather than a stub, because the claims worth testing here are
/// claims about the *seam*: that the flash and the haptic follow a capture the
/// session decided on, that the manual button reaches the session and nothing
/// else, that an interruption loses nothing. A stubbed session would let the
/// widget re-implement any of that and still pass.
///
/// Everything that touches the disk runs inside [WidgetTester.runAsync]: the
/// session writes JPEGs and rewrites `bundle.json` after every position, and
/// real file I/O never completes inside a `testWidgets` fake-async zone.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sphere_view_ui_test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Everything a driven capture screen needs.
  Future<
    ({
      SphereCaptureSession session,
      FakeCameraPlatform camera,
      FakePoseSource poses,
      List<String> platformCalls,
      List<CaptureBundle> completed,
    })
  >
  pumpCaptureView(
    WidgetTester tester, {
    SphereCaptureConfig config = const SphereCaptureConfig(),
    bool lockOrientation = false,
  }) async {
    final platformCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(
          call.arguments == null
              ? call.method
              : '${call.method}(${call.arguments})',
        );
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final camera = FakeCameraPlatform(intrinsics: fovIntrinsics(50, 69));
    final poses = FakePoseSource();
    late final SphereCaptureSession session;
    await tester.runAsync(() async {
      session = await SphereCaptureSession.create(
        config: config,
        camera: camera,
        poseSource: poses,
        directory: root,
        sessionId: 'ui-test',
        wakelock: FakeWakelock(),
        measureSharpness: (_) async => 100,
      );
    });

    final completed = <CaptureBundle>[];
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: SphereCaptureView(
            session: session,
            lockOrientation: lockOrientation,
            previewBuilder: (_) => const ColoredBox(color: Color(0xFF303030)),
            onCompleted: completed.add,
          ),
        ),
      ),
    );
    // Metering and the first `bundle.json` both need real async, and the
    // sequence — attach the preview, sweep, lock, write an empty manifest —
    // crosses the fake/real boundary several times, so it is driven rather
    // than assumed.
    await settleUntilCapturing(tester, session);

    return (
      session: session,
      camera: camera,
      poses: poses,
      platformCalls: platformCalls,
      completed: completed,
    );
  }

  /// Aims at the current target, holds still, and lets the dwell expire.
  Future<void> shootOne(
    WidgetTester tester,
    SphereCaptureSession session,
    FakePoseSource poses,
    FakeCameraPlatform camera, {
    required int fromClockUs,
  }) async {
    final target = session.currentTarget;
    if (target == null) return;
    final before = session.positions.length;
    var clockUs = fromClockUs;
    // Arrive, hold, and hold past the 350 ms dwell. The clock is the pose
    // clock, which is the same monotonic base the camera stamps frames with, so
    // the shutter always lands inside the buffered window.
    for (final offsetMs in [0, 100, 400]) {
      clockUs += offsetMs * 1000;
      camera.nextShutterUs = clockUs;
      await tester.runAsync(() async {
        poses.emit(poseAtTarget(target, timestampUs: clockUs));
        await pumpEventQueue();
      });
      await tester.pump();
    }
    // The bracket, the pose interpolation, the sharpness read and the manifest
    // rewrite alternate between real file I/O and callbacks that only run when
    // the fake clock is pumped, so both have to be driven in turn. Stopping at
    // either one leaves the capture half-finished and the assertion racing it.
    for (var i = 0;
        i < 60 &&
            (session.isCapturingPosition ||
                (session.positions.length == before &&
                    session.currentTarget == target));
        i++) {
      await tester.runAsync(() async => pumpEventQueue());
      await tester.pump();
    }
  }

  /// The preview and the marks over it have to be in **one** frame.
  ///
  /// Both platforms hand back the sensor's own buffer — landscape, behind a
  /// portrait-locked screen — so the view has to turn it. This is the defect that
  /// made a correct projection look broken: with the scene a quarter turn out,
  /// panning right slid it *down* while the dot slid right, which reads as "the dot
  /// moves as I move the camera" and sends you looking at the guidance maths.
  ///
  /// Two things are asserted because two separate mistakes were made here, and
  /// each is invisible to the other's test:
  ///
  /// * the texture is **rotated**, or the scene is sideways;
  /// * it is fitted with **cover**, not `fill`. `fill` scales each axis
  ///   independently, so any disagreement between the texture's aspect and the
  ///   box's comes out as a squashed scene rather than a crop. That shipped, and a
  ///   photograph of a stretched preview is what found it.
  /// Pumps the real preview — the other tests stub a flat colour, which is why
  /// neither of the two mistakes below was caught — and returns the session.
  Future<SphereCaptureSession> pumpRealPreview(
    WidgetTester tester, {
    required FakeCameraPlatform camera,
    String sessionId = 'preview-frame-test',
  }) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    late final SphereCaptureSession session;
    await tester.runAsync(() async {
      session = await SphereCaptureSession.create(
        camera: camera,
        poseSource: FakePoseSource(),
        directory: root,
        sessionId: sessionId,
        wakelock: FakeWakelock(),
        measureSharpness: (_) async => 100,
      );
    });
    addTearDown(() => tester.runAsync(session.dispose));

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: SphereCaptureView(
            session: session,
            lockOrientation: false,
            onCompleted: (_) {},
          ),
        ),
      ),
    );
    await tester.runAsync(() async => pumpEventQueue());
    await tester.pump();
    return session;
  }

  ({int turns, BoxFit fit, Size box}) previewTree(WidgetTester tester) {
    final rotated = tester.widget<RotatedBox>(
      find.ancestor(of: find.byType(Texture), matching: find.byType(RotatedBox)),
    );
    final fitted = tester.widget<FittedBox>(
      find.ancestor(of: find.byType(Texture), matching: find.byType(FittedBox)),
    );
    final sized = tester.widget<SizedBox>(
      find.ancestor(of: find.byType(Texture), matching: find.byType(SizedBox)),
    );
    return (
      turns: rotated.quarterTurns,
      fit: fitted.fit,
      box: Size(sized.width ?? 0, sized.height ?? 0),
    );
  }

  /// The preview and the marks over it have to be in **one** frame, and the frame
  /// the buffer arrives in is something only the platform knows.
  ///
  /// Three separate mistakes were made here and each is invisible to the others'
  /// test, so all three are asserted:
  ///
  /// * the turn must be the one the **platform reported**, not one derived from the
  ///   sensor mounting. Deriving it turned an already-upright Galaxy S24 preview
  ///   sideways while every unit test agreed with the derivation;
  /// * the fit must be `cover`, never `fill` — `fill` scales each axis
  ///   independently, so a box that disagrees with the content squashes it;
  /// * the box must be sized in the frame the content is actually in, or `cover`
  ///   fits a landscape rectangle over portrait content and stretches it.
  testWidgets('a platform that does not rotate gets the turn and a sensor-frame box', (
    tester,
  ) async {
    final session = await pumpRealPreview(
      tester,
      camera: FakeCameraPlatform(
        intrinsics: fovIntrinsics(50, 69, width: 4032),
        sensorOrientationDegrees: 90,
      ),
    );

    expect(session.previewQuarterTurns, 1);
    final tree = previewTree(tester);
    expect(tree.turns, 1, reason: 'the platform said it did not rotate');
    expect(
      tree.fit,
      BoxFit.cover,
      reason: 'BoxFit.fill stretches each axis independently — a squashed scene',
    );
    // Landscape box: rotating it a quarter turn is what produces the portrait
    // rectangle the dots are placed against.
    expect(tree.box, const Size(1280, 960));
    expect(session.previewAspectRatio, closeTo(960 / 1280, 1e-9));
  });

  testWidgets('a platform that already rotated gets no turn and a portrait box', (
    tester,
  ) async {
    // The Galaxy S24 case: Flutter's legacy texture path applies the SurfaceTexture
    // transform, so the buffer reaching the canvas is already upright. Rotating it
    // again is the bug this test exists to prevent — and note the sensor still
    // reports a 90° mounting, so anything deriving from *that* gets it wrong.
    final session = await pumpRealPreview(
      tester,
      sessionId: 'preview-handled-test',
      camera: FakeCameraPlatform(
        intrinsics: fovIntrinsics(50, 69, width: 4032),
        sensorOrientationDegrees: 90,
        previewRotationDegrees: 0,
        previewHandlesRotation: true,
      ),
    );

    expect(session.previewQuarterTurns, 0);
    final tree = previewTree(tester);
    expect(tree.turns, 0, reason: 'the platform already turned the buffer');
    expect(tree.fit, BoxFit.cover);
    // Portrait box, because the content is already portrait. Sizing this from the
    // reported landscape previewSize is what stretched it on device.
    expect(tree.box, const Size(960, 1280));
    expect(session.previewAspectRatio, closeTo(960 / 1280, 1e-9));
  });

  testWidgets('the flash and exactly one haptic follow every capture', (
    tester,
  ) async {
    final ctx = await pumpCaptureView(tester);
    addTearDown(() => tester.runAsync(ctx.session.dispose));
    expect(ctx.session.phase, SessionPhase.capturing);

    final model = tester.widget<CaptureHud>(find.byType(CaptureHud)).model;
    // Count the *starts* of the flash rather than its samples: the claim is
    // that it fires once per capture, not that it animates.
    var flashStarts = 0;
    var wasDark = true;
    model.addListener(() {
      if (wasDark && model.flashOpacity > 0.99) flashStarts++;
      wasDark = model.flashOpacity < 0.01;
    });

    final haptics = <String>[];
    void collect() {
      haptics
        ..clear()
        ..addAll(
          ctx.platformCalls.where((c) => c.startsWith('HapticFeedback.vibrate')),
        );
    }

    await shootOne(
      tester,
      ctx.session,
      ctx.poses,
      ctx.camera,
      fromClockUs: 2000000,
    );
    expect(ctx.session.positions.length, 1);
    expect(flashStarts, 1, reason: 'one flash, and only one');
    collect();
    expect(haptics.length, 1);
    // Light for a frame; the heavier ones are reserved for finishing a row and
    // finishing the plan (§5).
    expect(haptics.single, contains('lightImpact'));

    // 120 ms later the reticle is back to normal and nothing has fired again.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(model.flashOpacity, 0);
    expect(flashStarts, 1);
    collect();
    expect(haptics.length, 1);

    await shootOne(
      tester,
      ctx.session,
      ctx.poses,
      ctx.camera,
      fromClockUs: 5000000,
    );
    expect(ctx.session.positions.length, 2);
    expect(flashStarts, 2);
    collect();
    expect(haptics.length, 2);
  });

  testWidgets('a rejected frame flashes nothing and says why', (tester) async {
    // Sharpness below the floor: the session rejects the position, keeps the
    // target at the head of the queue, and hands the UI a sentence written for
    // a manager rather than for a log.
    final camera = FakeCameraPlatform(intrinsics: fovIntrinsics(50, 69));
    final poses = FakePoseSource();
    late final SphereCaptureSession session;
    await tester.runAsync(() async {
      session = await SphereCaptureSession.create(
        camera: camera,
        poseSource: poses,
        directory: root,
        sessionId: 'ui-reject',
        wakelock: FakeWakelock(),
        measureSharpness: (_) async => 1,
      );
    });
    addTearDown(() => tester.runAsync(session.dispose));

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: SphereCaptureView(
            session: session,
            lockOrientation: false,
            previewBuilder: (_) => const ColoredBox(color: Color(0xFF303030)),
            onCompleted: (_) {},
          ),
        ),
      ),
    );
    await settleUntilCapturing(tester, session);

    final model = tester.widget<CaptureHud>(find.byType(CaptureHud)).model;
    await shootOne(tester, session, poses, camera, fromClockUs: 2000000);

    expect(session.positions, isEmpty);
    expect(model.flashOpacity, 0);
    expect(model.instruction, 'Too blurry — hold still');
  });

  testWidgets('both buttons are labelled and big enough for a glove', (
    tester,
  ) async {
    final ctx = await pumpCaptureView(tester);
    addTearDown(() => tester.runAsync(ctx.session.dispose));
    final semantics = tester.ensureSemantics();

    expect(find.bySemanticsLabel('Exit capture'), findsOneWidget);
    expect(find.bySemanticsLabel('Take the photo now'), findsOneWidget);

    for (final label in ['Exit capture', 'Take the photo now']) {
      final size = tester.getSize(
        find.descendant(
          of: find.bySemanticsLabel(label),
          matching: find.byType(SizedBox),
        ),
      );
      // §4's floor is 56 dp; these are 64.
      expect(size.width, greaterThanOrEqualTo(56));
      expect(size.height, greaterThanOrEqualTo(56));
    }

    // Nothing interactive in the top half — that is where the user's attention
    // is supposed to be on the scene, not on the screen.
    for (final label in ['Exit capture', 'Take the photo now']) {
      expect(
        tester.getCenter(find.bySemanticsLabel(label)).dy,
        greaterThan(400),
      );
    }
    semantics.dispose();
  });

  testWidgets('the manual shutter asks the session and decides nothing', (
    tester,
  ) async {
    final ctx = await pumpCaptureView(tester);
    addTearDown(() => tester.runAsync(ctx.session.dispose));
    final semantics = tester.ensureSemantics();

    // No pose has ever been on target, so the gates would never have fired.
    // The button is the override, and the *session* is what overrides.
    await tester.runAsync(() async {
      ctx.camera.nextShutterUs = 3000000;
      ctx.poses.emit(
        poseAimedAt(3.0, 0.4, timestampUs: 3000000, angularSpeedRadPerSec: 0),
      );
      await pumpEventQueue();
    });
    await tester.pump();
    expect(ctx.session.positions, isEmpty);

    await tester.tap(find.bySemanticsLabel('Take the photo now'));
    await drive(tester, until: () => ctx.session.positions.isNotEmpty);

    expect(ctx.session.positions.length, 1);
    expect(ctx.camera.requestedBiases.length, 1);
    semantics.dispose();
  });

  testWidgets('an interruption pauses cleanly and loses no position', (
    tester,
  ) async {
    final ctx = await pumpCaptureView(tester);
    addTearDown(() => tester.runAsync(ctx.session.dispose));
    await shootOne(
      tester,
      ctx.session,
      ctx.poses,
      ctx.camera,
      fromClockUs: 2000000,
    );
    expect(ctx.session.positions.length, 1);

    await tester.runAsync(() async {
      ctx.camera.emitInterruption(true, 'a phone call');
      await pumpEventQueue();
    });
    await tester.pump();

    expect(ctx.session.phase, SessionPhase.paused);
    expect(find.text('Resume'), findsOneWidget);
    // The captured position is still there, and so is its manifest — a phone
    // call on a site is the normal case, not the exception.
    expect(ctx.session.positions.length, 1);
    expect(
      File('${root.path}${Platform.pathSeparator}bundle.json').existsSync(),
      isTrue,
    );

    await tester.tap(find.text('Resume'));
    await settleUntilCapturing(tester, ctx.session);
    expect(ctx.session.positions.length, 1);
  });

  testWidgets('exiting with work in hand asks before ending the session', (
    tester,
  ) async {
    final ctx = await pumpCaptureView(tester);
    final semantics = tester.ensureSemantics();
    await shootOne(
      tester,
      ctx.session,
      ctx.poses,
      ctx.camera,
      fromClockUs: 2000000,
    );

    await tester.tap(find.bySemanticsLabel('Exit capture'));
    await tester.pump();
    expect(find.text('Keep going'), findsOneWidget);
    expect(ctx.completed, isEmpty);

    await tester.tap(find.text('Keep going'));
    await tester.pump();
    expect(find.text('Keep going'), findsNothing);
    expect(ctx.session.phase, SessionPhase.capturing);

    await tester.tap(find.bySemanticsLabel('Exit capture'));
    await tester.pump();
    await tester.tap(find.text('Finish here'));
    await drive(tester, until: () => ctx.completed.isNotEmpty);

    // A partial capture is a bundle, not an error: the manager keeps the
    // twelve seconds of work they did (Phase 08 `finish`).
    expect(ctx.completed, hasLength(1));
    expect(ctx.completed.single.positions.length, 1);
    semantics.dispose();
  });

  testWidgets('the capture is locked to portrait for its whole length', (
    tester,
  ) async {
    final ctx = await pumpCaptureView(tester, lockOrientation: true);
    addTearDown(() => tester.runAsync(ctx.session.dispose));
    expect(
      ctx.platformCalls.where(
        (c) =>
            c.startsWith('SystemChrome.setPreferredOrientations') &&
            c.contains('portraitUp') &&
            !c.contains('landscape'),
      ),
      isNotEmpty,
      reason:
          'the plan is computed for one intrinsics/orientation pair, so a '
          'mid-session rotation would invalidate every remaining target',
    );
  });

  test('the view holds no capture logic', () {
    // Phase 09's "assert by review", made cheap enough to run every time.
    //
    // The gates live in Phase 08 and only there. This does not prove the widget
    // is logic-free — nothing short of review does — but it catches the way it
    // would actually go wrong: a threshold copied into a build method during a
    // hurried fix, which then drifts from the one the shutter gate uses and
    // presents as a stitcher bug months later.
    final source = File('lib/src/api/sphere_capture_view.dart')
        .readAsStringSync();
    for (final forbidden in [
      'aimTolerance',
      'steadinessThreshold',
      'minSharpness',
      'dwellProgress',
      'angularError',
      'overlapFraction',
    ]) {
      expect(
        source,
        isNot(contains(forbidden)),
        reason: '$forbidden is Phase 08 vocabulary and must not appear here',
      );
    }
  });
}

/// Pumps until the session has finished metering and is guiding.
///
/// The metering sweep is a real 2 s animation and a real await on the camera,
/// so this alternates real async with frames until the session says it is
/// capturing — which is also the assertion that it ever gets there.
Future<void> settleUntilCapturing(
  WidgetTester tester,
  SphereCaptureSession session,
) async {
  await tester.pumpAndSettle();
  for (var i = 0; i < 60 && session.phase != SessionPhase.capturing; i++) {
    await tester.runAsync(() async => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    session.phase,
    SessionPhase.capturing,
    reason: 'the view never got the session out of metering',
  );
}

/// Alternates real async with frames until [until] holds.
///
/// Everything the session does is a chain of real file I/O and callbacks that
/// only run when the fake clock is pumped, so neither `runAsync` nor `pump`
/// alone gets a capture, a resume or a `finish()` to the end.
///
/// **Bounded by a round count, and it has to be — the deadline the Phase 10
/// audit prescribed was tried here and is wrong.** `phases/README.md` diagnosed
/// these tests' load flakiness as forty rounds no longer being enough for
/// `bundle.save()` to land, and prescribed a wall-clock bound. Implemented, it
/// turned three consecutive green runs into two failures out of three, and the
/// reason is that `rounds` is doing a second job nobody wrote down: it is *how
/// many frames of animation to advance*. `tester.pump()` with no duration does
/// not move the fake clock, so a condition that is not yet reachable is spun on
/// for the whole timeout — thousands of pumps — and the flash animation, the
/// haptics and the position counter are all somewhere else by the end of it. The
/// assertions after `drive` are about a specific number of frames having passed.
///
/// The load flakiness is real and it is **not fixed**. It reproduces on this file
/// with every helper in its original state — measured at roughly one failure in
/// five on a machine with other work on it — so it is a property of these tests
/// rather than of anything Phase 12 changed, and the deadline is not the answer.
/// What the deadline *did* fix is `settle` in `capture_session_test.dart`, which
/// is a pure wait-for-I/O loop with no frame semantics to disturb: ten suites now
/// run together green there, where "frames are on disk the moment the position is
/// accepted" failed under that load before.
///
/// Do not re-apply the deadline here without running this file at least three
/// times and reading the failures.
Future<void> drive(
  WidgetTester tester, {
  int rounds = 40,
  bool Function()? until,
}) async {
  for (var i = 0; i < rounds; i++) {
    if (until != null && until()) return;
    await tester.runAsync(() async => pumpEventQueue());
    await tester.pump();
  }
}
