import 'dart:math' as math;

import '../api/models/camera_intrinsics.dart';
import '../utils/math_utils.dart';
import 'capture_plan.dart';
import 'coverage_validator.dart';

/// Thrown when a plan cannot cover the sphere, so the caller finds out before
/// the camera opens rather than after the site visit.
///
/// Carries a sentence somebody standing on a site can act on, not just the
/// numbers: a refusal that says "coverage failed" sends a manager back to the
/// office, while one that names the criterion and the lever tells them to raise
/// the overlap or use a different tablet.
class InsufficientCoverageException implements Exception {
  /// Creates the exception around the report that failed.
  const InsufficientCoverageException(
    this.coverage, {
    this.intrinsics,
    this.overlapFraction,
    this.positions,
  });

  /// The measured coverage that was rejected.
  final CoverageReport coverage;

  /// The intrinsics the rejected plan was built for, when known.
  final CameraIntrinsics? intrinsics;

  /// The overlap `ω` the rejected plan was built at, when known.
  final double? overlapFraction;

  /// How many positions the rejected plan contained, when known.
  final int? positions;

  /// Which of S5a/S5b/S5c failed, one line each.
  List<String> get failedCriteria => [
    if (coverage.fractionCoveredAtLeastOnce < 1 - CoverageReport.coverageTolerance)
      'S5a: ${_percent(coverage.fractionCoveredAtLeastOnce)} of the sphere is '
          'covered at least once, and it has to be 100% — '
          '${coverage.gapCount} of ${coverage.latticePointCount} sampled '
          'directions are seen by no frame at all',
    if (coverage.minimumPairwiseOverlap < CoverageReport.minimumAdjacentOverlap)
      'S5b: the weakest neighbouring pair shares only '
          '${_percent(coverage.minimumPairwiseOverlap)} of a frame, against the '
          '${_percent(CoverageReport.minimumAdjacentOverlap)} feature matching '
          'needs',
    if (coverage.fractionCoveredAtLeastTwice < CoverageReport.minimumDoubleCoverage)
      'S5c: only ${_percent(coverage.fractionCoveredAtLeastTwice)} of the '
          'sphere is covered twice, against a '
          '${_percent(CoverageReport.minimumDoubleCoverage)} floor',
  ];

  /// The message to show the user.
  String get message {
    final buffer = StringBuffer(
      'This capture would not cover the whole sphere, so it has been refused '
      'before the camera opened rather than after 90 seconds of your time.',
    );
    for (final line in failedCriteria) {
      buffer.write('\n  • $line');
    }
    if (intrinsics != null) {
      buffer.write(
        '\n  The plan was computed for a measured field of view of '
        '${intrinsics!.hfovDegrees.toStringAsFixed(1)}° × '
        '${intrinsics!.vfovDegrees.toStringAsFixed(1)}°',
      );
      if (positions != null) buffer.write(' over $positions positions');
      if (overlapFraction != null) {
        buffer.write(
          ' at ${_percent(overlapFraction!)} overlap. Raising the overlap adds '
          'positions and closes gaps',
        );
      }
      buffer.write('.');
    }
    return buffer.toString();
  }

  static String _percent(double value) =>
      '${(value * 100).toStringAsFixed(value >= 0.999 ? 2 : 1)}%';

  @override
  String toString() => 'InsufficientCoverageException: $message';
}

/// Derives the shot plan from the camera's **measured** field of view.
///
/// Exists because the previous planner hard-coded 8 shots per ring at an
/// assumed 52° HFOV, which on a real device is roughly 15% overlap — below the
/// ~30% feature matching needs. That is not a tuning problem: the frames
/// themselves are unrecoverable, so no better stitcher could have saved them
/// (architecture §2). The plan has to be computed from the intrinsics the probe
/// actually returned, every time, on every device.
///
/// The geometry is Math §8 and nothing here may restate it differently:
/// `Δyaw(φ) = h·(1−ω)/cos φ` then re-divided evenly so the ring closes with no
/// gap at the wrap; `Δpitch = v·(1−ω)`; rings while `|φ| + v/2 < π/2`, then two
/// zenith shots and optionally two nadir shots; consecutive rings staggered by
/// `Δyaw/2` so vertical seams do not stack.
///
/// The **order**, though, is not geometry — it is Phase 08 §1 rule 5, and it is
/// for the human holding the tablet:
///
/// 1. the equator ring first, because that is where the content a site manager
///    cares about is, so a session abandoned halfway still contains the useful
///    part;
/// 2. then up through the upper rings and the zenith, then back down through
///    the lower rings and the nadir;
/// 3. one rotation direction throughout — yaw always decreasing, i.e. the user
///    always turning to their right;
/// 4. each ring entered at the yaw nearest to where the previous one ended, so
///    nobody is ever asked to spin back across the room between rows.
class PlanBuilder {
  /// Creates a plan builder.
  const PlanBuilder({this.validator = const CoverageValidator()});

