import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:sphere_view/src/api/models/capture_bundle.dart';
import 'package:sphere_view/src/api/models/sphere_capture_config.dart';

import 'harness/camera_model.dart';
import 'harness/diff_image.dart';
import 'harness/float_image.dart';
import 'harness/field_metrics.dart';
import 'harness/ground_truth.dart';
import 'harness/legacy_dart_stitcher.dart';
import 'harness/metrics.dart';
import 'harness/native_stitcher.dart';
import 'harness/report.dart';
import 'harness/stitcher_backend.dart';

/// `tools/replay` — bundle in, metrics out.
///
/// ```
/// dart run tools/replay.dart --bundle build/bundles/nominal
/// dart run tools/replay.dart --bundle build/bundles/nominal --backend native
/// dart run tools/replay.dart --bundle build/bundles/nominal --report json
/// ```
///
/// The default output canvas matches the ground truth rather than a device
/// tier, and that is on purpose: comparing a 4096-wide stitch against a
/// 2048-wide reference means one of them gets resampled, and a resample is a
/// blur, and a blur moves SSIM in a direction that has nothing to do with the
/// stitcher. `--tier` is there for measuring time and memory at a realistic
/// output size, where fidelity is not the question being asked.
Future<void> main(List<String> arguments) async {
  exitCode = await _run(arguments);
}

/// The real entry point.
///
/// Split out because Dart does **not** turn a value returned from `main` into
/// the process exit code — it is silently discarded, and a CI gate that always
/// exits 0 is worse than no gate at all.
Future<int> _run(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options.help) {
    stdout.write(_usage);
    return 0;
  }

  final directory = Directory(options.bundle!);
  final bundle = await CaptureBundle.load(directory);

  // A bundle with no `ground_truth.json` is a **field** capture (Phase 12 §4):
  // a real station, from a real site, with no answers because nobody surveyed the
  // building. It is replayed through the same stitcher and scored by
  // `FieldMetricsEngine`, which measures the five criteria that need no reference
  // and reports the stitcher's own S1/S2/tilt under separate `*_reported` ids
  // rather than passing self-assessment off as measurement.
  if (!File(
    '${directory.path}${Platform.pathSeparator}${GroundTruth.fileName}',
  ).existsSync()) {
    return _replayField(directory, bundle, options);
  }

  final truth = await GroundTruth.load(directory);

  final canvas = options.tier != null
      ? EquirectCanvas.fromWidth(options.tier!.outputWidth)
      : EquirectCanvas(truth.canvasWidth, truth.canvasHeight);

  final backend = _backendNamed(options.backend, options, directory);

  final total = Stopwatch()..start();
  final StitchOutcome outcome;
  try {
    outcome = await backend.stitch(
      StitchJob(bundle: bundle, canvas: canvas),
    );
  } on StateError catch (error) {
    stderr.writeln(error.message);
    return 2;
  } on NativeStitchException catch (error) {
    // A refusal is a result, not a crash. `sparse_plan` is *required* to end
    // up here (§7), so the message has to be the actionable one the native
    // side wrote, and the warnings that led to it have to survive.
    stderr.writeln('${truth.profile}: registration refused this capture');
    stderr.writeln('  ${error.message}');
    for (final warning in (error.report?['warnings'] as List? ?? const [])) {
      stderr.writeln('  - $warning');
    }
    return 3;
  }
  total.stop();

  final reference = resampleEquirect(
    await FloatImage.loadRgb(
      File(
        '${directory.path}${Platform.pathSeparator}${GroundTruth.imageFileName}',
      ),
    ),
    canvas,
  );

  // The EV map, when the scene needed one. Loaded through the same scale and bias
  // it was written with, so the stops it holds are exactly the stops the renderer
  // applied — Phase 05's two metrics select their regions from this, and a region
  // off by a stop would be a different region.
  final evFile = truth.evFileName;
  final evMap = evFile == null
      ? null
      : resampleScalar(
          await FloatImage.loadScalar(
            File('${directory.path}${Platform.pathSeparator}$evFile'),
            scale: 2 * GroundTruth.evScaleStops,
            bias: -GroundTruth.evScaleStops,
          ),
          canvas,
        );

  final result = MetricsEngine(
    bundle: bundle,
    truth: truth,
    outcome: outcome,
    groundTruthImage: reference,
    canvas: canvas,
    evMap: evMap,
    peakRssBytes: MetricsEngine.currentPeakRss(),
    // §8 sets a different bar for `pristine` than for `parallax_1m`, and
    // collapsing the two would either excuse a broken control or fail a profile
    // for obeying optics.
    targets: MetricTargets.forProfile(truth.profile),
  ).compute();

  final out = Directory(options.out ?? '${directory.path}/replay');
  await out.create(recursive: true);
  final separator = Platform.pathSeparator;

  await File('${out.path}${separator}stitched.png').writeAsBytes(
    img.encodePng(outcome.equirect.toRgb8()),
  );
  await File('${out.path}${separator}diff_amplified.png').writeAsBytes(
    img.encodePng(
      DiffImage.render(
        stitched: outcome.equirect,
        groundTruth: reference,
        outcome: outcome,
        canvas: canvas,
        amplification: options.amplification,
      ),
    ),
  );
  await File('${out.path}${separator}labels.png').writeAsBytes(
    img.encodePng(DiffImage.renderLabels(outcome: outcome, canvas: canvas)),
  );
  // §2's wrap-seam test rolls the output by W/2 to bring the ±180° meridian to
  // the centre. The metric does that internally; this writes the same roll out
  // so a failing `s3_wrap` can be looked at rather than only argued about — the
  // seam lands exactly down the middle of this file.
  await File('${out.path}${separator}rolled.png').writeAsBytes(
    img.encodePng(rollHalf(outcome.equirect).toRgb8()),
  );

  final json = ReportFormatter.json(
    result,
    profile: truth.profile,
    backend: backend.name,
  );
  await File('${out.path}${separator}metrics.json').writeAsString(json);

  if (options.reportJson) {
    stdout.writeln(json);
  } else {
    stdout.write(
      ReportFormatter.text(
        result,
        profile: truth.profile,
        backend: backend.name,
        focal: describeFocal(
          outcome.estimatedIntrinsics,
          truth.trueIntrinsics,
        ),
        totalMilliseconds: total.elapsedMilliseconds,
      ),
    );
    stdout.writeln('artefacts              ${out.path}');
  }

  if (options.baseline != null) {
    await File(options.baseline!).writeAsString(
      ReportFormatter.baselineJson(
        result,
        profile: truth.profile,
        backend: backend.name,
        note: options.baselineNote,
      ),
    );
    stdout.writeln('baseline written       ${options.baseline}');
  }

  // A non-zero exit only when asked for. The default is that a FAIL is a
  // *result*, printed and recorded — `quality_gate.sh` decides whether a
  // recorded FAIL is a regression, because during this phase every profile is
  // expected to fail and the harness proving it is the deliverable.
  return options.failOnMiss && !result.allPass ? 1 : 0;
}

