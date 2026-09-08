import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../api/models/camera_intrinsics.dart';
import '../api/models/json_codec.dart';
import '../utils/spherical_conventions.dart';

/// One direction the user is asked to point the camera at.
///
/// Targets carry their ring membership as well as their angles because the
/// capture UI has to speak in rings ("now tilt up to the upper row") while the
/// geometry only cares about (yaw, pitch), and because consecutive rings are
/// staggered by half a yaw step (Math §8) — a fact that is invisible from the
/// angles alone but matters when reasoning about why a seam moved.
class CaptureTarget {
  /// Creates a target at [yaw]/[pitch] in the world frame.
  const CaptureTarget({
    required this.index,
    required this.ringIndex,
    required this.indexInRing,
    required this.yaw,
    required this.pitch,
    required this.ringLabel,
  });

  /// Position in the plan's overall shooting order.
  final int index;

  /// Which ring this target belongs to; the poles are rings of one.
  final int ringIndex;

  /// Position within [ringIndex], counting in shooting order.
  final int indexInRing;

  /// Target heading in radians, world frame, relative to session start
  /// (Math §3).
  final double yaw;

  /// Target elevation in radians, world frame; `+π/2` is the zenith.
  final double pitch;

  /// Human-readable ring name shown in the capture UI, e.g. `middle row`.
  final String ringLabel;

  /// Unit world-space direction to aim at.
  Vector3 get direction => SphericalConventions.directionOf(yaw, pitch);

  /// The device→world rotation this target asks the user to reach, including
  /// the roll about the optical axis (Math §8's "second polar frame rolled
  /// 90°").
  Matrix3 get orientation =>
      SphericalConventions.aimingDeviceToWorld(yaw, pitch);

  /// World-space direction the top of the screen points in when this target is
  /// reached — the second column of [orientation].
  ///
  /// Guidance needs it because [direction] alone does not distinguish the two
  /// polar frames: they aim at the same point and differ only in roll.
  Vector3 get screenUp => orientation.getColumn(1);

  /// Whether this is a polar target, where **yaw is not a heading**.
  ///
  /// At `|pitch| = π/2` every yaw names the same direction, so [yaw] carries
  /// the roll about the optical axis instead — which is what makes the second
  /// polar frame a different view rather than a duplicate. Phase 08 §7 pitfall
  /// 3 is the consequence: aim error here must be the angular distance between
  /// directions, never a yaw comparison, because the yaw component of the error
  /// is degenerate.
  bool get isPole => pitch.abs() >= math.pi / 2 - 1e-9;

  /// Serialises to `bundle.json` and to the native ABI.
  Map<String, Object?> toJson() => {
    'index': index,
    'ring_index': ringIndex,
    'index_in_ring': indexInRing,
    'yaw': yaw,
    'pitch': pitch,
    'ring_label': ringLabel,
  };

