import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Fitting a rotation to correspondences, and averaging rotations.
///
/// Two metrics need this and neither can be computed without it. S2 has to ask
/// what relative rotation a stitcher *would infer* from a pair of overlapping
/// frames given the intrinsics it believes in — that is a fit, not a lookup.
/// Residual tilt has to reduce a whole set of per-frame misalignments to one
/// number, which is an average.
///
/// Horn's quaternion method rather than Kabsch-by-SVD: the eigenproblem is
/// 4×4 and symmetric, so a dozen Jacobi sweeps solve it exactly, whereas an SVD
/// would mean hand-rolling one and getting the sign of the reflection case
/// right. Horn's method cannot return a reflection at all, which for a rotation
/// fit is the property you actually want.
class RotationFit {
  const RotationFit._();

  /// The rotation `R` minimising `Σ‖R·b_k − a_k‖²` over unit vectors.
  ///
  /// Returns `null` when there are fewer than three correspondences or they are
  /// degenerate, because a rotation is not determined by less than that and
  /// returning an arbitrary one would quietly corrupt whatever metric asked.
  static Quaternion? fit(List<Vector3> a, List<Vector3> b) {
    if (a.length != b.length) {
      throw ArgumentError('correspondence lists must be the same length');
    }
    if (a.length < 3) return null;

    // S[i][j] = Σ a_k[i] · b_k[j]
    final s = List.generate(3, (_) => List<double>.filled(3, 0));
    for (var k = 0; k < a.length; k++) {
      final av = [a[k].x, a[k].y, a[k].z];
      final bv = [b[k].x, b[k].y, b[k].z];
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          s[i][j] += av[i] * bv[j];
        }
      }
    }

    final trace = s[0][0] + s[1][1] + s[2][2];
    final n = [
      [trace, s[1][2] - s[2][1], s[2][0] - s[0][2], s[0][1] - s[1][0]],
      [
        s[1][2] - s[2][1],
        s[0][0] - s[1][1] - s[2][2],
        s[0][1] + s[1][0],
        s[2][0] + s[0][2],
      ],
      [
        s[2][0] - s[0][2],
        s[0][1] + s[1][0],
        -s[0][0] + s[1][1] - s[2][2],
        s[1][2] + s[2][1],
      ],
      [
        s[0][1] - s[1][0],
        s[2][0] + s[0][2],
        s[1][2] + s[2][1],
        -s[0][0] - s[1][1] + s[2][2],
      ],
    ];

    final eigen = _jacobiEigen(n);
    if (eigen == null) return null;
    var best = 0;
    for (var i = 1; i < 4; i++) {
      if (eigen.values[i] > eigen.values[best]) best = i;
    }
    final v = [
      eigen.vectors[0][best],
      eigen.vectors[1][best],
      eigen.vectors[2][best],
      eigen.vectors[3][best],
    ];
    // Horn's eigenvector is (w, x, y, z); vector_math's constructor is
    // (x, y, z, w).
    final q = Quaternion(v[1], v[2], v[3], v[0]);
    if (q.length < 1e-9) return null;
    return q..normalize();
  }

  /// The average of [rotations], by sign-aligned quaternion summation.
  ///
  /// Exact only in the limit of small dispersion, which is the regime residual
  /// tilt lives in — if the per-frame misalignments were spread far enough for
  /// the approximation to matter, the tilt number would already be so far past
  /// its 0.2° target that its third decimal place is not the problem.
  static Quaternion? average(List<Quaternion> rotations) {
    if (rotations.isEmpty) return null;
    final reference = rotations.first;
    var x = 0.0, y = 0.0, z = 0.0, w = 0.0;
    for (final q in rotations) {
      final dot =
          q.x * reference.x +
          q.y * reference.y +
          q.z * reference.z +
          q.w * reference.w;
      final sign = dot < 0 ? -1.0 : 1.0;
      x += q.x * sign;
      y += q.y * sign;
      z += q.z * sign;
      w += q.w * sign;
    }
    final q = Quaternion(x, y, z, w);
    if (q.length < 1e-12) return null;
    return q..normalize();
  }

  /// Rotation angle of [q], in radians, in `[0, π]`.
  static double angleOf(Quaternion q) {
    final w = q.w.abs().clamp(0.0, 1.0);
    return 2 * math.acos(w);
  }

  /// Jacobi eigen decomposition of a symmetric 4×4.
  static ({List<double> values, List<List<double>> vectors})? _jacobiEigen(
    List<List<double>> input,
  ) {
    final a = [for (final row in input) [...row]];
    final v = List.generate(4, (i) => List<double>.generate(4, (j) => i == j ? 1.0 : 0.0));

    for (var sweep = 0; sweep < 64; sweep++) {
      var off = 0.0;
      for (var p = 0; p < 4; p++) {
        for (var q = p + 1; q < 4; q++) {
          off += a[p][q] * a[p][q];
        }
      }
      if (off < 1e-24) break;

      for (var p = 0; p < 4; p++) {
        for (var q = p + 1; q < 4; q++) {
          if (a[p][q].abs() < 1e-30) continue;
          final theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
          final t =
              (theta >= 0 ? 1.0 : -1.0) /
              (theta.abs() + math.sqrt(theta * theta + 1));
          final c = 1 / math.sqrt(t * t + 1);
          final s = t * c;
          for (var k = 0; k < 4; k++) {
            final akp = a[k][p], akq = a[k][q];
            a[k][p] = c * akp - s * akq;
            a[k][q] = s * akp + c * akq;
          }
          for (var k = 0; k < 4; k++) {
            final apk = a[p][k], aqk = a[q][k];
            a[p][k] = c * apk - s * aqk;
            a[q][k] = s * apk + c * aqk;
          }
          for (var k = 0; k < 4; k++) {
            final vkp = v[k][p], vkq = v[k][q];
            v[k][p] = c * vkp - s * vkq;
            v[k][q] = s * vkp + c * vkq;
          }
        }
      }
    }
    return (values: [a[0][0], a[1][1], a[2][2], a[3][3]], vectors: v);
  }
}
