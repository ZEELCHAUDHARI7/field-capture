import 'dart:math' as math;
import 'dart:typed_data';

import '../api/models/camera_intrinsics.dart';
import '../utils/spherical_conventions.dart';
import 'capture_plan.dart';

/// Proves — by rasterisation, not arithmetic — that a plan covers the sphere.
///
/// Math §8 is explicit that this validator, not the ring arithmetic, is the
/// gate. The arithmetic tells you how many shots a ring wants; it does not tell
/// you what the polar cap actually reaches, what a frame's frustum covers once
/// it is tilted, or whether the outermost ring meets the zenith shot. Those are
/// where a plan quietly leaves a hole, and a hole found at the site is a wasted
/// site visit.
///
/// So the sphere is rasterised, each point counts how many planned frusta
/// contain it, and S5 is asserted directly:
///
/// - **S5a** 100% of directions covered at least once (minus a nadir cap the
///   plan has declared it is skipping) — holes are real defects;
/// - **S5b** every adjacent pair shares ≥25% of frame area — pairwise is what
///   feature matching actually needs;
/// - **S5c** ≥70% covered at least twice — a floor against degenerate plans,
///   reported rather than tuned to.
///
/// S5c used to read ≥95%, which was wrong: the double-covered fraction is
/// `ω/(1−ω)`, so 95% is algebraically a demand for ~49% overlap, against a
/// documented default of 33%. Math §8 has the full derivation and the measured
/// cost of the alternative.
class CoverageValidator {
  /// Creates a validator at the default lattice resolution.
  const CoverageValidator({
    this.latticePoints = defaultLatticePoints,
    this.borderErosionFraction = defaultBorderErosionFraction,
    this.maxRecordedGaps = 512,
  });

  /// ~40 000 points over the sphere: a mean nearest-neighbour spacing of about
  /// 1°, which is finer than any hole a shot plan can leave and still be worth
  /// calling a plan.
  static const int defaultLatticePoints = 40000;

  /// The erosion Phase 04 §1 applies to every warped mask, as a fraction of the
  /// frame's smaller dimension. Must stay equal to `compositing.h`'s
  /// `borderErosionFraction`; see [borderErosionFraction] for why.
  static const double defaultBorderErosionFraction = 0.015;

  /// How many points the sphere is sampled at.
  ///
  /// The lattice is a **Fibonacci (golden-angle) spiral**, not a lat/lon grid,
  /// and the difference is the whole reason this class can be believed. A
  /// lat/lon grid at 1° puts as many samples across the last degree below the
  /// zenith as across the entire equator — the poles are oversampled about
  /// 100× — so the reported percentage is dominated by the part of the plan
  /// that is *least* likely to be wrong, and a real equatorial hole can hide
  /// inside the rounding of a passing polar score. The Fibonacci lattice is
  /// equal-solid-angle by construction: every point carries the same `4π/N` of
  /// sphere, so every reported fraction is a fraction of *area*, which is what
  /// S5 means.
  final int latticePoints;

  /// Fraction of the frame's smaller dimension trimmed from every edge before a
  /// pixel counts as covered.
  ///
  /// Phase 04 §1 erodes each warped mask by this much before seam finding,
  /// because undistortion and the pinhole model both misbehave at the extreme
  /// frame edge and vignetting is worst there. Validating against the
  /// *un*-eroded rectangle would certify coverage that the compositor then
  /// throws away — a hole that no test catches, because both halves look
  /// correct alone.
  final double borderErosionFraction;

  /// Upper bound on how many gap locations are listed in the report.
  ///
  /// The count is always exact ([CoverageReport.gapCount]); this bounds only
  /// the list of *where*, which is written into every `bundle.json`. A plan
  /// that deliberately skips the nadir leaves ~6% of 40 000 points uncovered by
  /// design, and recording all 2 400 of them would add ~150 KB to every station
  /// of a site walk to describe a hole the plan already declared.
  final int maxRecordedGaps;

