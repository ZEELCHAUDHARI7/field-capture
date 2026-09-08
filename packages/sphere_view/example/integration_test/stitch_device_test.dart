// The Phase 10 §6 tests that only a device can answer.
//
// Three of Phase 10's exit criteria are statements about hardware, and none of
// them can be checked on a laptop:
//
//   1. **Zero dropped UI frames during a full stitch.** A desktop test can only
//      measure the *cause* — how long the Dart isolate goes without running a
//      callback — because there is no raster thread to drop anything.
//      `SchedulerBinding.addTimingsCallback` measures the symptom itself, and
//      it exists only in a real engine.
//   2. **The tier probe and the OOM downgrade on a real 3 GB Android tablet.**
//      The tier table (architecture §6.5) is a claim about devices. A tablet
//      that reports 2.8 GB must land on `low`, and one that reports 8 GB on
//      `high`, and no amount of desktop testing says whether `MemInfo` and
//      `ProcessInfo.physicalMemory` actually return what we think.
//   3. **Cancellation within 500 ms on device silicon.** The desktop numbers
//      are roughly 4x optimistic — the same pipeline runs in ~15 s here and is
//      budgeted at 60 s there — so the bound has to be re-measured where it
//      applies.
//
// There is no captured bundle on a fresh device, so the suite renders a small
// synthetic one first, with the same harness the quality gate uses. That takes
// a minute or two on a tablet and needs no physical setup at all: no grey card,
// no measured wall, nobody holding anything. Run it and send back
// `sphere_view_phase10_report.json`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sphere_view/sphere_view.dart';