/// Replays a real capture: same stitcher, reference-free metrics.
///
/// Deliberately a separate function rather than a branch threaded through the
/// synthetic one. Half of what the synthetic path does is about the reference —
/// resample it to the canvas, diff against it, exclude the pole caps from SSIM,
/// write an amplified difference image — and none of that exists here. Sharing the
/// body would mean a dozen `if (truth != null)` branches in a file whose job is to
/// be obviously correct about which number came from where.
Future<int> _replayField(
  Directory directory,
  CaptureBundle bundle,
  _Options options,
) async {
  final scene =
      FieldScene.byName(directory.path.split(Platform.pathSeparator).last);
  if (scene == null) {
    stderr.writeln(
      'no ground truth in ${directory.path}, so this is a field bundle — but its '
      'directory name is not one of the seven scenes in FieldScene.all. Rename it '
      'to the scene it is, or add the scene: the per-scene thresholds are the '
      'whole reason a tight room at 1 m and an open daylight shell are not judged '
      'against the same bar.',
    );
    return 2;
  }

  final canvas = options.tier != null
      ? EquirectCanvas.fromWidth(options.tier!.outputWidth)
      // The `mid` tier by default. A field bundle has no reference to match, so
      // there is nothing to be gained by an unusual canvas and the tier is what a
      // device would actually produce.
      : EquirectCanvas.fromWidth(QualityTier.mid.outputWidth);
  final backend = _backendNamed(options.backend, options, directory);

  final total = Stopwatch()..start();
  final StitchOutcome outcome;
  try {
    outcome = await backend.stitch(StitchJob(bundle: bundle, canvas: canvas));
  } on NativeStitchException catch (error) {
    stderr.writeln('${scene.name}: the stitcher refused this capture');
    stderr.writeln('  ${error.message}');
    return 3;
  }
  total.stop();

  final report = outcome.diagnostics;
  final metrics = FieldMetricsEngine(
    bundle: bundle,
    outcome: outcome,
    canvas: canvas,
    peakRssBytes: MetricsEngine.currentPeakRss(),
    scene: scene,
    reportedRmsPx: _asDouble(report['rms_reprojection_error_px']),
    reportedLoopDegrees: _asDouble(report['loop_closure_error_degrees']),
    reportedTiltDegrees: _asDouble(report['residual_tilt_degrees']),
  ).compute();

  final result = MetricsResult(
    metrics: metrics,
    worstSeams: const [],
    excludedFraction: 0,
    stageMilliseconds: outcome.stageMilliseconds,
    warnings: outcome.warnings,
    diagnostics: outcome.diagnostics,
  );

  final out = Directory(options.out ?? '${directory.path}/replay');
  await out.create(recursive: true);
  final separator = Platform.pathSeparator;
  await File('${out.path}${separator}stitched.png').writeAsBytes(
    img.encodePng(outcome.equirect.toRgb8()),
  );
  await File('${out.path}${separator}labels.png').writeAsBytes(
    img.encodePng(DiffImage.renderLabels(outcome: outcome, canvas: canvas)),
  );

  final json = ReportFormatter.json(
    result,
    profile: scene.name,
    backend: backend.name,
  );
  await File('${out.path}${separator}metrics.json').writeAsString(json);
  if (options.reportJson) {
    stdout.writeln(json);
  } else {
    stdout
      ..writeln('field scene ${scene.name}   backend ${backend.name}')
      ..writeln('stresses               ${scene.stresses}')
      ..writeln(
        'no ground truth        S1, S2, S6 and residual tilt are NOT measured '
        'here; the (self) rows are the stitcher\'s own figures',
      );
    stdout.write(
      ReportFormatter.text(
        result,
        profile: scene.name,
        backend: backend.name,
        focal:
            '${outcome.estimatedIntrinsics.fx.toStringAsFixed(1)} px (no true '
            'focal to compare against)',
        totalMilliseconds: total.elapsedMilliseconds,
      ),
    );
    stdout.writeln('artefacts              ${out.path}');
  }

  if (options.baseline != null) {
    await File(options.baseline!).writeAsString(
      ReportFormatter.baselineJson(
        result,
        profile: scene.name,
        backend: backend.name,
        note: options.baselineNote,
      ),
    );
  }
  return options.failOnMiss && !result.allPass ? 1 : 0;
}

