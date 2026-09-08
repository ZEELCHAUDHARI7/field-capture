import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'harness/camera_model.dart';
import 'harness/float_image.dart';
import 'harness/ground_truth.dart';
import 'harness/metrics.dart';
import 'harness/native_stitcher.dart';
import 'harness/profiles.dart';
import 'harness/scene.dart';
import 'harness/stitcher_backend.dart';
import 'harness/synth_runner.dart';
import 'package:sphere_view/src/api/models/capture_bundle.dart';
import 'package:sphere_view/src/api/models/sphere_capture_config.dart';
import 'package:sphere_view/src/api/models/image_size.dart';

/// `tools/parallax_sweep` — the honest floor under output quality, measured.
///
/// ```
/// dart run tools/parallax_sweep.dart
/// dart run tools/parallax_sweep.dart --offsets 0,0.10 --distances 1
/// ```
///
/// Phase 12's exit criteria ask for the parallax floor to be **measured and
/// documented rather than hidden**, and architecture §3 is why: a panorama is
/// only geometrically consistent if every frame comes from one optical centre,
/// handheld capture cannot do that, and no amount of bundle adjustment or seam
/// finding removes what is left. §3 predicts the disparity analytically —
/// `atan(r/d)`, tabulated for three lens offsets against three distances — and
/// then the project spent nine phases building a stitcher whose job is to *hide*
/// it. This is the measurement that says how well that worked, and at what point
/// technique stops being optional.
///
/// ## The experimental design, and why it is this
///
/// Every source of error except parallax is switched **off**: locked exposure, no
/// noise, exact poses, exact intrinsics, no distortion, no vignetting, no motion
/// blur. That is the `pristine` profile with two fields moved. The reason is that
/// the question is a difference — how much worse does a 10 cm offset make this —
/// and a difference between two numbers that each carry 9 px of unrelated error
/// is not a measurement of anything. It does mean the absolute figures here are
/// better than a real device will see; the *shape* is what transfers, and the
/// shape is what the capture technique doc needs.
///
/// The frames are small (240x320 against a 1024-wide ground truth) so the sweep
/// finishes in minutes rather than an afternoon. Parallax is an angular effect
/// and scales with the canvas, so the pixel figures below are quoted at the
/// canvas they were measured on and converted to degrees, which is the unit that
/// carries across resolutions.
Future<void> main(List<String> arguments) async {
  exitCode = await _run(arguments);
}

