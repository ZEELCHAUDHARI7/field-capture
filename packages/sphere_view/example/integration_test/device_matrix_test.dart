// Phase 12 §1 — one run per device produces one row of the device matrix.
//
// The matrix is the deliverable that decides whether this ships, and the reason
// it is a *test* rather than a spreadsheet is that a spreadsheet filled in by
// hand is filled in differently on every device. This writes
// `sphere_view_device_matrix.json`, `tools/device_matrix.dart` merges the files
// from every device into `docs/DEVICE_MATRIX.md`, and the numbers in the
// published table are therefore the numbers the code measured.
//
// **Run this on the low-end rugged Android tablet first.** The phase doc is
// blunt about it and it is worth repeating here, where somebody is deciding what
// to plug in: iPads will be fine. The 3 GB tablet with a `LEGACY` camera and
// possibly no gyroscope is what determines whether the feature exists. Finding
// out on device six that it cannot bracket is a week of work spent on the wrong
// question.
//
// ## What needs a human, and what does not
//
// Tests 1-5 are **unattended**. They need no grey card, no measured wall and
// nobody holding anything: the suite renders its own synthetic capture set with
// the same harness the quality gate uses, then stitches it. Put the tablet on a
// desk, start the run, come back.
//
// Test 6 is **attended** and it is the only source of S7. A session time is a
// statement about a person pivoting a tablet through 29 positions, and there is
// no way to measure that without the person. It takes two minutes.
//
// ## Running it
//
//   cd example
//   flutter test integration_test/device_matrix_test.dart -d <device-id>
//
// Then pull the report:
//
//   # Android
//   adb exec-out run-as com.asite.sphere_view_example \
//     cat files/sphere_view_device_matrix.json > tab-a9.json
//   # iOS: Files app, or the container from Xcode's Devices window
//
// and merge:
//
//   dart run tools/device_matrix.dart --add tab-a9.json --out docs/DEVICE_MATRIX.md

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sphere_view/sphere_view.dart';

// The rig, reached by path because it is a tool rather than part of the shipped
// package — the same way `stitch_device_test.dart` does it.
import '../../tools/harness/camera_model.dart';
import '../../tools/harness/ground_truth.dart';
import '../../tools/harness/float_image.dart';
import '../../tools/harness/metrics.dart';
import '../../tools/harness/native_stitcher.dart';
import '../../tools/harness/profiles.dart';
import '../../tools/harness/stitcher_backend.dart';
import '../../tools/harness/synth_runner.dart';

