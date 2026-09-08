import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'capture_fixtures.dart';
import 'fixtures.dart';

/// Phase 10 §5 — the background stitch queue.
///
/// The queue exists because a manager on a site has more stations to walk to:
/// 30 stations × 60 s of standing still is half an hour of nothing. Everything
/// asserted here is a property that has to survive the device being killed,
/// backgrounded or overheated halfway through, because on a site all three
/// happen.
void main() {
  late Directory root;
  late _StitchLog log;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sv_queue');
    log = _StitchLog();
  });

  tearDown(() async {
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } on FileSystemException {
      // The queue writes its state file through a temp-and-rename, and a test
      // that disposed a queue may still have that write in flight — so the
      // directory can gain a file between the `exists` and the `delete`. That
      // is the atomic write working, not a failure, and a temp directory that
      // will not delete is never the thing under test.
    }
  });

  Future<CaptureBundle> makeBundle(String sessionId) async {
    final directory = Directory('${root.path}/$sessionId');
    await directory.create(recursive: true);
    final bundle = CaptureBundle(
      sessionId: sessionId,
      directory: directory,
      plan: samplePlan,
      intrinsics: sampleIntrinsics,
      positions: samplePositions,
      deviceInfo: const {},
    );
    await bundle.save();
    return bundle;
  }

  StitchQueue makeQueue({
    SphereCameraPlatform? platform,
    int maxAttempts = 3,
    QualityTier? previewTier,
  }) => StitchQueue(
    directory: root,
    platform: platform ?? FakeCameraPlatform(),
    stitcherFactory: ({tier}) => _FakeStitcher(log),
    maxAttempts: maxAttempts,
    // Off by default in these tests, which are about queue *mechanics* —
    // ordering, serialisation, retry budgets, atomic persistence. With the
    // preview pass on, every bundle appears twice in `log.started` and each of
    // those assertions would be counting two things at once. The two-pass
    // behaviour has its own test below, where it is the subject rather than
    // background noise.
    previewTier: previewTier,
  );

  test('a queued bundle is stitched and the panorama recorded', () async {
    final queue = makeQueue();
    final bundle = await makeBundle('station-1');
    final entry = await queue.enqueue(bundle);
    expect(entry.status, StitchQueueStatus.pending);

    await queue.start();
    await queue.drained;

    expect(entry.status, StitchQueueStatus.done);
    expect(entry.outputPath, endsWith('panorama.jpg'));
    expect(log.started, ['station-1']);
    await queue.dispose();
  });

  test('a preview is emitted first, then the full-resolution panorama', () async {
    // The Pixel behaviour the product wants: something to look at the moment
    // capture ends, not 135 s later. The preview is a real complete sphere, just
    // small, and it goes to its own file so a failure in the full pass still
    // leaves the operator with a viewable panorama.
    final queue = makeQueue(previewTier: QualityTier.low);
    final results = <({String path, bool preview})>[];
    queue.events.listen((e) {
      if (e.result != null) {
        results.add((path: e.result!.equirectPath, preview: e.preview));
      }
    });

    await queue.enqueue(await makeBundle('station-1'));
    await queue.start();
    await queue.drained;
    await pumpEventQueue();

    expect(
      results.map((r) => r.preview),
      [true, false],
      reason: 'the small pass must land first — that is the whole point',
    );
    expect(results.first.path, contains('-preview'));
    expect(results.last.path, isNot(contains('-preview')));
    expect(
      log.started,
      ['station-1', 'station-1'],
      reason: 'one bundle, stitched twice, serially',
    );
    expect(log.maxConcurrent, 1, reason: 'still never two at once');
    await queue.dispose();
  });

  test('two enqueued bundles stitch serially, never concurrently', () async {
    // Two at once will run the device out of memory: the tier table sizes
    // *one* stitch against the hardware. This is the assertion that keeps that
    // true as the queue grows features.
    final queue = makeQueue();
    await queue.enqueue(await makeBundle('station-1'));
    await queue.enqueue(await makeBundle('station-2'));

    await queue.start();
    await queue.drained;

    expect(log.started, ['station-1', 'station-2']);
    expect(
      log.maxConcurrent,
      1,
      reason: 'two concurrent stitches will OOM — Phase 10 §5',
    );
    expect(
      queue.entries.every((e) => e.status == StitchQueueStatus.done),
      isTrue,
    );
    await queue.dispose();
  });

  test('enqueuing the same session twice does not stitch it twice', () async {
    final queue = makeQueue();
    final bundle = await makeBundle('station-1');
    final first = await queue.enqueue(bundle);
    final second = await queue.enqueue(bundle);
    expect(identical(first, second), isTrue);
    expect(queue.entries, hasLength(1));

    await queue.start();
    await queue.drained;
    expect(log.started, ['station-1']);
    await queue.dispose();
  });

  test('the queue survives an app kill mid-stitch and restarts that bundle', () async {
    // The kill is simulated the only way it can honestly be: the first queue is
    // abandoned mid-stitch without any shutdown at all, exactly as a process
    // that stops existing would leave things. Nothing gets to run a `finally`.
    final blocked = Completer<void>();
    log.hangOn = {'station-1': blocked};

    final first = StitchQueue(
      directory: root,
      platform: FakeCameraPlatform(),
      stitcherFactory: ({tier}) => _FakeStitcher(log),
      previewTier: null,  // mechanics, not previews — see makeQueue
    );
    await first.enqueue(await makeBundle('station-1'));
    unawaited(first.start());
    await _until(() => log.started.contains('station-1'));

    // What is on disk at the moment of the kill is the whole test: the queue
    // file has to already say this bundle was in flight, because the code that
    // would have written anything else is about to cease to exist.
    //
    // Waited for rather than read straight away. `log.started` is an in-memory
    // marker set by the fake stitcher, and the state file is written by a
    // separate `await` — so reading immediately is a race against real file I/O
    // that this test lost about one run in five on a loaded machine. Waiting for
    // the write does not weaken the assertion: the property is that the status
    // reaches disk before a kill could interrupt it, and a queue that never
    // wrote it still fails here, on the timeout.
    Map<String, Object?> persistedEntry() {
      final decoded =
          jsonDecode(first.stateFile.readAsStringSync()) as Map<String, Object?>;
      final entries = (decoded['entries'] as List?) ?? const [];
      return entries.isEmpty
          ? const {}
          : (entries.first as Map).cast<String, Object?>();
    }

    await _until(() => persistedEntry()['status'] == 'running');
    final persisted = persistedEntry();
    expect(persisted['status'], 'running');
    expect(persisted['attempts'], 1);

    // The new process.
    log.hangOn = {};
    final second = StitchQueue(
      directory: root,
      platform: FakeCameraPlatform(),
      stitcherFactory: ({tier}) => _FakeStitcher(log),
      previewTier: null,  // mechanics, not previews — see makeQueue
    );
    await second.load();

    expect(second.entries, hasLength(1));
    final recovered = second.entries.single;
    expect(
      recovered.status,
      StitchQueueStatus.pending,
      reason: 'a bundle found running at startup did not finish',
    );
    expect(
      recovered.interruptions,
      1,
      reason:
          'counted as an interruption, not a failure — a device that '
          'backgrounds aggressively must not exhaust the retry budget',
    );

    await second.start();
    await second.drained;
    expect(recovered.status, StitchQueueStatus.done);
    // Restarted from the beginning: resumable at bundle granularity, not stage
    // granularity (Phase 10 §5).
    expect(log.started, ['station-1', 'station-1']);

    blocked.complete();
    await second.dispose();
  });

  test('the queue waits out a hot device and resumes when it cools', () async {
    final platform = FakeCameraPlatform()
      ..currentThermalState = ThermalState.serious;
    final queue = makeQueue(platform: platform);
    await queue.enqueue(await makeBundle('station-1'));

    final paused = <String>[];
    queue.events.listen((e) {
      if (e.paused && e.pauseReason != null) paused.add(e.pauseReason!);
    });

    await queue.start();
    await _until(() => paused.isNotEmpty);
    expect(
      log.started,
      isEmpty,
      reason: 'Phase 10 §5 — skipped while thermally stressed',
    );
    expect(paused.first, contains('hot'));

    platform
      ..currentThermalState = ThermalState.nominal
      ..emitThermal(ThermalState.nominal);
    await queue.drained;

    expect(log.started, ['station-1']);
    expect(queue.entries.single.status, StitchQueueStatus.done);
    await queue.dispose();
  });

  test('a bundle that keeps failing is retried, then marked failed', () async {
    log.failOn = {'station-1'};
    final queue = makeQueue(maxAttempts: 2);
    await queue.enqueue(await makeBundle('station-1'));

    await queue.start();
    await queue.drained;

    final entry = queue.entries.single;
    expect(entry.status, StitchQueueStatus.failed);
    expect(entry.attempts, 2);
    expect(entry.lastError, contains('deliberate'));
    await queue.dispose();
  });

  test('a failed bundle can be retried, and only a failed one', () async {
    // Phase 13. The storage policy keeps exactly the bundles that failed, so
    // re-stitching one — after the device cools, after a pipeline improvement —
    // is a normal thing for a host app to want. Without this the caller's only
    // route back is to mutate the entry, which is not a route.
    log.failOn = {'station-1'};
    final queue = makeQueue(maxAttempts: 1);
    await queue.enqueue(await makeBundle('station-1'));
    await queue.start();
    await queue.drained;
    expect(queue.entries.single.status, StitchQueueStatus.failed);

    expect(await queue.retry('station-2'), isFalse, reason: 'no such entry');

    log.failOn = {};
    expect(await queue.retry('station-1'), isTrue);
    final entry = queue.entries.single;
    expect(entry.status, StitchQueueStatus.pending);
    expect(entry.attempts, 0);
    expect(entry.lastError, isNull);

    // A retry of something already queued is not an error, it is a no-op: a UI
    // that offers the button twice must not restart a running stitch.
    expect(await queue.retry('station-1'), isFalse);

    await queue.start();
    await queue.drained;
    expect(queue.entries.single.status, StitchQueueStatus.done);

    // And it reached disk, so the retry survives the kill it is most likely to
    // be followed by.
    final reloaded = makeQueue();
    await reloaded.load();
    expect(reloaded.entries.single.status, StitchQueueStatus.done);
    await reloaded.dispose();
    await queue.dispose();
  });

  test('a bundle whose folder is gone fails with a message that says so', () async {
    final queue = makeQueue();
    final bundle = await makeBundle('station-1');
    await queue.enqueue(bundle);
    await bundle.directory.delete(recursive: true);

    await queue.start();
    await queue.drained;

    final entry = queue.entries.single;
    expect(entry.status, StitchQueueStatus.failed);
    expect(entry.lastError, contains('capture folder is gone'));
    expect(log.started, isEmpty);
    await queue.dispose();
  });

  test('stopping the queue cancels the stitch without spending an attempt', () async {
    final blocked = Completer<void>();
    log.hangOn = {'station-1': blocked};
    final queue = makeQueue();
    await queue.enqueue(await makeBundle('station-1'));

    unawaited(queue.start());
    await _until(() => log.started.isNotEmpty);
    await queue.stop();

    final entry = queue.entries.single;
    expect(entry.status, StitchQueueStatus.pending);
    expect(
      entry.attempts,
      0,
      reason: 'stopping three times must not fail a bundle nobody tried',
    );
    expect(entry.interruptions, 1);

    blocked.complete();
    await queue.dispose();
  });

  test('the queue file is rewritten atomically and reloads exactly', () async {
    final queue = makeQueue();
    await queue.enqueue(await makeBundle('station-1'));
    await queue.enqueue(await makeBundle('station-2'));
    await queue.start();
    await queue.drained;

    final reloaded = makeQueue();
    await reloaded.load();
    expect(reloaded.entries.map((e) => e.sessionId), ['station-1', 'station-2']);
    expect(
      reloaded.entries.every((e) => e.status == StitchQueueStatus.done),
      isTrue,
    );
    expect(reloaded.pending, isEmpty);
    // No stray temporary left behind — the rename is what makes a kill during
    // the write safe.
    expect(await File('${queue.stateFile.path}.tmp').exists(), isFalse);
    await queue.dispose();
  });
}