Future<int> _run(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options.help) {
    stdout.write(_usage);
    return 0;
  }

  final out = Directory(options.outputDirectory);
  await out.create(recursive: true);
  final rows = <Map<String, Object?>>[];

  for (final distance in options.distances) {
    for (final offset in options.offsets) {
      final name =
          'parallax_r${(offset * 100).round()}cm_d${distance.toStringAsFixed(0)}m';
      stdout.write('  ${name.padRight(28)}');

      // `pristine` with two fields moved. Written out rather than derived from
      // `SynthProfile.byName('pristine')` because `copyWith` does not exist on a
      // profile and adding one would invite exactly the kind of half-specified
      // fixture this sweep must not have.
      final profile = SynthProfile(
        name: name,
        purpose: 'parallax floor: r = ${offset}m, nearest surface = ${distance}m',
        sceneStyle: SceneStyle.constructionInterior,
        nearestSurfaceMetres: distance,
        lensOffsetMetres: offset,
        // Everything else off, so the only difference between two rows is the
        // geometry.
        dynamicRangeScale: 0,
        exposure: const ExposureStrategy.locked(),
        poseErrorRmsDegrees: 0,
        focalErrorFraction: 0,
        distortion: Distorter.identity,
        vignetting: 0,
        gainRmsStops: 0,
        readNoiseElectrons: 0,
        fullWellElectrons: double.infinity,
        angularSpeedDegreesPerSecond: 0,
        rollingShutterSeconds: 0,
      );

      final directory = Directory('${out.path}/$name');
      final clock = Stopwatch()..start();
      if (!options.reuseBundles || !directory.existsSync()) {
        await SynthRunner(
          profile: profile,
          frameSize: ImageSize(options.frameWidth, options.frameWidth * 4 / 3),
          groundTruthWidth: options.canvasWidth,
        ).run(directory);
      }
      final bundle = await CaptureBundle.load(directory);
      final truth = await GroundTruth.load(directory);
      final canvas = EquirectCanvas(truth.canvasWidth, truth.canvasHeight);

      final backend = NativeStitcherBackend(
        tier: 'low',
        workDirectory: Directory('${directory.path}/native'),
        compositingOverrides: {'output_width': canvas.width},
      );
      final outcome = await backend.stitch(
        StitchJob(bundle: bundle, canvas: canvas),
      );
      final reference = resampleEquirect(
        await FloatImage.loadRgb(
          File('${directory.path}/${GroundTruth.imageFileName}'),
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
        // The `pristine` bar, on purpose. Every other error source is off, so a
        // row that misses it is missing it *because of parallax* — which is the
        // measurement. Judging these against `parallax_1m`'s relaxed targets
        // would be assuming the answer.
        targets: MetricTargets.forProfile('pristine'),
      ).compute();
      clock.stop();

      double value(String id) => metrics.metrics
          .firstWhere(
            (m) => m.id == id,
            orElse: () => const Metric.unavailable(id: '', label: '', reason: ''),
          )
          .value;

      // §3's prediction for this row: the angular disparity a lens offset `r`
      // induces on content at distance `d`.
      //
      // Reported in **two** pixel units, because S1 and the panorama are not
      // measured in the same one and putting a single "predicted px" next to S1
      // would invite a comparison between frame pixels and canvas pixels. On this
      // fixture the two scales are within 20% of each other, so such a table
      // looks like a clean confirmation of the model and is really a coincidence
      // of geometry.
      //
      //   * frame pixels — what S1 is in (registration scale, which is 1.0 here
      //     because the frames are already under the 0.6 MP registration target).
      //     This is the column that may be compared with S1.
      //   * canvas pixels at the `mid` tier — what somebody looking at the
      //     panorama sees, which is the number architecture §3's table quotes and
      //     the one the capture-technique doc needs.
      final predictedDegrees = offset == 0
          ? 0.0
          : _degrees(math.atan(offset / distance));
      final framePxPerDegree = options.frameWidth / options.hfovDegrees;
      final predictedFramePx = predictedDegrees * framePxPerDegree;
      final predictedTierPx = predictedDegrees * 6144 / 360.0;

      rows.add({
        'name': name,
        'lens_offset_m': offset,
        'nearest_surface_m': distance,
        'canvas_width': canvas.width,
        'predicted_disparity_degrees': predictedDegrees,
        'predicted_disparity_frame_px': predictedFramePx,
        'predicted_disparity_tier_px': predictedTierPx,
        'frame_width_px': options.frameWidth,
        'hfov_degrees': options.hfovDegrees,
        's1_rms_px': value('s1'),
        's2_loop_degrees': value('s2'),
        's3_seam': value('s3'),
        's3_wrap': value('s3_wrap'),
        's6_ssim': value('s6_ssim'),
        's6_psnr': value('s6_psnr'),
        'residual_scale_correlation':
            outcome.diagnostics['residual_scale_correlation'],
        'elapsed_ms': clock.elapsedMilliseconds,
      });
      stdout.writeln(
        'S1 ${value('s1').toStringAsFixed(2)} px   '
        'S3 ${value('s3').toStringAsFixed(2)}x   '
        'SSIM ${value('s6_ssim').toStringAsFixed(4)}   '
        '(§3 predicts ${predictedFramePx.toStringAsFixed(1)} frame px, '
        '${predictedTierPx.toStringAsFixed(0)} px at 6144 wide)',
      );

      if (!options.keepBundles) {
        // A sweep of eight is ~1 GB of frames, and the numbers are the artefact.
        for (final entity in directory.listSync()) {
          if (entity is File && entity.path.endsWith('.jpg')) entity.deleteSync();
        }
      }
    }
  }

  final table = _render(rows);
  stdout
    ..writeln()
    ..write(table);
  await File('${out.path}/parallax_floor.md').writeAsString(table);
  await File('${out.path}/parallax_floor.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'measured': DateTime.now().toUtc().toIso8601String(),
      'note':
          'every error source except parallax is off; see the header of '
          'tools/parallax_sweep.dart for why, and what that means for the '
          'absolute figures',
      'rows': rows,
    }),
  );
  stdout.writeln('written to ${out.path}/parallax_floor.{md,json}');
  return 0;
}