  /// The S5 gate. Injectable so a test can rasterise finer, or coarser when it
  /// is building hundreds of plans and only cares about the geometry.
  final CoverageValidator validator;

  /// Builds the plan for [intrinsics] and validates it against S5.
  ///
  /// [intrinsics] must be expressed in the frame the **device** is held in —
  /// portrait, the orientation the plan is locked to (Phase 09 §4) — not in the
  /// sensor's own frame. `SphereCaptureSession` reconciles the two; a caller
  /// passing raw sensor-frame intrinsics off a 90°-mounted camera would get a
  /// plan with the horizontal and vertical fields of view swapped, which is
  /// wrong in exactly the way that still produces a plausible-looking ring
  /// count.
  ///
  /// Throws [InsufficientCoverageException] if the resulting coverage is not
  /// acceptable — a plan that cannot cover the sphere is rejected **before the
  /// camera opens**, which is the only point at which rejecting it costs the
  /// user nothing.
  ///
  /// Two deliberate wrinkles in that rule:
  ///
  /// - When [captureNadir] is false the plan is *not* trying to cover the
  ///   nadir: it is the user's own feet, and architecture §8 says the pole is
  ///   push–pull filled instead. So the acceptance test excludes the nadir cap
  ///   the plan has declared it is skipping — but the [CapturePlan.coverage]
  ///   report stored in the bundle stays the honest whole-sphere number, gaps
  ///   and all, because the pole-fill stage downstream needs to know and
  ///   because "never silently degrade" means the shortfall has to stay
  ///   visible.
  /// - [enforceCoverage] can turn the gate off. The only legitimate caller is
  ///   the Phase 02 harness, which has to be able to construct a knowingly-bad
  ///   plan — the `sparse_plan` profile is today's 15%-overlap plan, and the
  ///   harness exists to show what it does to the output. Production code
  ///   leaves this alone.
  CapturePlan buildPlan({
    required CameraIntrinsics intrinsics,
    double overlapFraction = 0.33,
    bool captureNadir = false,
    bool enforceCoverage = true,
  }) {
    if (overlapFraction < 0 || overlapFraction >= 1) {
      throw ArgumentError.value(
        overlapFraction,
        'overlapFraction',
        'must be in [0, 1)',
      );
    }

    final h = intrinsics.hfovRadians;
    final v = intrinsics.vfovRadians;
    if (h <= 0 || v <= 0 || !h.isFinite || !v.isFinite) {
      throw ArgumentError.value(
        intrinsics,
        'intrinsics',
        'field of view must be positive and finite; got '
            '${intrinsics.hfovDegrees}° × ${intrinsics.vfovDegrees}°',
      );
    }

    final deltaPitch = v * (1 - overlapFraction);
    final baseYawStep = h * (1 - overlapFraction);

    // Ring levels above the equator: 0, 1, 2, … while |φ| + v/2 < π/2. The
    // southern rings mirror them, so only the count is needed.
    var topLevel = 0;
    while ((topLevel + 1) * deltaPitch + v / 2 < math.pi / 2) {
      topLevel++;
    }
    final outermost = topLevel * deltaPitch;

    // Math §8: "a single polar shot covers all yaw near the pole, down to a cap
    // of angular radius min(h,v)/2, so the outermost ring must reach within
    // that of the pole." The loop above does not guarantee it — at ω = 0.5 the
    // last ring it admits reaches 63.7° while the polar cap starts at 65°,
    // leaving a 1.3° annulus covered by nothing at all.
    //
    // The fix is a ring pushed as high as it will go, but *only when the
    // rasteriser says one is needed*, which is decided further down. The
    // `min(h,v)/2` cap is the frame's **inscribed** circle, and a frame's
    // corners reach half as far again; taking the conservative figure at face
    // value adds two whole rings — fourteen shutter presses against S7's 90 s
    // budget — for a gap that on most intrinsics does not exist. Math §8 is
    // explicit that "`coverage_validator` is the gate, not this arithmetic",
    // so here the arithmetic proposes and the lattice disposes.
    final reachPitch = math.pi / 2 - v / 2;
    final mightHavePolarGap =
        outermost + v / 2 < math.pi / 2 - math.min(h, v) / 2;

    List<CaptureTarget> layOut({required bool widened}) {
      final maxLevel = widened ? topLevel + 1 : topLevel;
      double pitchOf(int level) => widened && level.abs() == maxLevel
          ? (level > 0 ? reachPitch : -reachPitch)
          : level * deltaPitch;

      final targets = <CaptureTarget>[];
      var ringIndex = 0;
      // The heading the previous ring ended on, so the next one can start near
      // it. Poles do not update it: at |pitch| = π/2 yaw is a roll, not a
      // heading, and treating it as one would send the user off in an arbitrary
      // direction on the way back down.
      double? lastYaw;

      /// Two shots at each pole, not one.
      ///
      /// Math §8 said "a *single* zenith shot", and the rasteriser disproved it:
      /// the caps above ±70° are ~6% of the sphere's area and a lone polar frame
      /// covers them exactly once, which pins 2× coverage at ~90% no matter how
      /// tight the rings get. Rotating a second frame 90° about the optical axis
      /// costs one shutter per pole, makes their intersection a double-covered
      /// cap of radius min(h,v)/2, and gives the matcher a genuinely different
      /// view rather than a duplicate.
      void addPole(double pitch, String label) {
        for (var i = 0; i < 2; i++) {
          targets.add(
            CaptureTarget(
              index: targets.length,
              ringIndex: ringIndex,
              indexInRing: i,
              // At a pole every yaw is the same direction, so this is the roll
              // about the optical axis — see `CaptureTarget.isPole`.
              yaw: -i * math.pi / 2,
              pitch: pitch,
              ringLabel: label,
            ),
          );
        }
        ringIndex++;
      }

      void addRing(int level) {
        final pitch = pitchOf(level);
        // A frame at pitch φ spans more yaw than at the equator by 1/cos φ.
        final wanted = baseYawStep / math.cos(pitch);
        final count = math.max(2, (2 * math.pi / wanted).ceil());
        final step = 2 * math.pi / count;
        final stagger = _stagger(level, step);
        final label = _ringLabel(level, maxLevel);

        // Enter the ring at whichever of its fixed yaw positions is nearest to
        // where the last ring ended. This changes the shooting order, never the
        // yaw values, so it cannot move a seam or affect coverage — it only
        // saves the user from walking their eyes back across the room. Through
        // `wrapPi`, per §7 pitfall 2: an unwrapped comparison picks the wrong
        // start exactly at the ±180° meridian.
        var start = 0;
        if (lastYaw != null) {
          var best = double.infinity;
          for (var i = 0; i < count; i++) {
            final distance = MathUtils.wrapPi(
              MathUtils.wrapPi(-(i * step + stagger)) - lastYaw!,
            ).abs();
            if (distance < best) {
              best = distance;
              start = i;
            }
          }
        }

        for (var j = 0; j < count; j++) {
          // Yaw *decreases* along every ring, so the user always turns to their
          // right — one direction for the whole session (rule 3). Right is also
          // the direction content moves right in the equirect (Math §3).
          final yaw = MathUtils.wrapPi(-(((start + j) % count) * step + stagger));
          targets.add(
            CaptureTarget(
              index: targets.length,
              ringIndex: ringIndex,
              indexInRing: j,
              yaw: yaw,
              pitch: pitch,
              ringLabel: label,
            ),
          );
          lastYaw = yaw;
        }
        ringIndex++;
      }

      // Rule 5, the order that is for the human rather than for the maths.
      addRing(0);
      for (var level = 1; level <= maxLevel; level++) {
        addRing(level);
      }
      addPole(math.pi / 2, 'zenith');
      for (var level = 1; level <= maxLevel; level++) {
        addRing(-level);
      }
      if (captureNadir) addPole(-math.pi / 2, 'nadir');
      return targets;
    }

    CoverageReport measure(List<CaptureTarget> targets) => validator.validate(
      CapturePlan(
        targets: targets,
        intrinsics: intrinsics,
        overlapFraction: overlapFraction,
        // A provisional report: `validate` reads only the targets.
        coverage: const CoverageReport(
          fractionCoveredAtLeastOnce: 0,
          fractionCoveredAtLeastTwice: 0,
          gaps: [],
        ),
      ),
      intrinsics,
    );

    var targets = layOut(widened: false);
    var coverage = measure(targets);

    // The arithmetic proposed a polar gap; ask the lattice whether there really
    // is one before paying for two more rings.
    if (mightHavePolarGap && !_isAcceptable(coverage, captureNadir, v)) {
      final candidate = layOut(widened: true);
      final measured = measure(candidate);
      // Accept whenever the extra rings close holes — judged on S5a alone, not
      // on the composite.
      //
      // Gating this on full acceptability meant the widened plan was discarded
      // whenever double coverage *also* fell short, which is exactly when the
      // holes are worst. At h=56° v=74° ω=0.25 that returned an 11-shot plan
      // covering 70.5% of the sphere while a 13-shot plan covering 81.7% sat
      // measured and thrown away — and, worse, the rejection message then quoted
      // the discarded plan's coverage, pointing the reader at the wrong number.
      // These two rings exist to close holes; let them.
      if (measured.fractionCoveredAtLeastOnce >
          coverage.fractionCoveredAtLeastOnce +
              CoverageReport.coverageTolerance) {
        targets = candidate;
        coverage = measured;
      }
    }

    if (enforceCoverage && !_isAcceptable(coverage, captureNadir, v)) {
      throw InsufficientCoverageException(
        coverage,
        intrinsics: intrinsics,
        overlapFraction: overlapFraction,
        positions: targets.length,
      );
    }

    return CapturePlan(
      targets: targets,
      intrinsics: intrinsics,
      overlapFraction: overlapFraction,
      coverage: coverage,
    );
  }