  /// Counts frustum coverage per lattice point and reports S5.
  ///
  /// Containment is the exact pinhole frustum test — project the point through
  /// the target's pose and ask whether it lands inside the eroded image
  /// rectangle — not the `min(h, v)/2` inscribed cap the ring arithmetic uses.
  /// That is the whole point of rasterising: a tilted frame's corners reach
  /// half as far again as its inscribed circle, and whether the outermost ring
  /// meets the polar cap depends on exactly that difference.
  ///
  /// Distortion is deliberately ignored. It moves a frame's edge by a fraction
  /// of a degree, far below the resolution any plan should be relying on, and
  /// R2 found the model is simply unavailable on much of the fleet — so a
  /// validator that needed it would be unable to run where it matters most.
  CoverageReport validate(CapturePlan plan, CameraIntrinsics intrinsics) {
    final targetCount = plan.targets.length;
    final points = _lattice(latticePoints);
    final pointCount = points.length ~/ 3;

    // Each target's world→device rotation, flattened row-major. The inner loop
    // runs `pointCount × targetCount` times — 1.2 M for a normal plan — so a
    // `Matrix3` transpose and a `Vector3` allocation per iteration would
    // dominate the cost entirely.
    final rotation = Float64List(targetCount * 9);
    for (var t = 0; t < targetCount; t++) {
      final target = plan.targets[t];
      final m = SphericalConventions.aimingDeviceToWorld(target.yaw, target.pitch);
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          // The transpose: world→device is device→world inverted, and for a
          // rotation the inverse is the transpose.
          rotation[t * 9 + i * 3 + j] = m.entry(j, i);
        }
      }
    }

    final width = intrinsics.imageSize.width;
    final height = intrinsics.imageSize.height;
    // Phase 04 §1 erodes by a fraction of the *smaller* dimension, equally on
    // every edge, so the trim is isotropic rather than skewed by aspect ratio.
    final inset = math.min(width, height) * borderErosionFraction;
    final minX = inset, maxX = width - inset;
    final minY = inset, maxY = height - inset;
    final fx = intrinsics.fx, fy = intrinsics.fy;
    final cx = intrinsics.cx, cy = intrinsics.cy;

    var covered = 0;
    var coveredTwice = 0;
    var gapCount = 0;
    final gaps = <({double yaw, double pitch})>[];
    // Stride so the recorded sample spans the whole gap list rather than being
    // truncated at the front: a truncated list would describe one pole and say
    // nothing about the other.
    var gapStride = 1;

    // Per-target hit counts, for S5b. A point seen by both frames of a pair is
    // one unit of shared solid angle; dividing by the smaller frame's own count
    // gives overlap as a fraction of frame area, which is what "25% overlap"
    // means to anyone who has shot a panorama.
    final own = Int32List(targetCount);
    final shared = Int32List(targetCount * targetCount);
    final hits = Int32List(targetCount);

    for (var p = 0; p < pointCount; p++) {
      final px = points[p * 3];
      final py = points[p * 3 + 1];
      final pz = points[p * 3 + 2];

      var hitCount = 0;
      for (var t = 0; t < targetCount; t++) {
        final r = t * 9;
        // The ray in the device frame D, where the camera looks along −Z.
        final dz = rotation[r + 6] * px + rotation[r + 7] * py + rotation[r + 8] * pz;
        final z = -dz;
        if (z <= 1e-12) continue;
        final dx = rotation[r] * px + rotation[r + 1] * py + rotation[r + 2] * pz;
        final u = fx * (dx / z) + cx;
        if (u < minX || u > maxX) continue;
        final dy = rotation[r + 3] * px + rotation[r + 4] * py + rotation[r + 5] * pz;
        final v = fy * (-dy / z) + cy;
        if (v < minY || v > maxY) continue;
        hits[hitCount++] = t;
      }

      for (var i = 0; i < hitCount; i++) {
        own[hits[i]]++;
        for (var j = i + 1; j < hitCount; j++) {
          shared[hits[i] * targetCount + hits[j]]++;
        }
      }

      if (hitCount > 0) covered++;
      if (hitCount >= 2) coveredTwice++;
      if (hitCount == 0) {
        if (gapCount % gapStride == 0) {
          gaps.add((
            yaw: math.atan2(px, pz),
            pitch: math.asin(py.clamp(-1.0, 1.0)),
          ));
          if (gaps.length > maxRecordedGaps) {
            // Halve the sample in place and double the stride, so the list stays
            // bounded and stays spread over everything seen so far.
            for (var k = 1; k * 2 < gaps.length; k++) {
              gaps[k] = gaps[k * 2];
            }
            gaps.removeRange((gaps.length + 1) ~/ 2, gaps.length);
            gapStride *= 2;
          }
        }
        gapCount++;
      }
    }

    // S5b: the weakest link among pairs that overlap *at all*. Pairs pointing
    // opposite ways share nothing and are not "adjacent" in any useful sense, so
    // including them would make the minimum trivially zero for every plan.
    var minPairwise = double.infinity;
    for (var i = 0; i < targetCount; i++) {
      var best = 0.0;
      for (var j = 0; j < targetCount; j++) {
        if (i == j) continue;
        final count = i < j
            ? shared[i * targetCount + j]
            : shared[j * targetCount + i];
        if (count == 0) continue;
        final denominator = math.min(own[i], own[j]);
        if (denominator == 0) continue;
        final fraction = count / denominator;
        if (fraction > best) best = fraction;
      }
      // A frame overlapping nothing is a hole, which S5a already reports; do not
      // also drag the pairwise minimum to zero and blame the wrong criterion.
      if (best > 0 && best < minPairwise) minPairwise = best;
    }

    return CoverageReport(
      fractionCoveredAtLeastOnce: covered / pointCount,
      fractionCoveredAtLeastTwice: coveredTwice / pointCount,
      minimumPairwiseOverlap: minPairwise.isFinite ? minPairwise : 0.0,
      gaps: List.unmodifiable(gaps),
      recordedGapCount: gapCount,
      latticePointCount: pointCount,
    );
  }

  /// [count] unit vectors spread over the sphere by the golden-angle spiral,
  /// flattened as `x, y, z` triples in the world frame (`+Y` up).
  ///
  /// Uniform in `y`, so each point owns the same `4π/N` of solid angle — the
  /// property the whole report rests on. The azimuth advances by the golden
  /// angle, which is the arrangement with no rational period, so the points
  /// never fall into rows or columns that could align with a ring of the plan
  /// and flatter it.
  static Float64List _lattice(int count) {
    final n = math.max(1, count);
    final points = Float64List(n * 3);
    // 2π/φ, φ = (1+√5)/2. Written as a constant rather than derived so the
    // lattice is bit-identical across platforms and a coverage number is
    // reproducible from a bundle years later.
    const goldenAngle = 2.399963229728653;
    for (var i = 0; i < n; i++) {
      final y = 1 - 2 * (i + 0.5) / n;
      final r = math.sqrt(math.max(0.0, 1 - y * y));
      final theta = goldenAngle * i;
      points[i * 3] = r * math.sin(theta);
      points[i * 3 + 1] = y;
      points[i * 3 + 2] = r * math.cos(theta);
    }
    return points;
  }

  /// Fraction of the sphere's area lying strictly below `−[capDegrees]` of
  /// pitch — the nadir cap a plan may deliberately skip.
  ///
  /// Lives here rather than in the plan builder because it is a property of the
  /// same equal-area sampling the report is measured on, and the two numbers are
  /// only comparable if they agree about what "fraction of the sphere" means.
  static double nadirCapFraction(double capDegrees) =>
      (1 - math.sin(capDegrees * math.pi / 180)) / 2;
}