String _render(List<Map<String, Object?>> rows) {
  final buffer = StringBuffer()
    ..writeln('# The parallax floor, measured')
    ..writeln()
    ..writeln(
      'Every error source except parallax is off — locked exposure, no noise, '
      'exact poses, exact intrinsics, a perfect lens. So the difference between '
      'the first row of a block and the rest **is** the parallax, and nothing '
      'else. Absolute figures are therefore better than a real device sees; the '
      'shape is what transfers.',
    )
    ..writeln()
    ..writeln(
      '| lens offset `r` | nearest `d` | §3 disparity | §3 in frame px | '
      'S1 measured | S1 / predicted | S3 seam | SSIM | PSNR | at 6144 wide |',
    )
    ..writeln(
      '| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |',
    );
  for (final row in rows) {
    final offset = (row['lens_offset_m']! as num) * 100;
    final predicted = (row['predicted_disparity_frame_px']! as num).toDouble();
    final measured = (row['s1_rms_px']! as num).toDouble();
    buffer.writeln(
      '| ${offset.toStringAsFixed(0)} cm '
      '| ${(row['nearest_surface_m']! as num).toStringAsFixed(0)} m '
      '| ${(row['predicted_disparity_degrees']! as num).toStringAsFixed(2)}° '
      '| ${predicted.toStringAsFixed(1)} px '
      '| ${measured.toStringAsFixed(2)} px '
      '| ${predicted <= 0 ? '—' : (measured / predicted).toStringAsFixed(2)} '
      '| ${(row['s3_seam']! as num).toStringAsFixed(2)}x '
      '| ${(row['s6_ssim']! as num).toStringAsFixed(4)} '
      '| ${(row['s6_psnr']! as num).toStringAsFixed(1)} dB '
      '| ${(row['predicted_disparity_tier_px']! as num).toStringAsFixed(0)} px |',
    );
  }
  buffer
    ..writeln()
    ..writeln(
      '**Units.** `S1` is RMS reprojection error in **frame** pixels at '
      'registration scale, so the column it may be compared against is "§3 in '
      'frame px" — the predicted disparity converted through this fixture\'s '
      '${rows.isEmpty ? '?' : rows.first['frame_width_px']} px frame over '
      '${rows.isEmpty ? '?' : rows.first['hfov_degrees']}° of horizontal field. '
      'The last column is the same angle in **canvas** pixels of a `mid`-tier '
      '6144-wide panorama, which is what somebody looking at the output sees and '
      'what architecture §3\'s table quotes. The two differ by about 5x here, so '
      'a table with only one "predicted px" column would invite a comparison '
      'between two different units — and on this fixture the wrong comparison '
      'happens to look like a clean confirmation of the model.',
    );
  return buffer.toString();
}

double _degrees(double radians) => radians * 180 / math.pi;

const String _usage = '''
tools/parallax_sweep — measure the floor architecture §3 predicts.

  --offsets <a,b>     entrance-pupil offsets in metres (default 0,0.03,0.10,0.25)
  --distances <a,b>   nearest-surface distances in metres (default 1,3)
  --frame-width <px>  rendered frame width (default 240)
  --canvas <px>       ground-truth equirect width (default 1024)
  --hfov <deg>        the rig's horizontal field of view (default 50)
  --out <dir>         where bundles and the table go (default build/parallax)
  --keep-bundles      do not delete the frames afterwards
  --reuse-bundles     skip rendering where a bundle already exists
  --help
''';

class _Options {
  _Options({
    required this.offsets,
    required this.distances,
    required this.frameWidth,
    required this.canvasWidth,
    required this.hfovDegrees,
    required this.outputDirectory,
    required this.keepBundles,
    required this.reuseBundles,
    required this.help,
  });

  final List<double> offsets;
  final List<double> distances;
  final double frameWidth;
  final int canvasWidth;

  /// The true horizontal field of view the rig renders through, which is what
  /// converts an angle into frame pixels. Must match `SynthRunner`'s default, or
  /// the predicted column describes a different camera from the measured one.
  final double hfovDegrees;
  final String outputDirectory;
  final bool keepBundles;
  final bool reuseBundles;
  final bool help;

  static _Options parse(List<String> arguments) {
    // 0 is the control and it is not optional: without it the other rows are
    // absolute numbers rather than a measured difference.
    var offsets = <double>[0, 0.03, 0.10, 0.25];
    var distances = <double>[1, 3];
    var frameWidth = 240.0;
    var canvasWidth = 1024;
    // `SynthRunner.horizontalFovDegrees`. Repeated rather than read because the
    // runner takes it as a constructor default and this file has to convert with
    // the same number it rendered with.
    var hfovDegrees = 50.0;
    var out = 'build/parallax';
    var keep = false;
    var reuse = false;
    var help = false;
    for (var i = 0; i < arguments.length; i++) {
      switch (arguments[i]) {
        case '--offsets':
          offsets = arguments[++i].split(',').map(double.parse).toList();
        case '--distances':
          distances = arguments[++i].split(',').map(double.parse).toList();
        case '--frame-width':
          frameWidth = double.parse(arguments[++i]);
        case '--canvas':
          canvasWidth = int.parse(arguments[++i]);
        case '--hfov':
          hfovDegrees = double.parse(arguments[++i]);
        case '--out':
          out = arguments[++i];
        case '--keep-bundles':
          keep = true;
        case '--reuse-bundles':
          reuse = true;
        case '--help' || '-h':
          help = true;
        default:
          throw ArgumentError('unknown argument: ${arguments[i]}');
      }
    }
    return _Options(
      offsets: offsets,
      distances: distances,
      frameWidth: frameWidth,
      canvasWidth: canvasWidth,
      hfovDegrees: hfovDegrees,
      outputDirectory: out,
      keepBundles: keep,
      reuseBundles: reuse,
      help: help,
    );
  }
}