double? _asDouble(Object? value) => value is num ? value.toDouble() : null;

StitcherBackend _backendNamed(
  String name,
  _Options options,
  Directory bundle,
) => switch (name) {
  'legacy-dart' => const LegacyDartStitcher(),
  'reference-dart' => const ReferenceDartStitcher(),
  'native' => NativeStitcherBackend(
    registrationOnly: options.registrationOnly,
    tier: options.tier?.name ?? 'mid',
    hdrOverrides: {
      if (!options.hdrFusion) 'enabled': false,
      if (options.hdrAligner != null) 'aligner': options.hdrAligner,
      if (options.keepFused) 'keep_fused_frames': true,
      if (options.serialDecode) 'parallel_decode': false,
      if (options.hdrMaxOversampling != null)
        'max_oversampling': options.hdrMaxOversampling,
      if (!options.ghostSuppression) 'ghost_suppression': false,
      if (options.hdrExposureWeight != null)
        'exposure_weight': options.hdrExposureWeight,
      if (options.hdrContrastWeight != null)
        'contrast_weight': options.hdrContrastWeight,
    },
    workDirectory: Directory(
      '${options.out ?? '${bundle.path}/replay'}/native',
    ),
    compositingOverrides: {
      if (options.seamFinder != null) 'seam_finder': options.seamFinder,
      if (options.verifyStrips) 'verify_strip_equivalence': true,
      if (options.stripCount != null) 'strip_count': options.stripCount,
      if (options.numBands != null) 'num_bands': options.numBands,
      if (options.blender != null) 'blender': options.blender,
      if (!options.fillPoles) 'fill_poles': false,
      if (!options.gainCompensation) 'gain_compensation': false,
    },
  ),
  _ => throw ArgumentError.value(
    name,
    'backend',
    'expected legacy-dart, reference-dart or native',
  ),
};