  /// Yaw offset of ring [level], as an angle.
  ///
  /// Math §8 asks for half a step between consecutive rings, because a stack of
  /// coincident vertical seams is far more visible than staggered ones and it
  /// costs nothing to avoid. Half a step is the first term here. The other two
  /// are not in the document, and they are here because the half step **alone
  /// does not achieve what it is for**:
  ///
  /// - Rings `+k` and `−k` have the same `|φ|`, so the same shot count and the
  ///   same step. Any offset built from step parity therefore gives them
  ///   *identical yaw sets*, and their seams share a column of the equirect —
  ///   interrupted by the middle row, but still a column. A further quarter
  ///   step on the southern rings separates them by an amount that is not a
  ///   multiple of the step, which is the only way two rings of equal count can
  ///   fail to coincide.
  /// - Two rings of *different* count can still land on a shared yaw by
  ///   arithmetic accident. At h = 46° the 12-shot equator and the 10-shot ring
  ///   above it both shoot −90°: `3 × 30° = 2 × 36° + 18°`. The last term is an
  ///   **irrational** multiple of the step, which no integer combination of two
  ///   ring steps can cancel, so no two rings can coincide at all — and at ~2%
  ///   of a step it is far too small to move a seam anywhere that matters.
  ///
  /// The equator itself is never offset, so the first shot of the session is
  /// yaw 0: the heading the user is already pointing at (Math §1.1).
  static double _stagger(int level, double step) {
    if (level == 0) return 0;
    var fraction = level.isOdd ? 0.5 : 0.0;
    if (level < 0) fraction += 0.25;
    return step * (fraction + level * _irrationalOffset);
  }