  /// Inverse of [toJson].
  factory CaptureTarget.fromJson(Map<String, Object?> json) {
    const ctx = 'CaptureTarget';
    return CaptureTarget(
      index: jsonInt(json, 'index', context: ctx),
      ringIndex: jsonInt(json, 'ring_index', context: ctx),
      indexInRing: jsonInt(json, 'index_in_ring', context: ctx),
      yaw: jsonDouble(json, 'yaw', context: ctx),
      pitch: jsonDouble(json, 'pitch', context: ctx),
      ringLabel: jsonString(json, 'ring_label', context: ctx),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CaptureTarget &&
      other.index == index &&
      other.ringIndex == ringIndex &&
      other.indexInRing == indexInRing &&
      other.yaw == yaw &&
      other.pitch == pitch &&
      other.ringLabel == ringLabel;

  @override
  int get hashCode =>
      Object.hash(index, ringIndex, indexInRing, yaw, pitch, ringLabel);

  @override
  String toString() =>
      'CaptureTarget(#$index, $ringLabel[$indexInRing], '
      'yaw: $yaw, pitch: $pitch)';
}

/// Proof — or disproof — that a plan actually covers the sphere.
///
/// Exists because criterion S5 is a number, not a hope. The previous plan was
/// hard-coded to 8 shots per ring at an assumed 52° HFOV, which is ~15%
/// overlap: below the ~30% feature matching needs, so the frames themselves
/// were unrecoverable by any better algorithm. Rather than trust the arithmetic
/// of Math §8, `coverage_validator` rasterises the sphere on a ~1° lattice and
/// counts frusta per cell. A plan that fails this is rejected **before the
/// camera opens**, which is the only time rejecting it is cheap.
class CoverageReport {
  /// Creates a coverage report.
  const CoverageReport({
    required this.fractionCoveredAtLeastOnce,
    required this.fractionCoveredAtLeastTwice,
    required this.gaps,
    this.minimumPairwiseOverlap = 0,
    this.recordedGapCount,
    this.latticePointCount = 0,
  });

  /// Tolerance on the "100%" in S5, so floating-point rasterisation of a
  /// genuinely complete sphere is not rejected on the last bit.
  static const double coverageTolerance = 1e-9;

  /// Fraction of sphere directions seen by at least one frame. S5 wants `1.0`.
  final double fractionCoveredAtLeastOnce;

  /// Fraction seen by at least two frames — **S5c, a sanity floor, not a
  /// target**.
  ///
  /// This was `≥ 0.95` and that was wrong. In one dimension frames of width `w`
  /// at spacing `w(1−ω)` overlap over `wω` of every step, so the double-covered
  /// fraction is exactly `ω/(1−ω)`; asking for 0.95 is algebraically asking for
  /// `ω = 0.487`, while the documented default overlap is 0.33. The two could
  /// never both hold.
  ///
  /// What the pipeline actually needs is [minimumPairwiseOverlap] — matching
  /// works on pairs, and the seam finder and blender work *inside* the overlap
  /// band, whose width at `ω = 0.33` is ~280 px on a 6144-wide canvas against a
  /// 5-band blend's ~32 px. So this number is reported for diagnosis and floored
  /// at 0.70 only to catch a degenerate plan. See Math §8.
  final double fractionCoveredAtLeastTwice;

  /// Smallest overlap, as a fraction of frame area, between any two *adjacent*
  /// planned frames — **S5b, and the criterion that actually matters**.
  ///
  /// Feature matching is pairwise: what it needs is that neighbouring frames
  /// share enough image to match on, which is a property of each pair rather
  /// than of the sphere as a whole. 0.25 is the floor; production stitchers work
  /// at 0.20–0.30.
  final double minimumPairwiseOverlap;

  /// Lattice points that no frame covers, so the UI can point at them instead
  /// of saying "coverage failed".
  ///
  /// **A bounded sample, not necessarily all of them** — see [gapCount] for the
  /// true total. The validator rasterises 40 000 points, and a plan that
  /// deliberately skips the nadir leaves ~6% of them uncovered by design; at
  /// one JSON object each that is ~150 KB of manifest per station, repeated at
  /// every station of a site walk, describing a hole the plan already declared.
  /// The sample is spread across the whole gap list rather than truncated from
  /// the front, so it still says *where* the holes are.
  final List<({double yaw, double pitch})> gaps;

  /// How many lattice points were uncovered in total.
  ///
  /// `null` in hand-constructed reports and in manifests written before the
  /// field existed, in which case [gapCount] falls back to `gaps.length` — the
  /// old meaning, which was exact because the list was not yet bounded.
  final int? recordedGapCount;

  /// How many points the sphere was rasterised on, so a fraction can be read
  /// back as a count. `0` when not recorded.
  final int latticePointCount;

  /// Number of uncovered lattice points, whether or not they all appear in
  /// [gaps].
  int get gapCount => recordedGapCount ?? gaps.length;

  /// S5c's floor. A sanity check against degenerate plans, not a target.
  static const double minimumDoubleCoverage = 0.70;

  /// S5b's floor — the overlap feature matching needs between adjacent frames.
  static const double minimumAdjacentOverlap = 0.25;

  /// Whether this plan satisfies S5a, S5b and S5c.
  bool get isAcceptable =>
      fractionCoveredAtLeastOnce >= 1.0 - coverageTolerance &&
      minimumPairwiseOverlap >= minimumAdjacentOverlap &&
      fractionCoveredAtLeastTwice >= minimumDoubleCoverage;

  /// Serialises to `bundle.json` and to the native ABI.
  Map<String, Object?> toJson() => {
    'fraction_covered_at_least_once': fractionCoveredAtLeastOnce,
    'fraction_covered_at_least_twice': fractionCoveredAtLeastTwice,
    'minimum_pairwise_overlap': minimumPairwiseOverlap,
    'gap_count': gapCount,
    'lattice_point_count': latticePointCount,
    'gaps': [
      for (final gap in gaps) {'yaw': gap.yaw, 'pitch': gap.pitch},
    ],
  };

  /// Inverse of [toJson].
  factory CoverageReport.fromJson(Map<String, Object?> json) {
    const ctx = 'CoverageReport';
    return CoverageReport(
      fractionCoveredAtLeastOnce: jsonDouble(
        json,
        'fraction_covered_at_least_once',
        context: ctx,
      ),
      fractionCoveredAtLeastTwice: jsonDouble(
        json,
        'fraction_covered_at_least_twice',
        context: ctx,
      ),
      // Defaulted rather than required: bundles written before S5b existed are
      // still loadable, which is what makes the replay corpus permanent.
      minimumPairwiseOverlap: json.containsKey('minimum_pairwise_overlap')
          ? jsonDouble(json, 'minimum_pairwise_overlap', context: ctx)
          : 0.0,
      recordedGapCount: jsonIntOrNull(json, 'gap_count', context: ctx),
      latticePointCount: json.containsKey('lattice_point_count')
          ? jsonInt(json, 'lattice_point_count', context: ctx)
          : 0,
      gaps: jsonList(json, 'gaps', (e) {
        if (e is! Map) {
          throw const SphereJsonFormatException(
            'CoverageReport.gaps',
            'expected a list of {yaw, pitch} objects',
          );
        }
        final gap = e.cast<String, Object?>();
        return (
          yaw: jsonDouble(gap, 'yaw', context: '$ctx.gaps'),
          pitch: jsonDouble(gap, 'pitch', context: '$ctx.gaps'),
        );
      }, context: ctx),
    );
  }

  // S5b is part of the identity of a report. It was omitted here when the field
  // was added, which made two reports differing only in the criterion that
  // "actually matters" compare equal — and equality is what the round-trip test
  // asserts on, so the omission also meant nothing was checking that S5b
  // survived a trip through `bundle.json`.
  @override
  bool operator ==(Object other) =>
      other is CoverageReport &&
      other.fractionCoveredAtLeastOnce == fractionCoveredAtLeastOnce &&
      other.fractionCoveredAtLeastTwice == fractionCoveredAtLeastTwice &&
      other.minimumPairwiseOverlap == minimumPairwiseOverlap &&
      other.gapCount == gapCount &&
      other.latticePointCount == latticePointCount &&
      listEquals(other.gaps, gaps);

  @override
  int get hashCode => Object.hash(
    fractionCoveredAtLeastOnce,
    fractionCoveredAtLeastTwice,
    minimumPairwiseOverlap,
    gapCount,
    latticePointCount,
    listHash(gaps),
  );

  @override
  String toString() =>
      'CoverageReport(1×: ${(fractionCoveredAtLeastOnce * 100).toStringAsFixed(1)}%, '
      '2×: ${(fractionCoveredAtLeastTwice * 100).toStringAsFixed(1)}%, '
      'pairwise: ${(minimumPairwiseOverlap * 100).toStringAsFixed(1)}%, '
      '$gapCount gaps)';
}

/// The ordered list of directions to shoot, together with the intrinsics it was
/// derived from and the proof that it is sufficient.
///
/// [intrinsics] is a field rather than a parameter because a plan is **only
/// valid for one camera at one orientation**: the yaw step is `h·(1−ω)/cos φ`
/// and the ring spacing is `v·(1−ω)` (Math §8), so changing the FOV — or
/// rotating the device out of the portrait lock — silently invalidates every
/// target. Storing them together makes that impossible to forget, and lets the
/// replay tool re-derive the plan from a bundle years later.
class CapturePlan {
  /// Creates a plan. Callers should prefer `plan_builder.dart`, which computes
  /// the geometry and runs the coverage validator.
  const CapturePlan({
    required this.targets,
    required this.intrinsics,
    required this.overlapFraction,
    required this.coverage,
  });

  /// Targets in shooting order.
  final List<CaptureTarget> targets;

  /// The intrinsics this plan was computed for. Shooting with anything else
  /// invalidates it.
  final CameraIntrinsics intrinsics;

  /// Fraction `ω` of each frame that overlaps its neighbour. Default 0.33 —
  /// feature matching needs roughly 30% to be reliable.
  final double overlapFraction;

  /// The S5 proof for this plan; a plan whose coverage is not
  /// [CoverageReport.isAcceptable] must be rejected.
  final CoverageReport coverage;

  /// Number of targets, i.e. shutter positions — not frames, since a bracket
  /// fires several exposures per position.
  int get length => targets.length;

  /// Distinct ring indices present, ascending.
  List<int> get ringIndices =>
      targets.map((t) => t.ringIndex).toSet().toList()..sort();

  /// The targets belonging to [ringIndex], in shooting order.
  List<CaptureTarget> targetsInRing(int ringIndex) =>
      targets.where((t) => t.ringIndex == ringIndex).toList(growable: false);

  /// Serialises to `bundle.json` and to the native ABI.
  Map<String, Object?> toJson() => {
    'targets': [for (final t in targets) t.toJson()],
    'intrinsics': intrinsics.toJson(),
    'overlap_fraction': overlapFraction,
    'coverage': coverage.toJson(),
  };

  /// Inverse of [toJson].
  factory CapturePlan.fromJson(Map<String, Object?> json) {
    const ctx = 'CapturePlan';
    return CapturePlan(
      targets: jsonList(json, 'targets', (e) {
        if (e is! Map) {
          throw const SphereJsonFormatException(
            'CapturePlan.targets',
            'expected a list of objects',
          );
        }
        return CaptureTarget.fromJson(e.cast<String, Object?>());
      }, context: ctx),
      intrinsics: CameraIntrinsics.fromJson(
        jsonObject(json, 'intrinsics', context: ctx),
      ),
      overlapFraction: jsonDouble(json, 'overlap_fraction', context: ctx),
      coverage: CoverageReport.fromJson(
        jsonObject(json, 'coverage', context: ctx),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CapturePlan &&
      other.intrinsics == intrinsics &&
      other.overlapFraction == overlapFraction &&
      other.coverage == coverage &&
      listEquals(other.targets, targets);

  @override
  int get hashCode =>
      Object.hash(listHash(targets), intrinsics, overlapFraction, coverage);

  @override
  String toString() =>
      'CapturePlan(${targets.length} targets, '
      '${ringIndices.length} rings, overlap: $overlapFraction, $coverage)';
}