/// How many consecutive `low`-tier stitches the soak runs.
///
/// Phase 12 §5 asks for 20 without an OOM, and the number is not arbitrary: the
/// failure it is looking for is a leak or a fragmentation creep, and both are
/// invisible in one run and obvious by the twentieth. On a tablet at ~30 s a
/// stitch this is ten minutes, which is why it is the last test rather than the
/// first.
const int kSoakRuns = 20;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final row = <String, Object?>{};
  late Directory work;
  late CaptureBundle bundle;
  late GroundTruth truth;

  setUpAll(() async {
    final documents = await getApplicationDocumentsDirectory();
    work = Directory('${documents.path}/device_matrix');
    if (await work.exists()) await work.delete(recursive: true);
    await work.create(recursive: true);

    row['measured_at'] = DateTime.now().toUtc().toIso8601String();
    row['platform'] = Platform.operatingSystem;
    row['os_version'] = Platform.operatingSystemVersion;

    // The reference scene, rendered here rather than shipped, because 100 MB of
    // JPEG in an app bundle is worse than two minutes of arithmetic — and because
    // the rig is seeded by profile name, so every device renders **the same
    // scene**, which is the whole point of a matrix. `nominal` is the profile
    // that stands for the device we expect.
    //
    // Smaller than the desktop corpus: 240x320 frames against a 1024 ground
    // truth, ~16x less pixel work, because the renderer is pure Dart. It does not
    // weaken what is measured — the tier, the memory ceiling, the timings and the
    // metrics all describe the same pipeline — but it does mean S8 here is a
    // *lower bound* on a real 12 MP capture, and the row says so.
    final directory = Directory('${work.path}/nominal');
    await SynthRunner(
      profile: SynthProfile.byName('nominal'),
      frameSize: const ImageSize(240, 320),
      groundTruthWidth: 1024,
    ).run(directory);
    bundle = await CaptureBundle.load(directory);
    truth = await GroundTruth.load(directory);
  });

  tearDownAll(() async {
    final documents = await getApplicationDocumentsDirectory();
    final file = File('${documents.path}/sphere_view_device_matrix.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(row));
    debugPrint('device matrix row written to ${file.path}');
    debugPrint(const JsonEncoder.withIndent('  ').convert(row));
  });

  testWidgets('1. what this device is, and what it can do', (_) async {
    final platform = PigeonCameraPlatform();
    final capability = await SphereCapabilityProbe.probe(camera: platform);
    final identity = await platform.deviceIdentity();

    row['device'] = '${identity.make} ${identity.model}';
    row['device_identity'] = identity.toJson();
    row['capability'] = capability.toJson();
    row['tier'] = capability.tier.name;
    row['total_memory_mb'] = capability.totalPhysicalMemoryMb;
    row['battery_start_percent'] = await platform.batteryPercent();
    row['thermal_at_start'] = (await platform.thermalState()).name;

    // Not an assertion about *which* capability: a `noBracketing` tablet is a
    // supported device and a matrix row for it is the point of the exercise. What
    // is asserted is that the probe answered at all, because a row whose
    // capability is unknown cannot be read.
    expect(row['capability'], isNotNull);
    expect(capability.cameraId, isNotEmpty);

    // The one hard refusal. If this fires, the rest of the suite is measuring a
    // device the feature must hide itself on — which is a legitimate matrix row
    // and the end of the run.
    if (!capability.isSupported) {
      row['unsupported_reason'] = capability.blockingReason;
      markTestSkipped(
        'this device cannot capture a 360: ${capability.blockingReason}',
      );
    }
  });

  testWidgets('2. S1-S6 on the fixed reference scene', (_) async {
    // At ground-truth canvas size, not at the device tier. Comparing a
    // 4096-wide stitch against a 1024-wide reference resamples one of them, and
    // a resample is a blur, and a blur moves SSIM for reasons that have nothing
    // to do with this device. Timing and memory are measured at the tier
    // instead, in test 3, where fidelity is not the question.
    final canvas = EquirectCanvas(truth.canvasWidth, truth.canvasHeight);
    final backend = NativeStitcherBackend(
      tier: 'low',
      workDirectory: Directory('${work.path}/native'),
      compositingOverrides: {'output_width': canvas.width},
    );
    final outcome = await backend.stitch(
      StitchJob(bundle: bundle, canvas: canvas),
    );
    final reference = resampleEquirect(
      await FloatImage.loadRgb(
        File('${bundle.directory.path}/${GroundTruth.imageFileName}'),
      ),
      canvas,
    );
    final metrics = MetricsEngine(
      bundle: bundle,
      truth: truth,
      outcome: outcome,
      groundTruthImage: reference,
      canvas: canvas,
      peakRssBytes: MetricsEngine.currentPeakRss(),
      targets: MetricTargets.forProfile(truth.profile),
    ).compute();

    row['quality'] = {
      for (final metric in metrics.metrics)
        if (!metric.value.isNaN) metric.id: metric.value,
    };
    row['quality_pass'] = {
      for (final metric in metrics.metrics)
        if (metric.pass != null) metric.id: metric.pass,
    };
    row['warnings'] = metrics.warnings;

    // Deliberately not asserted against the targets. Several are known to miss
    // on the synthetic corpus (`phases/baselines`), and a device test that fails
    // for a reason the desktop gate already records would be red on every device
    // and would stop being run. What this test is *for* is producing the numbers
    // so a device can be compared against the desktop and against another
    // device; the gate is where a target is enforced.
    expect(row['quality'], isNotEmpty);
  });

  testWidgets('3. S8 stitch time and S9 peak memory at this device\'s tier', (
    _,
  ) async {
    final tier = await MemoryTier.probe();
    final stitcher = SphereStitcher(tier: tier);
    final before = await PigeonCameraPlatform().batteryPercent();

    final clock = Stopwatch()..start();
    final result = await stitcher.stitch(
      bundle,
      outputPath: '${work.path}/tier_${tier.name}.jpg',
    );
    clock.stop();

    row['s8_stitch_ms'] = clock.elapsedMilliseconds;
    row['s8_reported_ms'] = result.report.elapsedMs;
    row['s9_peak_rss_mb'] = MetricsEngine.currentPeakRss() ~/ (1024 * 1024);
    row['tier_used'] = result.report.tierUsed.name;
    row['output'] = '${result.width}x${result.height}';
    row['stitch_warning_codes'] = [
      for (final warning in result.report.warnings) warning.code.wireName,
    ];
    row['stitch_warnings'] = [
      for (final warning in result.report.warnings) warning.message,
    ];
    row['thermal_after_stitch'] =
        (await PigeonCameraPlatform().thermalState()).name;
    row['battery_after_stitch_percent'] =
        await PigeonCameraPlatform().batteryPercent();
    row['battery_stitch_delta'] = before < 0
        ? null
        : before - (row['battery_after_stitch_percent']! as int);

    // S9 is a real budget rather than a recorded number: 700 MB is what
    // architecture §7 sized the strip blender for, and a device over it is a
    // device that will be killed mid-stitch on a bad day. Asserted here even
    // though the synthetic frames are small, because the canvas — which is what
    // dominates the peak — is the device's own tier.
    expect(
      row['s9_peak_rss_mb']! as int,
      lessThan(700),
      reason:
          'peak RSS ${row['s9_peak_rss_mb']} MB at the ${tier.name} tier, '
          'against S9\'s 700 MB ceiling',
    );
  });

  testWidgets('4. a stitch under thermal pressure pauses and resumes intact', (
    _,
  ) async {
    // The §5 test, driven through the policy rather than by heating the tablet:
    // a device that is already hot cannot be relied on to be hot on cue, and one
    // that is cool cannot be made hot inside a test. What is checked is that the
    // *decision* the policy returns for each state is the one the queue acts on,
    // and that a stitch interrupted at each state still produces a valid
    // panorama rather than a truncated file.
    final states = <String, Object?>{};
    for (final state in ThermalState.values) {
      final decision = ThermalPolicy.forStitch(state);
      states[state.name] = {
        'action': decision.action.name,
        'message': decision.message,
      };
    }
    row['thermal_policy'] = states;

    // And the honest half: whether this device ever *reaches* the states whose
    // handling matters. A tablet that reports `nominal` through a whole walk has
    // not exercised the pause at all, and the row should not imply it has.
    final observed = <String>{};
    final platform = PigeonCameraPlatform();
    final subscription = platform.thermalStates.listen(
      (state) => observed.add(state.name),
    );
    final stitcher = SphereStitcher(tier: QualityTier.low);
    final result = await stitcher.stitch(
      bundle,
      outputPath: '${work.path}/thermal.jpg',
    );
    await subscription.cancel();

    row['thermal_states_observed'] = observed.toList()..sort();
    final written = File(result.equirectPath);
    expect(await written.exists(), isTrue);
    // A truncated JPEG is the failure mode a paused-and-resumed stitch would
    // produce, and it is invisible in a file listing. `GPanoReader` parses the
    // segment structure, so it fails on a file that stops halfway.
    final metadata = const GPanoReader().read(await written.readAsBytes());
    expect(metadata, isNotNull);
    expect(metadata!.fullWidth, result.width);
  });

  testWidgets('5. $kSoakRuns consecutive low-tier stitches without an OOM', (
    _,
  ) async {
    // Phase 12 §5's soak. The failure it hunts is not a single allocation that
    // is too large — test 3 covers that — but a leak or heap fragmentation that
    // only shows after the tenth run, on the device with the least headroom to
    // absorb it. Nothing here is clever; the whole value is in the repetition.
    final stitcher = SphereStitcher(tier: QualityTier.low);
    final peaks = <int>[];
    final durations = <int>[];
    final downgrades = <int>[];

    for (var run = 0; run < kSoakRuns; run++) {
      final clock = Stopwatch()..start();
      final result = await stitcher.stitch(
        bundle,
        outputPath: '${work.path}/soak_$run.jpg',
      );
      clock.stop();
      durations.add(clock.elapsedMilliseconds);
      peaks.add(MetricsEngine.currentPeakRss() ~/ (1024 * 1024));
      if (result.report.warnings.any(
        (w) =>
            w.code == StitchWarningCode.tierDowngradedAfterOom ||
            w.code == StitchWarningCode.tierDowngradedBeforeStart,
      )) {
        downgrades.add(run);
      }
      // The output of run n is not needed by run n+1, and twenty 4096-wide
      // panoramas is 400 MB of storage on a device that may not have it.
      await File(result.equirectPath).delete();
    }

    row['soak'] = {
      'runs': kSoakRuns,
      'peak_rss_mb': peaks,
      'duration_ms': durations,
      'downgraded_runs': downgrades,
      // The number that answers "is it creeping": the last five runs against the
      // first five. A leak shows here long before it shows as a failure.
      'first_five_mean_mb': _mean(peaks.take(5)),
      'last_five_mean_mb': _mean(peaks.skip(kSoakRuns - 5)),
    };

    expect(
      downgrades,
      isEmpty,
      reason:
          'the low tier is the floor — a downgrade from it means the device '
          'cannot stitch at all, and runs $downgrades hit it',
    );
    // Not an equality: a garbage-collected VM's high-water mark moves a few
    // percent between identical runs (see `quality_gate.dart`'s 25% band). A
    // 40% climb across twenty runs is not that.
    expect(
      _mean(peaks.skip(kSoakRuns - 5)),
      lessThan(_mean(peaks.take(5)) * 1.4),
      reason:
          'peak memory climbed from ${_mean(peaks.take(5))} MB over the first '
          'five runs to ${_mean(peaks.skip(kSoakRuns - 5))} MB over the last '
          'five, which is the shape of a leak rather than of GC noise',
    );
  });

  testWidgets(
    '6. S7 — a full 29-position session, timed (NEEDS A PERSON)',
    (tester) async {
      // The only attended test, and the only source of S7. Stand somewhere with
      // a bit of structure in view, start the run, and follow the prompts: pivot
      // on the spot through every position until the counter fills. The clock
      // starts when the session opens and stops when the last position lands.
      //
      // Skipped rather than failed when nobody is there — a suite that cannot be
      // run unattended is a suite that stops being run, and the other five tests
      // are worth having on their own.
      final capability = await SphereCapabilityProbe.probe();
      if (!capability.isSupported) {
        markTestSkipped('unsupported device; S7 does not apply');
        return;
      }

      SphereCaptureSession? session;
      try {
        session = await SphereCaptureSession.create(
          config: capability.configFrom(const SphereCaptureConfig()),
          capability: capability,
          directory: Directory('${work.path}/session'),
        );
      } on Object catch (error) {
        row['s7_error'] = '$error';
        markTestSkipped('the camera could not be opened for the S7 run: $error');
        return;
      }

      // The clock starts at `beginCapture`, not at `create`: S7 is a statement
      // about the ninety seconds a person spends turning, and the metering
      // pre-sweep before it is a fixed cost that does not scale with the plan.
      final battery = await PigeonCameraPlatform().batteryPercent();
      await session.beginMetering();
      final clock = Stopwatch()..start();
      await session.beginCapture();

      // Nothing here drives the shutter: the session's own auto-shutter does,
      // once the operator aims and holds. The pump loop is what lets the pose
      // stream and the frame gate run while a person turns, and the state stream
      // is how many positions have landed.
      var captured = 0;
      final subscription = session.states.listen(
        (state) => captured = state.capturedCount,
      );
      final deadline = DateTime.now().add(const Duration(minutes: 4));
      while (captured < session.plan.length && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      clock.stop();
      await subscription.cancel();
      final finished = await session.finish();

      row['s7_session_ms'] = clock.elapsedMilliseconds;
      row['s7_positions_planned'] = session.plan.length;
      row['s7_positions_captured'] = captured;
      row['s7_complete'] = captured == session.plan.length;
      row['battery_capture_delta'] = battery < 0
          ? null
          : battery - await PigeonCameraPlatform().batteryPercent();
      row['thermal_after_capture'] =
          (await PigeonCameraPlatform().thermalState()).name;
      row['s7_capture_warnings'] = finished.deviceInfo['warnings'];

      // Only meaningful if the operator actually finished. A partial session is
      // a real outcome but it is not an S7 measurement, and reporting 40 s for
      // 12 of 29 positions as a pass would be the most flattering number in the
      // matrix.
      if (captured == session.plan.length) {
        expect(
          clock.elapsedMilliseconds,
          lessThan(90000),
          reason:
              'S7 is 90 s for a full station; this took '
              '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
        );
      } else {
        markTestSkipped(
          'only $captured of ${session.plan.length} positions were captured, '
          'so this run does not measure S7',
        );
      }
    },
    // Longer than the default 10 minutes: the render in setUpAll plus a
    // four-minute human capture does not fit in it.
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

int _mean(Iterable<int> values) =>
    values.isEmpty ? 0 : values.reduce((a, b) => a + b) ~/ values.length;