  /// `(√5 − 2)/10 ≈ 0.0236` — irrational, and small enough to be invisible.
  static const double _irrationalOffset = 0.02360679774997897;

  /// S5, allowing for a nadir the plan never intended to shoot.
  ///
  /// The excluded cap is the one a single nadir frame would have covered,
  /// `min(h, v)/2` of angular radius below the pole — not an arbitrary
  /// tolerance, so a plan cannot pass by leaving a hole *larger* than the shot
  /// it skipped.
  bool _isAcceptable(CoverageReport coverage, bool captureNadir, double vfov) {
    if (captureNadir) return coverage.isAcceptable;
    final skipped = CoverageValidator.nadirCapFraction(
      90 - (vfov / 2) * 180 / math.pi,
    );
    return coverage.fractionCoveredAtLeastOnce >=
            1 - skipped - CoverageReport.coverageTolerance &&
        coverage.minimumPairwiseOverlap >=
            CoverageReport.minimumAdjacentOverlap &&
        coverage.fractionCoveredAtLeastTwice >=
            CoverageReport.minimumDoubleCoverage - skipped;
  }

  /// The name the capture UI says out loud, e.g. `middle row`.
  static String _ringLabel(int level, int maxLevel) {
    if (level == 0) return 'middle row';
    final side = level > 0 ? 'upper' : 'lower';
    // Numbered only when there is more than one row on a side, because "upper
    // row 1" reads as a bug when it is the only one.
    return maxLevel > 1 ? '$side row ${level.abs()}' : '$side row';
  }
}