const String _usage = '''
tools/replay — stitch a CaptureBundle and score it against its ground truth.

  --bundle <dir>       the bundle to replay (required)
  --backend <name>     legacy-dart (default, the control group),
                       reference-dart (correct intrinsics, still naive),
                       or native (Phases 03-05)
  --tier low|mid|high  stitch at a device tier instead of at ground-truth size
  --out <dir>          where to write artefacts (default <bundle>/replay)
  --report json        print the JSON report instead of the table
  --amplify <n>        diff amplification (default 4)
  --baseline <file>    also write a baseline JSON for the quality gate
  --baseline-note <s>  the explanation recorded in that baseline
  --fail-on-miss       exit non-zero when any metric misses its target
  --help

native backend only:
  --registration-only  stop after stage 9, as Phase 03 did
  --no-hdr             skip stage 5 and register the 0 EV frame of each
                       bracket — the single-exposure control group
  --serial-decode      decode the bracket serially, to bisect determinism
  --hdr-aligner <m>    ecc (default), mtb, ecc+mtb or none
  --hdr-exposure-weight <w>
                       Mertens well-exposedness weight (§2)
  --hdr-contrast-weight <w>
                       Mertens contrast weight (§2)
  --no-ghost           skip ghost suppression, to see what it is buying
  --hdr-oversampling   frame-vs-canvas oversampling above which frames are
                       downscaled before fusion (default 2.0; 0 disables)
  --keep-fused         leave the fused frames on disk for inspection
  --seam-finder <m>    graph-cut (default) or feather — §8's parallax control
  --verify-strips      blend a second time on the full canvas and assert §5's
                       strip equivalence instead of reporting it as untested
  --strips <n>         override the tier's strip count
  --no-pole-fill       skip stage 14, to see the real holes
  --no-gain            skip stage 11, to see what compensation is buying
  --bands <n>          multi-band pyramid depth (default: from canvas width)
  --blender <m>        multiband or feather, independently of --seam-finder
''';

class _Options {
  _Options({
    required this.bundle,
    required this.backend,
    required this.tier,
    required this.out,
    required this.reportJson,
    required this.amplification,
    required this.baseline,
    required this.baselineNote,
    required this.failOnMiss,
    required this.help,
    required this.registrationOnly,
    required this.seamFinder,
    required this.verifyStrips,
    required this.stripCount,
    required this.fillPoles,
    required this.gainCompensation,
    required this.numBands,
    required this.blender,
    required this.hdrFusion,
    required this.hdrAligner,
    required this.ghostSuppression,
    required this.serialDecode,
    required this.hdrMaxOversampling,
    required this.keepFused,
    required this.hdrExposureWeight,
    required this.hdrContrastWeight,
  });

  final String? bundle;
  final String backend;
  final QualityTier? tier;
  final String? out;
  final bool reportJson;
  final int amplification;
  final String? baseline;
  final String baselineNote;
  final bool failOnMiss;
  final bool help;

  /// Stop after stage 9. Native backend only.
  final bool registrationOnly;

  /// `graph-cut` or `feather` — the two sides of §8's `parallax_1m` comparison.
  /// Null leaves the native default, which is the graph cut.
  final String? seamFinder;

  /// Ask the native side to blend twice and report the difference (§5).
  final bool verifyStrips;

  /// Override the tier's strip count, so the strip-equivalence assertion can be
  /// made against a number of strips that is not 1.
  final int? stripCount;

  /// Stage 14. Off for the diagnostic that wants to see the real holes.
  final bool fillPoles;

  /// Stage 11. Off to ask what the compensator is actually buying.
  final bool gainCompensation;

  /// Multi-band pyramid depth. Only for characterising the blender.
  final int? numBands;

  /// `multiband` or `feather`, overriding whatever [seamFinder] implied. Set both
  /// to attribute §8's parallax difference to the seam finder alone.
  final String? blender;

  /// Stage 5. Off is the single-exposure control Phase 05's second exit
  /// criterion is measured against.
  final bool hdrFusion;

  /// Which inter-exposure alignment estimator to use, for §7's benchmark.
  final String? hdrAligner;

  /// Stage 5's §3.3. Off to ask what ghost suppression is buying.
  final bool ghostSuppression;

  /// Decode the bracket serially — a bisect handle for the determinism bug.
  final bool serialDecode;

  /// §5's downscale threshold. `0` disables the downscale entirely.
  final double? hdrMaxOversampling;

  /// Leave the fused frames on disk so they can be looked at.
  final bool keepFused;

  /// Mertens' well-exposedness weight. §2 sets it to 0 and says to measure.
  final double? hdrExposureWeight;

  /// Mertens' contrast weight. Raising it sharpens the per-band winner, which is
  /// the alternative to the well-exposedness term for lifting deep shadows.
  final double? hdrContrastWeight;

