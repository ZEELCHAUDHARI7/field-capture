import 'dart:convert';
import 'dart:io';

/// Produces a copy of a bundle at a different **intrinsics quality tier**.
///
/// R2's central finding for this phase is that intrinsics quality is a
/// *gradient, not a constant*: a calibrated multi-camera Android tablet, a
/// physics-derived tablet, and a base iPad with only a FOV-derived focal are
/// three genuinely different inputs, and Phase 03 §2 requires registration to
/// tolerate all of them. It also requires the cost to be **measured**: run
/// `nominal` at the best and worst tiers and record the gap, because that
/// number is what the iOS fleet actually loses — and it is worth knowing before
/// anyone explains it away.
///
/// The synthetic profiles ship at the worst tier on purpose (`distortion: null`
/// with a 3% focal error), which mirrors the fleet. This tool writes the
/// best-tier counterpart by handing the stitcher the distortion model the
/// renderer actually used, taken from `ground_truth.json`.
///
/// The focal error is left in place deliberately. Changing two variables at
/// once would measure their sum; the question is what the *distortion model*
/// alone buys, and bundle adjustment is supposed to recover the focal either
/// way.
///
///     dart run tools/intrinsics_tier.dart build/bundles/nominal best
Future<void> main(List<String> arguments) async {
  if (arguments.length < 2) {
    stderr.writeln(
      'usage: dart run tools/intrinsics_tier.dart <bundle-dir> <best|worst> [out-dir]',
    );
    exitCode = 64;
    return;
  }

  final source = Directory(arguments[0]);
  final tier = arguments[1];
  final target = Directory(
    arguments.length > 2 ? arguments[2] : '${source.path}_$tier',
  );

  final manifest =
      jsonDecode(await File('${source.path}/bundle.json').readAsString())
          as Map<String, Object?>;
  final truth =
      jsonDecode(await File('${source.path}/ground_truth.json').readAsString())
          as Map<String, Object?>;

  final intrinsics = (manifest['intrinsics'] as Map).cast<String, Object?>();
  final trueIntrinsics =
      (truth['true_intrinsics'] as Map).cast<String, Object?>();

  switch (tier) {
    case 'best':
      // The distortion the renderer actually applied, plus the provenance a
      // device that could supply it would report.
      intrinsics['distortion'] = trueIntrinsics['distortion'];
      intrinsics['source'] = 'platformCalibration';
    case 'calibrated':
      // Both the distortion model AND the true focal. Not a fleet tier — no
      // device delivers this — but the control that separates "undistortion is
      // implemented wrong" from "undistortion is being handed a focal that is
      // 3% off, so it corrects at the wrong radii".
      intrinsics['distortion'] = trueIntrinsics['distortion'];
      intrinsics['source'] = 'platformCalibration';
      intrinsics['fx'] = trueIntrinsics['fx'];
      intrinsics['fy'] = trueIntrinsics['fy'];
    case 'worst':
      intrinsics['distortion'] = null;
      intrinsics['source'] = 'exifFallback';
    default:
      stderr.writeln('tier must be "best", "calibrated" or "worst"');
      exitCode = 64;
      return;
  }
  manifest['intrinsics'] = intrinsics;

  if (target.existsSync()) target.deleteSync(recursive: true);
  await target.create(recursive: true);

  // Symlink the frames rather than copying them. A tier variant differs only in
  // one JSON field, and duplicating a hundred JPEGs per comparison would make
  // the sweep slow enough that people stop running it.
  for (final entity in source.listSync()) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.last;
    if (name == 'bundle.json') continue;
    Link('${target.path}/$name').createSync(entity.absolute.path);
  }

  await File('${target.path}/bundle.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));

  stdout.writeln('wrote ${target.path} at the "$tier" intrinsics tier');
  stdout.writeln('  source     ${intrinsics['source']}');
  stdout.writeln('  distortion ${intrinsics['distortion'] ?? 'none'}');
}