// The rig that renders the capture set, reached by path because it is a tool
// rather than part of the shipped package — the same way
// `test/synthetic_sanity_test.dart` reaches it.
import '../../tools/harness/profiles.dart';
import '../../tools/harness/synth_runner.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final report = <String, Object?>{};
  late CaptureBundle bundle;
  late Directory work;

  setUpAll(() async {
    final documents = await getApplicationDocumentsDirectory();
    work = Directory('${documents.path}/phase10');
    if (await work.exists()) await work.delete(recursive: true);
    await work.create(recursive: true);

    // Deliberately small. The frames are 240x320 rather than the harness
    // default 480x640 and the ground truth 1024 rather than 2048, which is
    // ~16x less pixel work — the rendering is pure Dart and this is a tablet.
    // It does not weaken anything measured here: the isolate, the poll loop and
    // the cancel flag do not care how big the frames are, and the stitch is
    // still a real one through the real pipeline.
    //
    // `pristine` because one exposure per position keeps stage 5 a passthrough.
    // Phase 05's bracket path has its own device coverage; what is being timed
    // here is the plumbing.
    final profile = SynthProfile.all.firstWhere((p) => p.name == 'pristine');
    final runner = SynthRunner(
      profile: profile,
      frameSize: const ImageSize(240, 320),
      groundTruthWidth: 1024,
    );
    final rendering = Stopwatch()..start();
    bundle = await runner.run(Directory('${work.path}/bundle'));
    report['render_ms'] = rendering.elapsedMilliseconds;
    report['positions'] = bundle.positions.length;
  });

  tearDownAll(() async {
    final file = File('${work.parent.path}/sphere_view_phase10_report.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    // ignore: avoid_print
    print('Phase 10 report written to ${file.path}');
    // ignore: avoid_print
    print(const JsonEncoder.withIndent('  ').convert(report));
  });

  testWidgets('1. the tier probe reads this device and is stable', (
    tester,
  ) async {
    final probe = await MemoryTier.probeDetailed();
    report['total_physical_memory_mb'] = probe.totalPhysicalMemoryMb;
    report['available_process_memory_mb'] = probe.availableProcessMemoryMb;
    report['tier_from_total_memory'] = probe.tierFromTotalMemory.name;
    report['tier'] = probe.tier.name;
    report['tier_warning'] = probe.warning;

    expect(
      probe.totalPhysicalMemoryMb,
      greaterThan(512),
      reason: 'the platform reported an implausible amount of RAM',
    );
    // The claim architecture §6.5 makes about devices, checked against this one.
    expect(
      probe.tierFromTotalMemory,
      MemoryTier.forTotalMemoryMb(probe.totalPhysicalMemoryMb),
    );

    // Twenty calls, one answer. This is the whole reason the tier comes from
    // *total* memory: if it moved with what else the device is doing, two runs
    // of one bundle would give two output resolutions and a bug report would
    // stop being evidence about anything.
    final tiers = <QualityTier>{};
    for (var i = 0; i < 20; i++) {
      tiers.add(await MemoryTier.probe());
    }
    expect(tiers, hasLength(1), reason: 'the tier probe is not deterministic');

    if (Platform.isIOS) {
      expect(
        probe.availableProcessMemoryMb,
        greaterThan(0),
        reason:
            'os_proc_available_memory returned nothing, so the iOS pre-flight '
            'check — the only defence against a jetsam kill — is not working',
      );
    } else {
      expect(
        probe.availableProcessMemoryMb,
        -1,
        reason: 'Android has no honest per-process figure and must say so',
      );
    }
  });

  testWidgets('2. a full stitch drops no UI frames', (tester) async {
    // The exit criterion, measured the only way it can be: against the frames
    // the engine actually built while the stitch was running. A widget is kept
    // animating throughout, because a stitch with nothing on screen would
    // produce no frames to drop and the test would pass vacuously.
    final frames = <FrameTiming>[];
    void collect(List<FrameTiming> timings) => frames.addAll(timings);
    SchedulerBinding.instance.addTimingsCallback(collect);

    await tester.pumpWidget(const _SpinningProbe());

    final clock = Stopwatch()..start();
    final stitcher = SphereStitcher();
    final ticks = <StitchProgress>[];

    final pumping = Completer<void>();
    unawaited(
      stitcher
          .stitch(
            bundle,
            outputPath: '${work.path}/panorama.jpg',
            onProgress: ticks.add,
          )
          .then((result) {
            report['stitch_ms'] = clock.elapsedMilliseconds;
            report['output'] = result.equirectPath;
            report['tier_used'] = result.report.tierUsed.name;
            report['report'] = result.report.toJson();
            pumping.complete();
          }, onError: pumping.completeError),
    );

    // `pump` in a loop rather than `pumpAndSettle`: the point is to keep
    // producing frames for the whole stitch so there is something to drop.
    while (!pumping.isCompleted) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await pumping.future;

    SchedulerBinding.instance.removeTimingsCallback(collect);

    final overBudget = frames
        .where((f) => f.totalSpan > const Duration(milliseconds: 32))
        .toList();
    report['frames_built'] = frames.length;
    report['frames_over_32ms'] = overBudget.length;
    report['worst_frame_ms'] = frames.isEmpty
        ? 0
        : frames
              .map((f) => f.totalSpan.inMilliseconds)
              .reduce((a, b) => a > b ? a : b);
    report['progress_ticks'] = ticks.length;

    expect(frames, isNotEmpty, reason: 'no frames were built to measure');
    expect(
      overBudget,
      isEmpty,
      reason:
          '${overBudget.length} of ${frames.length} frames took longer than '
          '32 ms during the stitch. The worst was '
          '${report['worst_frame_ms']} ms.',
    );

    // And the progress bar behaved while it did.
    expect(ticks, isNotEmpty);
    for (var i = 1; i < ticks.length; i++) {
      expect(ticks[i].fraction, greaterThanOrEqualTo(ticks[i - 1].fraction));
    }
    expect(ticks.last.fraction, 1.0);
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('3. cancellation lands within 500 ms on this silicon', (
    tester,
  ) async {
    final latencies = <String, int>{};
    for (final stage in [
      StitchStage.findingFeatures,
      StitchStage.warping,
      StitchStage.blending,
    ]) {
      final stitcher = SphereStitcher();
      final clock = Stopwatch()..start();
      var requestedAtUs = -1;
      try {
        await stitcher.stitch(
          bundle,
          outputPath: '${work.path}/cancel_${stage.name}.jpg',
          onProgress: (progress) {
            if (requestedAtUs < 0 && progress.stage.index >= stage.index) {
              requestedAtUs = clock.elapsedMicroseconds;
              stitcher.cancel();
            }
          },
        );
        fail('the stitch finished instead of being cancelled at ${stage.name}');
      } on StitchCancelledException {
        latencies[stage.name] =
            (clock.elapsedMicroseconds - requestedAtUs) ~/ 1000;
      }
    }
    report['cancel_latency_ms'] = latencies;

    for (final entry in latencies.entries) {
      expect(
        entry.value,
        lessThan(500),
        reason:
            'cancelling during ${entry.key} took ${entry.value} ms on this '
            'device, against Phase 10 §3s 500 ms bound',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('4. an out-of-memory failure drops a tier and retries once', (
    tester,
  ) async {
    // Forced rather than provoked. Genuinely exhausting a tablet's memory is
    // not a test — on iOS it is a jetsam kill with no signal, and on Android it
    // is whichever process the OS decides to end. What has to be proved here is
    // that the *recovery* works on device: the native side maps the failure,
    // the Dart side degrades one step, retries, finishes, and says so.
    final stitcher = _ForcedOomStitcher();
    final result = await stitcher.stitch(
      bundle,
      outputPath: '${work.path}/oom.jpg',
    );

    report['oom_tiers_attempted'] = [
      for (final t in stitcher.tiersAttempted) t.name,
    ];
    report['oom_warning'] = result.report.warnings.isEmpty
        ? null
        : result.report.warnings.first;

    expect(stitcher.tiersAttempted, hasLength(2));
    expect(
      stitcher.tiersAttempted[1],
      MemoryTier.degrade(stitcher.tiersAttempted[0]),
      reason: 'the retry must be exactly one tier down',
    );
    expect(result.report.tierUsed, stitcher.tiersAttempted[1]);
    expect(
      result.report.warnings.first,
      contains('ran out of memory'),
      reason: 'architecture §8 — the downgrade has to reach the caller',
    );
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('5. the queue survives a kill and stitches serially', (
    tester,
  ) async {
    // The on-device half of Phase 10 §5. The desktop suite proves the queue's
    // logic against a fake stitcher; this proves the same file survives a real
    // app's document directory and a real stitch.
    final queueDirectory = Directory('${work.path}/queue');
    final first = StitchQueue(directory: queueDirectory);
    await first.enqueue(bundle, outputPath: '${work.path}/queued.jpg');
    unawaited(first.start());

    // Let it get properly under way, then reproduce what a kill leaves behind.
    //
    // The queue really is stopped first, rather than abandoned: an abandoned
    // stitch would go on running in this process and compete with the one the
    // recovered queue starts, which is the exact thing §5 forbids. What is
    // asserted before stopping is that the file *already* said `running` — that
    // is the state a killed process leaves, and putting it back by hand
    // afterwards reconstructs it exactly rather than assuming it.
    await Future<void>.delayed(const Duration(seconds: 2));
    final onDisk =
        jsonDecode(await first.stateFile.readAsString()) as Map<String, Object?>;
    final persisted = (onDisk['entries'] as List).first as Map<String, Object?>;
    expect(
      persisted['status'],
      'running',
      reason:
          'the queue must record a bundle as in flight *before* it starts, or '
          'a kill leaves no evidence that it was ever tried',
    );
    await first.stop();
    await first.stateFile.writeAsString(jsonEncode(onDisk));

    final second = StitchQueue(directory: queueDirectory);
    await second.load();
    expect(second.entries.single.status, StitchQueueStatus.pending);
    expect(second.entries.single.interruptions, greaterThanOrEqualTo(1));

    await second.start();
    await second.drained;
    expect(second.entries.single.status, StitchQueueStatus.done);
    expect(File('${work.path}/queued.jpg').existsSync(), isTrue);

    report['queue_interruptions'] = second.entries.single.interruptions;
    report['queue_attempts'] = second.entries.single.attempts;
    await second.dispose();
  }, timeout: const Timeout(Duration(minutes: 15)));
}

/// A stitcher whose first attempt is forced to fail with `std::bad_alloc`.
class _ForcedOomStitcher extends SphereStitcher {
  final List<QualityTier> tiersAttempted = [];

  @override
  String? forceErrorFor(QualityTier tier, int attempt) {
    tiersAttempted.add(tier);
    return attempt == 0 ? 'bad_alloc' : null;
  }
}

/// Something that repaints every frame, so the engine has frames to drop.
///
/// Without it the "no dropped frames" measurement would be taken over a static
/// tree that builds nothing, and would pass on a stitch that froze the UI
/// solid.
class _SpinningProbe extends StatefulWidget {
  const _SpinningProbe();

  @override
  State<_SpinningProbe> createState() => _SpinningProbeState();
}

class _SpinningProbeState extends State<_SpinningProbe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: const Color(0xFF101010),
      child: Center(
        child: RotationTransition(
          turns: _controller,
          child: const SizedBox(
            width: 96,
            height: 96,
            child: ColoredBox(color: Color(0xFFEEEEEE)),
          ),
        ),
      ),
    ),
  );
}