  static _Options parse(List<String> arguments) {
    String? bundle;
    var backend = 'legacy-dart';
    QualityTier? tier;
    String? out;
    var reportJson = false;
    var amplification = DiffImage.defaultAmplification;
    String? baseline;
    var baselineNote = '';
    var failOnMiss = false;
    var help = arguments.isEmpty;
    var registrationOnly = false;
    String? seamFinder;
    var verifyStrips = false;
    int? stripCount;
    var fillPoles = true;
    var gainCompensation = true;
    int? numBands;
    String? blender;
    var hdrFusion = true;
    String? hdrAligner;
    var serialDecode = false;
    var ghostSuppression = true;
    double? hdrMaxOversampling;
    var keepFused = false;
    double? hdrExposureWeight;
    double? hdrContrastWeight;

    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--bundle':
          bundle = arguments[++i];
        case '--backend':
          backend = arguments[++i];
        case '--tier':
          // The argument is read once, into a local, before the search. Inlining
          // `arguments[++i]` into the predicate advances `i` on **every candidate
          // firstWhere tries**, so `--tier mid` compared 'low' against "mid", then
          // 'mid' against the next flag, then 'high' against the flag's value, and
          // threw "tier must be low, mid or high" for a tier that was spelled
          // correctly.
          final tierName = arguments[++i];
          tier = QualityTier.values.firstWhere(
            (t) => t.name == tierName,
            orElse: () => throw ArgumentError('tier must be low, mid or high'),
          );
        case '--out':
          out = arguments[++i];
        case '--report':
          reportJson = arguments[++i] == 'json';
        case '--amplify':
          amplification = int.parse(arguments[++i]);
        case '--baseline':
          baseline = arguments[++i];
        case '--baseline-note':
          baselineNote = arguments[++i];
        case '--fail-on-miss':
          failOnMiss = true;
        case '--registration-only':
          registrationOnly = true;
        case '--seam-finder':
          seamFinder = arguments[++i];
          if (seamFinder != 'graph-cut' && seamFinder != 'feather') {
            throw ArgumentError('--seam-finder must be graph-cut or feather');
          }
        case '--verify-strips':
          verifyStrips = true;
        case '--strips':
          stripCount = int.parse(arguments[++i]);
        case '--no-pole-fill':
          fillPoles = false;
        case '--no-gain':
          gainCompensation = false;
        case '--bands':
          numBands = int.parse(arguments[++i]);
        case '--blender':
          blender = arguments[++i];
          if (blender != 'multiband' && blender != 'feather') {
            throw ArgumentError('--blender must be multiband or feather');
          }
        case '--no-hdr':
          hdrFusion = false;
        case '--serial-decode':
          serialDecode = true;
          break;
        case '--hdr-aligner':
          hdrAligner = arguments[++i];
          if (!['ecc', 'mtb', 'ecc+mtb', 'none'].contains(hdrAligner)) {
            throw ArgumentError('--hdr-aligner must be ecc, mtb, ecc+mtb or none');
          }
        case '--no-ghost':
          ghostSuppression = false;
        case '--hdr-oversampling':
          hdrMaxOversampling = double.parse(arguments[++i]);
        case '--keep-fused':
          keepFused = true;
        case '--hdr-exposure-weight':
          hdrExposureWeight = double.parse(arguments[++i]);
        case '--hdr-contrast-weight':
          hdrContrastWeight = double.parse(arguments[++i]);
        case '--help' || '-h':
          help = true;
        default:
          throw ArgumentError('unknown argument "${arguments[i]}"');
      }
    }
    if (!help && bundle == null) {
      throw ArgumentError('pass --bundle <dir>');
    }
    return _Options(
      bundle: bundle,
      backend: backend,
      tier: tier,
      out: out,
      reportJson: reportJson,
      amplification: amplification,
      baseline: baseline,
      baselineNote: baselineNote,
      failOnMiss: failOnMiss,
      help: help,
      registrationOnly: registrationOnly,
      seamFinder: seamFinder,
      verifyStrips: verifyStrips,
      stripCount: stripCount,
      fillPoles: fillPoles,
      gainCompensation: gainCompensation,
      numBands: numBands,
      blender: blender,
      hdrFusion: hdrFusion,
      hdrAligner: hdrAligner,
      ghostSuppression: ghostSuppression,
      serialDecode: serialDecode,
      hdrMaxOversampling: hdrMaxOversampling,
      keepFused: keepFused,
      hdrExposureWeight: hdrExposureWeight,
      hdrContrastWeight: hdrContrastWeight,
    );
  }
}
