// The Phase 06 §6 tests, on real hardware.
//
// Every number here is one that does not exist off a device. R3's headline
// finding was that *no source anywhere* publishes a measured wall clock for a
// 3-frame full-resolution bracket, and R2 left four questions open that only an
// iPad and an Android tablet can answer. So this file is not a regression suite
// — it is the instrument that produces the findings.
//
// Run it, then send back `sphere_view_phase06_report.json`. `RUNNING.md` in
// this directory says exactly how.
//
// The seven tests of §6, in order:
//
//   1. enumerate → open → meter+lock → 29 brackets → close
//   2. intrinsics hfovRadians within 2% of the Spike B physical measurement
//   3. AE lock: 29 grey-card captures, mean luminance variation < 1%
//   4. AWB lock: the same, per channel
//   5. burst timing < 600 ms
//   6. camera↔motion clock offset stable within ±2 ms over 60 s
//   7. the intrinsics fallback chain — a *unit* test, in
//      `test/intrinsics_chain_test.dart`, because it must cover branches this
//      fleet will never take
//
// Tests 2 and 3/4 need physical setup (a measured wall, a grey card). They skip
// with a printed explanation rather than failing when it is absent, so a run
// without a grey card still produces the burst and clock numbers — which are
// the ones nothing anywhere has measured.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sphere_view/sphere_view.dart';

/// Set with `--dart-define=SPIKE_B_HFOV_DEGREES=…` to enable test 2.
///
/// The value is the horizontal field of view measured physically, per
/// `spikes/README.md`: two marks on a wall at the frame edges, a tape measure,
/// `hfov = 2·atan(separation / (2·distance))`. Without it there is nothing to
/// check the derived intrinsics *against*, and the test says so instead of
/// inventing a reference.
const String _spikeBHfovDegrees = String.fromEnvironment('SPIKE_B_HFOV_DEGREES');

/// Set with `--dart-define=GREY_CARD=true` when the camera is pointed at an
/// evenly-lit grey card that fills the centre of the frame.
const bool _greyCard = bool.fromEnvironment('GREY_CARD');

/// §6's count. It is the plan's own size — 29 positions, nadir skipped
/// (Math §8) — so the AE lock is measured over exactly as many captures as a
/// real session takes, not over a convenient round number.
const int _positionCount = 29;