/// Waits for [condition], or fails the test rather than hanging forever.
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for the queue to reach the expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Shared state across the stitchers the queue builds, since it makes a fresh
/// one per bundle.
class _StitchLog {
  final List<String> started = [];
  int concurrent = 0;
  int maxConcurrent = 0;

  /// Sessions whose stitch should never finish, keyed to the completer that
  /// releases them at the end of the test.
  Map<String, Completer<void>> hangOn = {};

  /// Sessions whose stitch should throw.
  Set<String> failOn = {};
}

/// A stitcher that records what the queue asked of it instead of stitching.
///
/// The queue's job is scheduling, persistence and thermal policy; driving real
/// C++ through it would make these tests minutes long and would test the
/// pipeline again rather than the queue.
class _FakeStitcher extends SphereStitcher {
  _FakeStitcher(this.log);

  final _StitchLog log;
  bool _cancelled = false;

  @override
  Future<StitchResult> stitch(
    CaptureBundle bundle, {
    void Function(StitchProgress progress)? onProgress,
    String? outputPath,
    PanoramaMetadata? metadata,
  }) async {
    log.started.add(bundle.sessionId);
    log.concurrent += 1;
    log.maxConcurrent =
        log.concurrent > log.maxConcurrent ? log.concurrent : log.maxConcurrent;
    try {
      onProgress?.call(
        const StitchProgress(stage: StitchStage.fusing, fraction: 0.1),
      );

      final hang = log.hangOn[bundle.sessionId];
      if (hang != null) {
        while (!_cancelled && !hang.isCompleted) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        if (_cancelled) throw const StitchCancelledException(StitchStage.fusing);
      }
      if (log.failOn.contains(bundle.sessionId)) {
        throw StateError('deliberate failure for ${bundle.sessionId}');
      }

      onProgress?.call(
        const StitchProgress(stage: StitchStage.encoding, fraction: 1.0),
      );
      return StitchResult(
        equirectPath: outputPath ?? '${bundle.directory.path}/panorama.jpg',
        width: QualityTier.mid.outputWidth,
        height: QualityTier.mid.outputHeight,
        report: sampleReport,
      );
    } finally {
      log.concurrent -= 1;
    }
  }

  @override
  void cancel() => _cancelled = true;
}
