import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:sphere_view/src/api/models/capture_bundle.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart';

import 'harness/camera_model.dart';
import 'harness/native_stitcher.dart';
import 'harness/stitcher_backend.dart';

/// Compares the rotations the native stitcher recovered against ground truth.
///
/// The discriminating question when S1 explodes is *how* the rotations are
/// wrong. A rotation-only bundle adjustment has an exact 3-DOF gauge freedom
/// (Math §7), so the whole solution being rotated by one constant `R_g` is
/// expected and harmless — the levelling step exists to remove it. Per-frame
/// scatter is the opposite: that is a real registration failure. Printing both
/// separately is the difference between "the gauge is unpinned" and "the solver
/// diverged", which are fixed in completely different places.
Future<void> main(List<String> arguments) async {
  final directory = Directory(arguments.isEmpty ? 'build/bundles/pristine' : arguments.first);
  final bundle = await CaptureBundle.load(directory);
  final truthJson = jsonDecode(
    await File('${directory.path}/ground_truth.json').readAsString(),
  ) as Map<String, Object?>;

  final truePositions = (truthJson['positions'] as List).cast<Map<String, Object?>>();
  final trueRotations = <Matrix3>[
    for (final p in truePositions)
      _fromRowMajor(
        (p['true_device_to_world'] as List).map((v) => (v as num).toDouble()).toList(),
      ),
  ];

  final backend = NativeStitcherBackend(
    optionOverrides: {
      if (arguments.contains('--no-ba')) 'skip_bundle_adjustment': true,
    },
  );
  final outcome = await backend.stitch(
    StitchJob(bundle: bundle, canvas: EquirectCanvas.fromWidth(2048)),
  );
  final estimated = outcome.estimatedDeviceToWorld;

  stdout.writeln('frames: truth=${trueRotations.length} estimated=${estimated.length}');
  final n = math.min(trueRotations.length, estimated.length);

  // R_err(i) = R_true(i) · R_est(i)ᵀ. If the only problem is the gauge, every
  // R_err is the SAME matrix; the spread around the mean is the real error.
  final errors = <Matrix3>[];
  for (var i = 0; i < n; i++) {
    errors.add(trueRotations[i] * estimated[i].transposed());
  }

  stdout.writeln('\nper-frame |R_true · R_estᵀ| angle (deg) — raw, gauge included:');
  for (var i = 0; i < n; i++) {
    stdout.writeln('  $i: ${_angleDeg(errors[i]).toStringAsFixed(3)}');
  }

  // Remove the gauge by referencing every error to the first one.
  final reference = errors.first;
  final residuals = <double>[
    for (var i = 0; i < n; i++) _angleDeg(reference.transposed() * errors[i]),
  ];
  residuals.sort();
  stdout.writeln('\nafter removing a single global rotation (the gauge):');
  stdout.writeln('  median ${residuals[n ~/ 2].toStringAsFixed(4)} deg');
  stdout.writeln('  max    ${residuals.last.toStringAsFixed(4)} deg');
}

Matrix3 _fromRowMajor(List<double> v) {
  final m = Matrix3.zero();
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
      m.setEntry(i, j, v[i * 3 + j]);
    }
  }
  return m;
}

double _angleDeg(Matrix3 m) {
  final trace = m.entry(0, 0) + m.entry(1, 1) + m.entry(2, 2);
  return math.acos(math.max(-1, math.min(1, (trace - 1) / 2))) * 180 / math.pi;
}

// Referenced so the analyzer keeps the conventions import honest: this probe
// deliberately does NOT re-derive the frame conversion, it uses the one copy.
// ignore: unused_element
final _conventions = SphericalConventions.deviceToWorldFromOpenCvRotation;