/// The exit criteria, as numbers rather than prose.
const double _hfovTolerance = 0.02; // 2%
const double _luminanceVariationLimit = 0.01; // 1%
const double _burstBudgetMs = 600.0;
const int _clockStabilityLimitUs = 2000; // ±2 ms
const Duration _clockObservationWindow = Duration(seconds: 60);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late PigeonCameraPlatform platform;
  late Directory workDirectory;
  final report = <String, Object?>{
    'phase': '06',
    'generated_at': DateTime.now().toIso8601String(),
    'platform': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'inputs': {
      'spike_b_hfov_degrees': _spikeBHfovDegrees.isEmpty ? null : _spikeBHfovDegrees,
      'grey_card': _greyCard,
      'position_count': _positionCount,
    },
  };

  setUpAll(() async {
    platform = PigeonCameraPlatform();
    final documents = await getApplicationDocumentsDirectory();
    workDirectory = Directory('${documents.path}/phase06')
      ..createSync(recursive: true);
  });

  tearDownAll(() async {
    await platform.close().catchError((_) {});
    final file = File('${workDirectory.path}/sphere_view_phase06_report.json');
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    // Printed as well as written: on a device with no easy file access, the
    // console is the shortest path from "it ran" to "here is the number".
    // ignore: avoid_print
    print('\n===== PHASE 06 REPORT (${file.path}) =====\n'
        '${const JsonEncoder.withIndent('  ').convert(report)}\n'
        '===== END PHASE 06 REPORT =====\n');
  });

  testWidgets('1. enumerate, open, meter, lock, 29 brackets, close', (_) async {
    final cameras = await platform.listCameras();
    expect(cameras, isNotEmpty, reason: 'the platform reported no cameras at all');
    report['cameras'] = [
      for (final c in cameras)
        {
          'id': c.id,
          'facing': c.facing.name,
          'focal_lengths_mm': c.focalLengthsMm,
          'largest_size': c.availableSizes.isEmpty
              ? null
              : '${c.availableSizes.first.width.toInt()}x'
                  '${c.availableSizes.first.height.toInt()}',
          'size_count': c.availableSizes.length,
          'supports_bracketing': c.supportsBracketing,
          // R3 §4/§8's two unknowns, per device, by name.
          'max_bracket_count': c.maxBracketCount,
          'has_manual_sensor': c.hasManualSensor,
          'hardware_level': c.hardwareLevel,
          'has_distortion_model': c.hasDistortionModel,
          'is_logical_multi_camera': c.isLogicalMultiCamera,
          'excluded_reason': c.excludedReason,
        },
    ];

    final probe = CameraProbe(platform);
    final selection = await probe.selectCaptureCamera();
    final opened = await platform.open(
      selection.camera.id,
      CaptureFormatSpec(
        captureSize: probe.selectCaptureSize(selection.camera),
        // Statistics are what turn the grey-card check into a measurement
        // rather than an opinion, which is §6's whole point.
        computeFrameStatistics: true,
      ),
    );

    report['selection'] = {
      'chosen': selection.camera.id,
      'rejected': selection.rejected,
    };
    report['open'] = {
      ...opened.toProvenanceJson(),
      'hfov_degrees': opened.intrinsics.hfovDegrees,
      'vfov_degrees': opened.intrinsics.vfovDegrees,
      'fx': opened.intrinsics.fx,
      'fy': opened.intrinsics.fy,
      'cx': opened.intrinsics.cx,
      'cy': opened.intrinsics.cy,
      'distortion': opened.intrinsics.distortion?.toJson(),
    };

    final textureId = await platform.attachPreview();
    expect(textureId, greaterThanOrEqualTo(0));
    report['preview_texture_id'] = textureId;

    final metering = await ExposureController(platform).meterAndLock();
    report['metering'] = metering.toJson();
    // §2.3's decision, visible in the data: if these two are far apart the
    // scene really did have the bright-window skew the percentile resists.
    report['metering_skew_ev'] = metering.meanEv - metering.percentile65Ev;

    final biases = ExposureController(platform).bracketBiases(
      const SphereCaptureConfig(),
      mode: opened.bracketMode,
      maxBracketCount: opened.maxBracketCount,
    );
    report['requested_ev_biases'] = biases;

    final captures = <BracketCapture>[];
    final sessionStart = DateTime.now();
    for (var i = 0; i < _positionCount; i++) {
      captures.add(
        await platform.captureBracket(
          biases,
          outputDirectory: workDirectory.path,
          namePrefix: 'pos$i',
        ),
      );
    }
    final sessionMs = DateTime.now().difference(sessionStart).inMilliseconds;

    for (final capture in captures) {
      expect(
        capture.frames,
        isNotEmpty,
        reason: 'a bracket returned no frames at all',
      );
      for (final frame in capture.frames) {
        expect(
          File(frame.filePath).existsSync(),
          isTrue,
          reason: '${frame.filePath} was reported but not written',
        );
        expect(frame.byteCount, greaterThan(0));
        expect(
          frame.timestampUs,
          greaterThan(0),
          reason: 'a frame arrived with no shutter timestamp, which would make '
              'its pose unrecoverable',
        );
      }
    }

    // Whether the bracket actually separated, checked against actuals rather
    // than against what was requested. R3's warning is that a device without
    // real bracketing returns identical frames, and only this shows it.
    final achieved = <double>[
      for (final c in captures)
        for (final f in c.frames)
          if (f.achievedEvBias != null) (f.achievedEvBias! - f.evBias).abs(),
    ];
    report['session'] = {
      'positions': captures.length,
      'frames': captures.fold<int>(0, (n, c) => n + c.frames.length),
      'wall_clock_ms': sessionMs,
      'bracket_mode': captures.first.mode.name,
      'clamped_exposure': captures.any((c) => c.clampedExposure),
      'clamped_iso': captures.any((c) => c.clampedIso),
      'worst_ev_error': achieved.isEmpty ? null : achieved.reduce(math.max),
      'achieved_requested_separation':
          captures.every((c) => c.achievedRequestedSeparation),
      'notes': <String>{
        for (final c in captures)
          if (c.note != null) c.note!,
      }.toList(),
    };

    // ---- test 5: burst timing --------------------------------------------
    // The number R3 found nothing anywhere had ever published. The first burst
    // on a cold pipeline is routinely slower than steady state, so the median
    // is what the budget is judged against and every run is reported.
    final wallClocks = [for (final c in captures) c.burstWallClockMs]..sort();
    final median = wallClocks[wallClocks.length ~/ 2];
    report['HEADLINE_burst_wall_clock_ms'] = {
      'median': median,
      'min': wallClocks.first,
      'max': wallClocks.last,
      'first_run': captures.first.burstWallClockMs,
      'budget_ms': _burstBudgetMs,
      'within_budget': median <= _burstBudgetMs,
      'all_runs': [for (final c in captures) c.burstWallClockMs],
      // Separates what the sensor sustains from what encoding then costs —
      // the distinction the JPEG-versus-YUV decision turns on (R3 §9).
      'shutter_to_shutter_ms': captures.first.shutterToShutterMs,
      'deferred_encode_ms': captures.first.deferredEncodeMs,
    };

    await platform.detachPreview();
    await platform.unlock();
    await platform.close();

    expect(
      median,
      lessThanOrEqualTo(_burstBudgetMs),
      reason:
          'the ${biases.length}-shot burst took ${median.toStringAsFixed(0)} ms, over the '
          '${_burstBudgetMs.toStringAsFixed(0)} ms budget. Per R3, try the YUV + '
          'deferred-encode path first (CaptureFormatSpec.useDeferredJpegEncode) '
          'before dropping to a 2-shot bracket',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('2. intrinsics agree with the Spike B measurement within 2%', (_) async {
    final open = report['open'] as Map<String, Object?>?;
    expect(open, isNotNull, reason: 'test 1 must run first');

    if (_spikeBHfovDegrees.isEmpty) {
      // ignore: avoid_print
      print(
        'SKIPPED: no --dart-define=SPIKE_B_HFOV_DEGREES. Measure it per '
        'spikes/README.md — two marks on a wall at the frame edges, a tape '
        'measure, hfov = 2·atan(separation / (2·distance)) — and re-run. '
        'Derived HFOV was ${open!['hfov_degrees']}° via branch '
        '${open['intrinsics_branch']}.',
      );
      report['intrinsics_check'] = {
        'status': 'skipped',
        'reason': 'no physical measurement supplied',
        'derived_hfov_degrees': open['hfov_degrees'],
        'branch': open['intrinsics_branch'],
      };
      return;
    }

    final measured = double.parse(_spikeBHfovDegrees);
    final derived = open!['hfov_degrees']! as double;
    final error = (derived - measured).abs() / measured;
    report['intrinsics_check'] = {
      'status': 'measured',
      'measured_hfov_degrees': measured,
      'derived_hfov_degrees': derived,
      'relative_error': error,
      'tolerance': _hfovTolerance,
      'branch': open['intrinsics_branch'],
      'notes': open['intrinsics_notes'],
    };

    expect(
      error,
      lessThanOrEqualTo(_hfovTolerance),
      reason:
          'the derived HFOV (${derived.toStringAsFixed(2)}°, via '
          '${open['intrinsics_branch']}) is ${(error * 100).toStringAsFixed(1)}% from '
          'the measured ${measured.toStringAsFixed(2)}°. Architecture §2 defect 2: '
          'a 4% focal error means the panorama does not close',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('3+4. AE and AWB lock hold over 29 grey-card captures', (_) async {
    if (!_greyCard) {
      // ignore: avoid_print
      print(
        'SKIPPED: no --dart-define=GREY_CARD=true. Clamp the tablet, fill the '
        'centre of the frame with an evenly-lit grey card, and re-run. This is '
        'the test that answers whether the #749574 lock drift affects our '
        'devices — Phase 04 gain compensation assumes the lock holds.',
      );
      report['lock_stability'] = {'status': 'skipped', 'reason': 'no grey card'};
      return;
    }

    final probe = CameraProbe(platform);
    final selection = await probe.selectCaptureCamera();
    await platform.open(
      selection.camera.id,
      CaptureFormatSpec(
        captureSize: probe.selectCaptureSize(selection.camera),
        computeFrameStatistics: true,
      ),
    );
    final metering = await ExposureController(platform).meterAndLock();

    // One frame per capture: the bracket deliberately varies exposure, so
    // measuring drift across a bracket would measure the bracket.
    final frames = <PlatformFrame>[];
    for (var i = 0; i < _positionCount; i++) {
      final capture = await platform.captureBracket(
        const [0.0],
        outputDirectory: workDirectory.path,
        namePrefix: 'grey$i',
      );
      frames.addAll(capture.frames);
    }
    await platform.close();

    final luma = [
      for (final f in frames)
        if (f.meanLuma != null) f.meanLuma!,
    ];
    expect(
      luma.length,
      _positionCount,
      reason: 'frame statistics were requested but not returned for every frame',
    );

    double spread(List<double> values) {
      final mean = values.reduce((a, b) => a + b) / values.length;
      if (mean == 0) return double.infinity;
      final lo = values.reduce(math.min);
      final hi = values.reduce(math.max);
      return (hi - lo) / mean;
    }

    final lumaVariation = spread(luma);
    // Per channel, because a *ratio* moving while luminance holds is white
    // balance failing on its own — the exact shape the drift report describes.
    final rVariation = spread([for (final f in frames) f.meanR!]);
    final gVariation = spread([for (final f in frames) f.meanG!]);
    final bVariation = spread([for (final f in frames) f.meanB!]);
    final rOverG = [for (final f in frames) f.meanR! / f.meanG!];
    final bOverG = [for (final f in frames) f.meanB! / f.meanG!];

    report['lock_stability'] = {
      'status': 'measured',
      'lock_quality': metering.lockQuality.name,
      'pinned_processing_modes': metering.pinnedProcessingModes,
      'captures': frames.length,
      'luminance_variation': lumaVariation,
      'channel_variation': {'r': rVariation, 'g': gVariation, 'b': bVariation},
      'channel_ratio_variation': {
        'r_over_g': spread(rOverG),
        'b_over_g': spread(bOverG),
      },
      'limit': _luminanceVariationLimit,
      'mean_luma_first': luma.first,
      'mean_luma_last': luma.last,
      // A monotone trend is drift; scatter is noise. The distinction matters,
      // because only drift compounds across a session.
      'monotone_trend': _isMonotone(luma),
    };

    expect(
      lumaVariation,
      lessThanOrEqualTo(_luminanceVariationLimit),
      reason:
          'mean luminance varied by ${(lumaVariation * 100).toStringAsFixed(2)}% over '
          '$_positionCount captures of a static grey card, against a 1% limit. The AE '
          'lock is not holding, and Phase 04 gain compensation assumes it does',
    );
    for (final entry in {'R': rVariation, 'G': gVariation, 'B': bVariation}.entries) {
      expect(
        entry.value,
        lessThanOrEqualTo(_luminanceVariationLimit),
        reason:
            'the ${entry.key} channel varied by '
            '${(entry.value * 100).toStringAsFixed(2)}%; white balance is not holding',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('6. the camera↔motion clock offset is stable over 60 s', (_) async {
    // §2.5's arithmetic is why this is an exit criterion at all: a 10–50 ms
    // mismatch is 0.6–3° of rotation error at a realistic 60°/s pan, which is
    // larger than everything Phase 03 works to remove — and it presents as a
    // stitcher bug rather than as a clock bug.
    final probe = CameraProbe(platform);
    final selection = await probe.selectCaptureCamera();
    final opened = await platform.open(
      selection.camera.id,
      CaptureFormatSpec(captureSize: probe.selectCaptureSize(selection.camera)),
    );

    final samples = <ClockOffsetSample>[];
    final start = DateTime.now();
    while (DateTime.now().difference(start) < _clockObservationWindow) {
      samples.add(await platform.sampleClockOffset());
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    await platform.close();

    final offsets = [for (final s in samples) s.offsetUs];
    final minOffset = offsets.reduce(math.min);
    final maxOffset = offsets.reduce(math.max);
    final drift = maxOffset - minOffset;
    final worstUncertainty =
        samples.map((s) => s.uncertaintyUs).reduce(math.max);

    report['clock'] = {
      ...opened.clock.toJson(),
      'samples': samples.length,
      'window_seconds': _clockObservationWindow.inSeconds,
      'offset_min_us': minOffset,
      'offset_max_us': maxOffset,
      'drift_us': drift,
      'worst_sample_uncertainty_us': worstUncertainty,
      'limit_us': _clockStabilityLimitUs,
      // On Android REALTIME the two clocks *are* one clock, so the offset is
      // zero by construction and nothing was estimated. That is the right
      // answer, and worth distinguishing from a measured zero.
      'is_exact': opened.clock.isExact,
    };

    expect(
      drift,
      lessThanOrEqualTo(_clockStabilityLimitUs),
      reason:
          'the camera↔motion clock offset moved by $drift µs over '
          '${_clockObservationWindow.inSeconds} s, against a ±$_clockStabilityLimitUs µs '
          'limit. Every pose in every bundle is wrong by that much',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('thermal state is reported and acted on', (_) async {
    final state = await platform.thermalState();
    final capture = ThermalPolicy.forCapture(state);
    final stitch = ThermalPolicy.forStitch(state);
    final memoryMb = await platform.totalPhysicalMemoryMb();

    report['thermal'] = {
      'state': state.name,
      'capture_action': capture.action.name,
      'capture_message': capture.message,
      'stitch_action': stitch.action.name,
      'stitch_message': stitch.message,
    };
    report['total_physical_memory_mb'] = memoryMb;

    expect(memoryMb, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 1)));
}

/// Whether a series moves in one direction throughout — drift rather than
/// scatter. Only drift compounds across a session.
bool _isMonotone(List<double> values) {
  if (values.length < 3) return false;
  var rising = true;
  var falling = true;
  for (var i = 1; i < values.length; i++) {
    if (values[i] < values[i - 1]) rising = false;
    if (values[i] > values[i - 1]) falling = false;
  }
  return rising || falling;
}
