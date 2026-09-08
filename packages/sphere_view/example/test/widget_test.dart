import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:example/main.dart';
import 'package:example/stations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:vector_math/vector_math_64.dart';

/// The demo's own regression tests, and one of them is the point of the demo.
///
/// Flow 2 — capture two or three spheres back to back without waiting — is the
/// behaviour the real use case depends on and the easiest thing to break by
/// accident, because breaking it looks like nothing: the panoramas still come
/// out, they just come out one at a time with the user standing still between
/// them. It cannot be proved on a device without a site visit, and it does not
/// need one: with a fake stitcher the whole queue runs on a laptop in
/// milliseconds, kill included.
///
/// Everything that touches the queue or the disk runs inside
/// [WidgetTester.runAsync]. `testWidgets` puts timers and microtasks on a fake
/// clock that only `pump` advances, so a genuine `await` on file I/O inside the
/// test body deadlocks — and the deadlock looks like a hung test rather than
/// like a mistake in the test.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sv_demo');
  });

  tearDown(() async {
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } on FileSystemException {
      // The queue's own cleanup may still be running; a temp directory that
      // will not delete is not a test failure.
    }
  });

  StationStore makeStore(_FakeStitcher stitcher, {QualityTier? previewTier}) {
    final queue = StitchQueue(
      directory: Directory('${root.path}/queue'),
      // Not the real platform: the queue asks for a thermal state before every
      // entry, and on a test host there is nobody to answer.
      platform: _NoPlatform(),
      stitcherFactory: ({tier}) => stitcher,
      // Off unless a test asks: with previews on, every station produces two
      // results and the assertions below would be counting both.
      previewTier: previewTier,
    );
    return StationStore(
      bundleRoot: Directory('${root.path}/bundles'),
      panoramaRoot: Directory('${root.path}/panoramas'),
      indexFile: File('${root.path}/stations.json'),
      queue: queue,
    );
  }

  testWidgets('the empty screen offers the three actions and nothing else', (
    tester,
  ) async {
    final store = makeStore(_FakeStitcher());
    await tester.runAsync(store.load);
    await tester.pumpWidget(SphereViewExampleApp(store: store));
    await tester.pump();

    expect(find.text('Capture a 360°'), findsOneWidget);
    expect(find.text('Device report'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
    expect(find.textContaining('No stations yet'), findsOneWidget);
    store.dispose();
  });

  testWidgets('two stations queued back to back both reach ready', (
    tester,
  ) async {
    final stitcher = _FakeStitcher();
    final store = makeStore(stitcher);
    late Station first;
    late Station second;

    await tester.runAsync(() async {
      await store.load();
      // Station 1 is captured and handed over. Nothing awaits its stitch —
      // which is exactly what the second capture, immediately after, depends
      // on.
      first = await store.begin();
      stitcher.hold(first.sessionId);
      await store.record(first, await _bundle(first));
      second = await store.begin();
      stitcher.hold(second.sessionId);
      await store.record(second, await _bundle(second));
      await _until(() => stitcher.running.contains(first.sessionId));
    });

    await tester.pumpWidget(SphereViewExampleApp(store: store));
    await tester.pump();

    // Serial by design — two concurrent stitches would run a device out of
    // memory — so the second is waiting while the first works.
    expect(find.textContaining('stitching'), findsOneWidget);
    expect(find.textContaining('queued'), findsOneWidget);

    await tester.runAsync(() async {
      stitcher.release(first.sessionId);
      await _until(() => store.resultFor(first) != null);
      await _until(() => stitcher.running.contains(second.sessionId));
    });
    await tester.pump();
    expect(find.textContaining('ready'), findsOneWidget);
    expect(find.textContaining('stitching'), findsOneWidget);

    await tester.runAsync(() async {
      stitcher.release(second.sessionId);
      await _until(() => store.resultFor(second) != null);
    });
    await tester.pump();
    expect(find.textContaining('ready'), findsNWidgets(2));
    // The metrics line is flow 4's entry point, so it has to be there for both.
    expect(find.textContaining('coverage'), findsNWidgets(2));

    await tester.runAsync(() => store.queue.stop());
    store.dispose();
  });

  testWidgets('progress reaches the row as a percentage while it runs', (
    tester,
  ) async {
    final stitcher = _FakeStitcher();
    final store = makeStore(stitcher);
    late Station station;

    await tester.runAsync(() async {
      await store.load();
      station = await store.begin();
      stitcher.hold(station.sessionId);
      await store.record(station, await _bundle(station));
      await _until(() => stitcher.running.contains(station.sessionId));
      stitcher.report(
        station.sessionId,
        const StitchProgress(stage: StitchStage.warping, fraction: 0.42),
      );
    });

    await tester.pumpWidget(SphereViewExampleApp(store: store));
    await tester.pump();

    // A row that says `queued` forever is what a queue that never drains looks
    // like, so the percentage arriving is the assertion, not decoration.
    expect(find.textContaining('stitching 42%'), findsOneWidget);
    expect(find.textContaining('warping'), findsOneWidget);

    await tester.runAsync(() async {
      stitcher.release(station.sessionId);
      await _until(() => store.resultFor(station) != null);
      await store.queue.stop();
    });
    store.dispose();
  });

  testWidgets('a capture killed part-way comes back as a resumable station', (
    tester,
  ) async {
    final reopened = makeStore(_FakeStitcher());
    await tester.runAsync(() async {
      // The kill: a store that registered a station and wrote a partial
      // bundle, then stopped existing without ever calling `record`.
      final killed = makeStore(_FakeStitcher());
      await killed.load();
      final station = await killed.begin();
      await _bundle(station, positions: 12);
      killed.dispose();

      // The reopen. Nothing about this path is special-cased for recovery — it
      // is the same `load()` every cold start runs.
      await reopened.load();
    });

    await tester.pumpWidget(SphereViewExampleApp(store: reopened));
    await tester.pump();

    expect(
      reopened.phaseOf(reopened.stations.single),
      StationPhase.interrupted,
    );
    expect(find.textContaining('capture interrupted'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    reopened.dispose();
  });

  test('a stitch killed mid-run is picked back up, not lost', () async {
    final stitcher = _FakeStitcher();
    final killed = makeStore(stitcher);
    await killed.load();
    final station = await killed.begin();
    stitcher.hold(station.sessionId);
    await killed.record(station, await _bundle(station));
    // The queue writes `running` *before* the work starts, which is the whole
    // reason a kill is recoverable rather than merely survivable.
    await _until(() => stitcher.running.contains(station.sessionId));
    killed.dispose();

    stitcher.release(station.sessionId);
    final reopened = makeStore(_FakeStitcher());
    await reopened.load();
    final entry = reopened.entryFor(reopened.stations.single)!;
    expect(entry.status, StitchQueueStatus.pending);
    expect(entry.interruptions, greaterThanOrEqualTo(1));
    // And it is not merely marked pending: draining actually finishes it.
    await reopened.start();
    await _until(() => reopened.resultFor(reopened.stations.single) != null);
    expect(reopened.resultFor(reopened.stations.single), isNotNull);
    reopened.dispose();
  });

  test(
    'a stitch that met its targets loses its bundle; one that did not keeps it',
    () async {
      // The storage policy from docs/INTEGRATION.md, as behaviour rather than
      // as a paragraph. Keeping the bad captures is what makes a pipeline
      // improvement re-runnable without going back to site.
      for (final passes in [true, false]) {
        final store = makeStore(_FakeStitcher(passing: passes));
        await store.load();
        final station = await store.begin();
        await store.record(station, await _bundle(station));
        await store.start();
        await _until(() => store.resultFor(station) != null);
        await _until(
          () => Directory(station.bundleDirectory).existsSync() != passes,
        );
        expect(
          Directory(station.bundleDirectory).existsSync(),
          !passes,
          reason: passes
              ? 'a stitch that met its targets should release the bundle'
              : 'a stitch that did not should keep it for a re-stitch',
        );
        store.dispose();
      }
    },
  );

  test('the fast preview does not delete the bundle the full pass needs', () async {
    // The storage policy releases the bundle once a panorama has met its
    // targets. Applied to the *preview* it would delete the very bundle the
    // full-resolution pass is about to read — a fast preview that destroys the
    // real stitch, which is worse than having no preview at all.
    //
    // The full pass is blocked so the assertion happens in a world that is
    // genuinely between the two. Neither polling nor listening works here: the
    // store starts the storage policy with `unawaited`, so at the instant the
    // preview event fires the delete has not run yet, and a test that checked
    // then would pass against the bug. Holding call 2 lets the event loop drain
    // completely first.
    final stitcher = _FakeStitcher(passing: true)..holdCall = 2;
    final store = makeStore(stitcher, previewTier: QualityTier.low);
    await store.load();
    final station = await store.begin();
    await store.record(station, await _bundle(station));
    await store.start();

    // Preview done, full pass parked.
    await _until(() => stitcher.calls == 2);
    await pumpEventQueue();

    expect(
      store.viewablePathFor(station),
      isNotNull,
      reason: 'the preview should be openable while the full pass runs',
    );
    expect(store.isPreviewOnly(station), isTrue);
    expect(
      Directory(station.bundleDirectory).existsSync(),
      isTrue,
      reason: 'the preview must not trigger the storage policy — the '
          'full-resolution pass still has to read this bundle',
    );

    // Let it finish; the policy applies as it always did.
    stitcher.holdCallGate.complete();
    await _until(() => !Directory(station.bundleDirectory).existsSync());
    expect(store.isPreviewOnly(station), isFalse);
    store.dispose();
  });

  test('a failed stitch can be retried, and the bundle is still there', () async {
    final stitcher = _FakeStitcher()..failEverything = true;
    final store = makeStore(stitcher);
    await store.load();
    final station = await store.begin();
    await store.record(station, await _bundle(station));
    await store.start();
    await _until(() => store.phaseOf(station) == StationPhase.failed);
    expect(Directory(station.bundleDirectory).existsSync(), isTrue);

    stitcher.failEverything = false;
    await store.retry(station);
    await _until(() => store.resultFor(station) != null);
    expect(store.phaseOf(station), StationPhase.ready);
    store.dispose();
  });
}

/// Polls [condition] until it holds or five seconds pass.
///
/// A deadline rather than a round count, which is the shape of the flake the
/// 06–09 audit chased down in the package's own suite: forty rounds of
/// `pumpEventQueue` is plenty until the machine is loaded, and then it is not.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A saved `CaptureBundle` for [station], with [positions] of a full plan.
Future<CaptureBundle> _bundle(Station station, {int positions = 29}) async {
  final directory = Directory(station.bundleDirectory);
  await directory.create(recursive: true);
  final intrinsics = CameraIntrinsics.fromHorizontalFov(
    hfovRadians: 50 * math.pi / 180,
    imageSize: const ImageSize(3024, 4032),
    source: IntrinsicsSource.derivedFromPhysics,
  );
  final plan = const PlanBuilder().buildPlan(intrinsics: intrinsics);
  final bundle = CaptureBundle(
    sessionId: station.sessionId,
    directory: directory,
    plan: plan,
    intrinsics: intrinsics,
    positions: [
      for (var i = 0; i < math.min(positions, plan.length); i++)
        CapturedPosition(
          targetIndex: plan.targets[i].index,
          pose: DevicePose(
            deviceToWorld: Quaternion.identity(),
            gravityWorld: Vector3(0, 1, 0),
            timestampUs: 1000 + i,
            angularSpeedRadPerSec: 0.01,
          ),
          shots: [ExposureShot(filePath: 'p$i.jpg', evBias: 0, timestampUs: i)],
          sharpness: 120,
          steadinessRadPerSec: 0.02,
        ),
    ],
    deviceInfo: const {},
  );
  await bundle.save();
  return bundle;
}

/// A stitcher that produces a result without going anywhere near OpenCV, and
/// can be held open so a test can look at the row while it is running.
class _FakeStitcher extends SphereStitcher {
  _FakeStitcher({this.passing = true});

  /// Whether the report it produces meets its quality targets.
  final bool passing;

  /// Makes every stitch throw, for the retry test.
  bool failEverything = false;

  final Map<String, Completer<void>> _held = {};
  final Map<String, void Function(StitchProgress)> _listeners = {};

  /// Sessions whose stitch has actually started.
  final Set<String> running = {};

  /// Blocks the stitch of [sessionId] until [release].
  void hold(String sessionId) => _held[sessionId] = Completer<void>();

  /// How many times [stitch] has been entered. Two per station once the queue
  /// runs a preview pass followed by the full-resolution one.
  int calls = 0;

  /// Blocks the *nth* call, so a test can inspect the world between the preview
  /// and the full pass. `hold` cannot do this: it keys on session id, and both
  /// passes of one station share it.
  int? holdCall;
  final Completer<void> holdCallGate = Completer<void>();

  /// Lets a held stitch finish.
  void release(String sessionId) {
    final completer = _held.remove(sessionId);
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// Pushes [progress] into a running stitch.
  void report(String sessionId, StitchProgress progress) =>
      _listeners[sessionId]?.call(progress);

  @override
  Future<StitchResult> stitch(
    CaptureBundle bundle, {
    void Function(StitchProgress progress)? onProgress,
    String? outputPath,
    PanoramaMetadata? metadata,
  }) async {
    final id = bundle.sessionId;
    calls++;
    if (holdCall == calls) await holdCallGate.future;
    running.add(id);
    if (onProgress != null) _listeners[id] = onProgress;
    onProgress?.call(
      const StitchProgress(stage: StitchStage.fusing, fraction: 0.05),
    );
    try {
      final held = _held[id];
      if (held != null) await held.future;
      if (failEverything) throw StateError('deliberate failure for $id');

      final path = outputPath ?? '${bundle.directory.path}/panorama.jpg';
      await File(path).parent.create(recursive: true);
      await File(path).writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);
      return StitchResult(
        equirectPath: path,
        width: QualityTier.mid.outputWidth,
        height: QualityTier.mid.outputHeight,
        report: _report(passing),
      );
    } finally {
      _listeners.remove(id);
      running.remove(id);
    }
  }

  static StitchReport _report(bool passing) => StitchReport(
    rmsReprojectionErrorPx: passing ? 0.42 : 6.8,
    loopClosureErrorDegrees: passing ? 0.08 : 1.4,
    maxGainRatio: 1.01,
    coverageFraction: 1,
    refinedFocalPx: 3242.6,
    refinedIntrinsics: CameraIntrinsics(
      fx: 3242.6,
      fy: 3242.6,
      cx: 1512,
      cy: 2016,
      imageSize: const ImageSize(3024, 4032),
      source: IntrinsicsSource.refinedByStitcher,
    ),
    residualTiltDegrees: 0.05,
    droppedPositionIndices: const [],
    warnings: const [],
    elapsedMs: 41000,
    tierUsed: QualityTier.mid,
  );
}

/// The queue asks for a thermal state before every entry. On a test host there
/// is nobody to answer, and a probe that throws must not stall the queue — this
/// is the class that proves it does not.
class _NoPlatform implements SphereCameraPlatform {
  @override
  Future<ThermalState> thermalState() async =>
      throw UnimplementedError('no platform on a test host');

  @override
  Stream<ThermalState> get thermalStates => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not needed here');
}
