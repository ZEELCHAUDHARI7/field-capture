import 'dart:convert';
import 'dart:io';

import 'package:sphere_view/src/api/models/capture_bundle.dart';

import 'harness/camera_model.dart';
import 'harness/native_stitcher.dart';
import 'harness/stitcher_backend.dart';

/// Dumps the raw JSON report `sv_stitch` returns, without the harness's own
/// scoring in the way.
///
/// The two numbers exist for different reasons and disagreeing is diagnostic:
/// the native `rms_reprojection_error_px` is BA's residual over its own
/// inliers, so it says whether registration converged; the harness's S1 is
/// scored against ground truth, so it says whether it converged to the *right*
/// answer. A small native S1 with a huge harness S1 is a frame-convention bug,
/// not a solver bug.
///
///     dart run tools/probe_native.dart build/bundles/pristine
Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('usage: dart run tools/probe_native.dart <bundle-dir>');
    exitCode = 64;
    return;
  }

  final bundle = await CaptureBundle.load(Directory(arguments.first));
  // --opt key=value, repeatable, so a knob can be swept without a rebuild.
  final overrides = <String, Object?>{
    if (arguments.contains('--no-ba')) 'skip_bundle_adjustment': true,
  };
  for (var i = 0; i < arguments.length - 1; i++) {
    if (arguments[i] != '--opt') continue;
    final parts = arguments[i + 1].split('=');
    overrides[parts.first] = num.tryParse(parts.last) ?? parts.last == 'true';
  }
  // Tier, and whether to run stages 10-15 at all.
  //
  // Peak RSS and wall clock are why this tool takes a tier: `tools/replay` holds
  // the ground truth, a resampled copy of it and the metric buffers alongside the
  // stitch, which at `high` is over 400 MB of *harness* before the stitcher
  // allocates anything. Criterion S9 is about the stitcher, so it has to be
  // measured somewhere the harness is not.
  var tier = 'mid';
  for (var i = 0; i < arguments.length - 1; i++) {
    if (arguments[i] == '--tier') tier = arguments[i + 1];
  }
  final registrationOnly = arguments.contains('--registration-only');
  final width = switch (tier) {
    'low' => 4096,
    'high' => 8192,
    _ => 6144,
  };

  final scratch = Directory('${bundle.directory.path}/replay/probe');
  final backend = NativeStitcherBackend(
    optionOverrides: overrides,
    registrationOnly: registrationOnly,
    tier: tier,
    workDirectory: scratch,
    compositingOverrides: {
      'output_width': width,
      // Off, because the device never writes them and they are not small: at
      // `high` the label map is 134 MB and the float scratch that builds it
      // another 134 MB, so leaving them on would have this tool reporting a
      // quarter of a gigabyte of diagnostics as though it were the pipeline.
      'emit_debug_maps': false,
    },
  );
  if (!registrationOnly) scratch.createSync(recursive: true);

  try {
    final stopwatch = Stopwatch()..start();
    final raw = backend.stitchRaw(
      StitchJob(bundle: bundle, canvas: EquirectCanvas.fromWidth(width)),
      scratch,
    );
    stopwatch.stop();
    final report = Map<String, Object?>.from(raw.report);
    // The rotations are 9 doubles per frame and would bury everything else.
    (report['registration'] as Map?)?.remove('rotations_camera_to_pano');
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('---');
    stdout.writeln('tier                   $tier (${width}x${width ~/ 2})');
    stdout.writeln('frames                 ${bundle.positions.length}');
    stdout.writeln(
      'wall clock             '
      '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
    );
    stdout.writeln(
      'peak rss               '
      '${(ProcessInfo.maxRss / (1024 * 1024)).round()} MB',
    );
  } on NativeStitchException catch (error) {
    stdout.writeln('code ${error.code}: ${error.message}');
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(error.report));
  }
}
