import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sphere_view/src/api/models/camera_intrinsics.dart';
import 'package:sphere_view/src/api/models/capture_bundle.dart';
import 'package:sphere_view/src/plan/capture_plan.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart';

import 'camera_model.dart';
import 'float_image.dart';
import 'ground_truth.dart';
import 'rotation_fit.dart';
import 'stitcher_backend.dart';

/// One measured number, its target, and whether it met it.
class Metric {
  /// Creates a metric.
  const Metric({
    required this.id,
    required this.label,
    required this.value,
    required this.formatted,
    required this.target,
    required this.pass,
    this.lowerIsBetter = true,
  });

  /// A metric that could not be computed, with the reason in [formatted].
  const Metric.unavailable({
    required this.id,
    required this.label,
    required String reason,
  }) : value = double.nan,
       formatted = reason,
       target = '',
       pass = null,
       lowerIsBetter = true;

  /// Stable key, used in the baselines JSON: `s1`, `s2`, …
  final String id;

  /// Human label for the report table.
  final String label;

  /// The measured value, for the baseline comparison. `NaN` when unavailable.
  final double value;

  /// The value as the table prints it, units included.
  final String formatted;

  /// The target as the table prints it.
  final String target;

  /// `true`, `false`, or `null` when the metric could not be computed.
  final bool? pass;

  /// Whether a regression means the number went up. Used by the quality gate.
  final bool lowerIsBetter;
}

/// The thresholds one profile is judged against.
///
/// §8 of the Phase 04 doc does not set one bar for every case, and flattening it
/// to one would be a real loss of information in both directions: `pristine` has
/// exact poses and a uniformly-exposable room, so 0.97 SSIM there would be a
/// silent failure, while holding `parallax_1m` to 0.995 would fail it for
/// obeying optics. Every profile that the table does not single out gets the
/// `nominal` column, which is the device we expect.
class MetricTargets {
  /// Creates a set of targets. The defaults are §8's `nominal` row.
  const MetricTargets({
    this.rmsReprojectionPx = 1.0,
    this.loopClosureDegrees = 0.25,
    this.seamScore = 2.0,
    this.wrapSeamScore = 1.1,
    this.gainRatio = 1.03,
    this.ssim = 0.97,
    this.psnrDb = 32.0,
    this.residualTiltDegrees = 0.2,
    this.peakRssMb = 700.0,
    this.requireFullCoverage = true,
    this.hdrWindowHeadroom = 0.90,
    this.hdrShadowContrast = 0.70,
  });

  /// S1, in pixels at registration scale.
  final double rmsReprojectionPx;

  /// S2, in degrees.
  final double loopClosureDegrees;

  /// S3's 95th-percentile seam ratio.
  final double seamScore;

  /// S3 measured at the ±180° meridian on an output rolled by W/2 (§2).
  final double wrapSeamScore;

  /// S4.
  final double gainRatio;

  /// S6's SSIM.
  final double ssim;

  /// S6's PSNR, in dB.
  final double psnrDb;

  /// Math §7's acceptance for residual tilt, in degrees.
  final double residualTiltDegrees;

  /// S9's budget, in MB.
  final double peakRssMb;

  /// Whether the sphere has to be covered everywhere. False for `partial`,
  /// which is an abandoned session by construction: its exit criterion is that
  /// the gap fill leaves no black pixels and that the reported coverage is
  /// honest, not that the coverage is complete.
  final bool requireFullCoverage;

  /// Phase 05 §7. Fraction of the blown-highlight region that must still be below
  /// the 8-bit rail, i.e. that still holds information.
  final double hdrWindowHeadroom;

  /// Phase 05 §7. Local contrast the deep-shadow region must retain, as a
  /// fraction of the contrast the ground truth has there.
  final double hdrShadowContrast;

  /// The targets for [profile].
  static MetricTargets forProfile(String profile) => switch (profile) {
    // The control. Exact poses, exact intrinsics, a lens with no distortion and
    // a room that fits in one exposure — if this is not near-perfect the
    // geometry or the conventions are wrong and no other number means anything.
    'pristine' => const MetricTargets(ssim: 0.995, psnrDb: 42.0),
    // A 6 cm entrance-pupil offset against a surface 1 m away is 3.4° of
    // parallax, which no rotation-only model can remove (architecture §3). The
    // graph cut's job is to hide it, not to fix it, so fidelity is allowed to
    // suffer while the seam score is not.
    'parallax_1m' => const MetricTargets(ssim: 0.90, psnrDb: 26.0),
    // Motion blur and a featureless room both cost sharpness everywhere rather
    // than at the seams; S1 and S6 are the metrics that say so, and S3 should
    // still hold.
    'motion_blur' => const MetricTargets(ssim: 0.92, psnrDb: 28.0),
    'low_texture' => const MetricTargets(ssim: 0.94, psnrDb: 29.0),
    'partial' => const MetricTargets(requireFullCoverage: false),
    _ => const MetricTargets(),
  };
}

/// Everything `tools/replay` prints, plus the raw values the gate compares.
class MetricsResult {
  /// Creates a result.
  const MetricsResult({
    required this.metrics,
    required this.worstSeams,
    required this.excludedFraction,
    required this.stageMilliseconds,
    required this.warnings,
    this.diagnostics = const {},
  });

  /// The eight metrics, in report order.
  final List<Metric> metrics;

  /// The ten worst seam locations, for inspection.
  final List<({int x, int y, double ratio})> worstSeams;

  /// Fraction of the sphere left out of S6 — uncovered or pole-filled. §4 of
  /// the phase doc requires this to be reported, because an SSIM computed over
  /// a shrinking region is a rising number that means nothing.
  final double excludedFraction;

  /// Per-stage wall clock, straight from the backend.
  final Map<String, int> stageMilliseconds;

  /// The stitcher's own warnings, carried through.
  final List<String> warnings;

  /// The stitcher's own diagnostics — for the native backend, the whole
  /// compositing block of `StitchReport`. Printed rather than scored, except
  /// where §8 turns one into an assertion.
  final Map<String, Object?> diagnostics;

  /// Whether every computable metric met its target.
  bool get allPass => metrics.every((m) => m.pass ?? true);

  /// The raw values, keyed by metric id, for `phases/baselines/*.json`.
  Map<String, Object?> toBaselineJson() => {
    for (final m in metrics)
      if (!m.value.isNaN) m.id: m.value,
  };
}

/// Computes the eight metrics of §2 and §4 against ground truth.
///
/// Two decisions here are worth stating up front because they make these
/// numbers stricter than the ones a stitcher reports about itself.
///
/// **S1 is measured against the truth, not against the stitcher's own
/// residual.** Bundle adjustment's residual says how self-consistent a solution
/// is; it is perfectly possible to be smoothly, confidently, self-consistently
/// wrong — a focal error does exactly that. Since the rig knows where every
/// camera really was, the harness asks the question that actually matters.
///
/// **S2 is measured the way a stitcher would have to earn it.** Composing the
/// stitcher's *absolute* rotations around a ring is vacuous — it telescopes to
/// the identity whatever the rotations are. So the harness reconstructs the
/// pairwise chain: for each neighbouring pair it takes the correspondences the
/// truth puts in their overlap, converts them to rays through the intrinsics
/// **the stitcher believes in**, fits the relative rotation those rays imply,
/// and composes all of them around the loop. A wrong focal makes every step's
/// angle wrong by the same fraction, and 360° of that is what fails to close.
class MetricsEngine {
  /// Creates an engine over one stitch.
  MetricsEngine({
    required this.bundle,
    required this.truth,
    required this.outcome,
    required this.groundTruthImage,
    required this.canvas,
    required this.peakRssBytes,
    this.targets = const MetricTargets(),
    this.evMap,
  });

  /// The thresholds this profile is judged against.
  final MetricTargets targets;

  /// The bundle that was stitched.
  final CaptureBundle bundle;

  /// The answers.
  ///
  /// Required, and that is a statement about what this class is for: every
  /// metric here is defined *against a reference*, including S3, whose ratio
  /// subtracts the gradient step the ground truth has at the same place so that a
  /// real edge in the scene is not scored as a seam. A field capture has no
  /// reference — nobody surveyed the building — so it is measured by
  /// `field_metrics.dart` with reference-free definitions under their own names,
  /// rather than by making this class pretend.
  final GroundTruth truth;

  /// What the stitcher produced.
  final StitchOutcome outcome;

  /// The ground-truth equirect, already resampled to [canvas] if needed.
  final FloatImage groundTruthImage;

  /// Output canvas geometry.
  final EquirectCanvas canvas;

  /// Peak resident set of the replay process, in bytes.
  final int peakRssBytes;

  /// Stops of scene radiance above or below what the display-referred ground
  /// truth can itself hold, per direction, resampled to [canvas]. `null` when the
  /// profile's scene fits in 8 bits, which is when the Phase 05 metrics have
  /// nothing to say.
  ///
  /// This is the only place the harness uses the EV map for scoring rather than
  /// for rendering, and it is what makes "the window region" a definition instead
  /// of a hand-drawn rectangle: the window is where the scene is 4 stops brighter
  /// than a single exposure can hold, wherever that happens to land in the
  /// panorama.
  final FloatImage? evMap;

  /// Runs every metric.
  MetricsResult compute() {
    final seam = _seamScore();
    final fidelity = _fidelity();
    return MetricsResult(
      metrics: [
        _rmsReprojection(),
        _loopClosure(),
        seam.metric,
        _wrapSeamScore(),
        _maxGainRatio(),
        _coverage(),
        _unfilledHoles(),
        fidelity.ssim,
        fidelity.psnr,
        _dynamicRange(highlight: true),
        _dynamicRange(highlight: false),
        _residualTilt(),
        _stripEquivalence(),
        _peakRss(),
      ],
      worstSeams: seam.worst,
      excludedFraction: fidelity.excludedFraction,
      stageMilliseconds: outcome.stageMilliseconds,
      warnings: [...outcome.warnings, ..._crossChecks()],
      diagnostics: outcome.diagnostics,
    );
  }

  /// Warnings the harness raises about the stitcher's own reported numbers.
  ///
  /// §6 requires the report to state how much of the sphere is real
  /// photography, and `partial`'s exit criterion is that the figure is *honest*.
  /// The stitcher's `coverage_fraction` and the harness's own S5 are computed
  /// from the same count map, so agreement is not proof of much — but
  /// disagreement is proof of something, and it is free to check.
  List<String> _crossChecks() {
    final reported = outcome.diagnostics['coverage_fraction'];
    if (reported is! num) return const [];
    var total = 0.0;
    var once = 0.0;
    for (var y = 0; y < canvas.height; y++) {
      final weight = canvas.rowSolidAngleWeight(y);
      for (var x = 0; x < canvas.width; x++) {
        total += weight;
        if (outcome.counts[y * canvas.width + x] >= 1) once += weight;
      }
    }
    final measured = total == 0 ? 0.0 : once / total;
    if ((measured - reported).abs() <= 0.005) return const [];
    return [
      'The stitcher reported ${(reported * 100).toStringAsFixed(1)}% coverage '
          'but its own coverage map says '
          '${(measured * 100).toStringAsFixed(1)}%. One of the two is wrong, and '
          'a coverage figure the report cannot stand behind is worse than none.',
    ];
  }

  /// The true camera for captured position [i].
  SyntheticCamera _trueCamera(int i) => SyntheticCamera(
    deviceToWorld: truth.positions[i].trueDeviceToWorld,
    intrinsics: truth.trueIntrinsics,
    distortion: Distorter.from(truth.trueIntrinsics.distortion),
  );

  /// The camera the stitcher believes in for captured position [i].
  SyntheticCamera _estimatedCamera(int i) => SyntheticCamera(
    deviceToWorld: outcome.estimatedDeviceToWorld[i],
    intrinsics: outcome.estimatedIntrinsics,
    distortion: Distorter.from(outcome.estimatedIntrinsics.distortion),
  );

  int get _positionCount => math.min(
    truth.positions.length,
    outcome.estimatedDeviceToWorld.length,
  );

  // ---------------------------------------------------------------- S1

  /// S1 — RMS reprojection error, in pixels of the source frame.
  ///
  /// For a grid of pixels in every frame: take the world ray that *really*
  /// produced that pixel, hand it to the camera model the stitcher settled on,
  /// and measure how far from the original pixel it lands. Registration scale
  /// here is the frame's own resolution, which is where the criterion's
  /// "1.0 px" is meaningful — a pixel of a 480×640 frame is 0.1° of arc.
  Metric _rmsReprojection() {
    if (_positionCount == 0) {
      return const Metric.unavailable(
        id: 's1',
        label: 'rms reproj',
        reason: 'no positions',
      );
    }
    final width = truth.trueIntrinsics.imageSize.width;
    final height = truth.trueIntrinsics.imageSize.height;
    var sumSquares = 0.0;
    var n = 0;

    for (var i = 0; i < _positionCount; i++) {
      final trueCamera = _trueCamera(i);
      final estimated = _estimatedCamera(i);
      for (var gy = 1; gy < 12; gy++) {
        for (var gx = 1; gx < 9; gx++) {
          final px = width * gx / 9;
          final py = height * gy / 12;
          final ray = trueCamera.rayForPixel(px, py);
          final landed = estimated.pixelForRay(ray);
          if (landed == null) continue;
          final dx = landed.x - px;
          final dy = landed.y - py;
          sumSquares += dx * dx + dy * dy;
          n++;
        }
      }
    }
    if (n == 0) {
      return const Metric.unavailable(
        id: 's1',
        label: 'rms reproj',
        reason: 'no reprojectable samples',
      );
    }
    final rms = math.sqrt(sumSquares / n);
    return Metric(
      id: 's1',
      label: 'rms reproj',
      value: rms,
      formatted: '${rms.toStringAsFixed(2)} px',
      target: '< ${targets.rmsReprojectionPx.toStringAsFixed(1)}',
      pass: rms < targets.rmsReprojectionPx,
    );
  }

  // ---------------------------------------------------------------- S2

  /// S2 — yaw error after a full 360° traverse.
  Metric _loopClosure() {
    final ring = _closedRing();
    if (ring == null) {
      return const Metric.unavailable(
        id: 's2',
        label: 'loop closure',
        reason: 'no complete ring captured',
      );
    }

    var accumulated = Quaternion.identity();
    for (var k = 0; k < ring.length; k++) {
      final i = ring[k];
      final j = ring[(k + 1) % ring.length];
      final relative = _inferredRelativeRotation(i, j);
      if (relative == null) {
        return const Metric.unavailable(
          id: 's2',
          label: 'loop closure',
          reason: 'a ring pair had too little overlap to register',
        );
      }
      accumulated = (accumulated * relative)..normalize();
    }

    final degrees = RotationFit.angleOf(accumulated) * 180 / math.pi;
    return Metric(
      id: 's2',
      label: 'loop closure',
      value: degrees,
      formatted: '${degrees.toStringAsFixed(3)} deg',
      target: '< ${targets.loopClosureDegrees.toStringAsFixed(2)}',
      pass: degrees < targets.loopClosureDegrees,
    );
  }

  /// The relative rotation a stitcher with [outcome]'s intrinsics would infer
  /// between the true frames [i] and [j] from their overlapping content.
  Quaternion? _inferredRelativeRotation(int i, int j) {
    final a = _trueCamera(i);
    final b = _trueCamera(j);
    final estimated = outcome.estimatedIntrinsics;
    final width = truth.trueIntrinsics.imageSize.width;
    final height = truth.trueIntrinsics.imageSize.height;

    final raysA = <Vector3>[];
    final raysB = <Vector3>[];
    for (var gy = 0; gy <= 16; gy++) {
      for (var gx = 0; gx <= 12; gx++) {
        final px = width * gx / 12;
        final py = height * gy / 16;
        final direction = a.rayForPixel(px, py);
        final inB = b.pixelForRay(direction);
        if (inB == null) continue;
        if (inB.x < 0 || inB.x > width || inB.y < 0 || inB.y > height) continue;
        // The same scene point, seen in both frames. A stitcher only ever sees
        // these two pixel positions; the ray it derives from each depends
        // entirely on the intrinsics it believes in.
        raysA.add(
          SphericalConventions.deviceRayForPixel(
            estimated,
            px,
            py,
          ).normalized(),
        );
        raysB.add(
          SphericalConventions.deviceRayForPixel(
            estimated,
            inB.x,
            inB.y,
          ).normalized(),
        );
      }
    }
    if (raysA.length < 6) return null;
    return RotationFit.fit(raysA, raysB);
  }

  /// Captured positions of the fully-captured ring closest to the equator, in
  /// shooting order — the loop S2 traverses.
  ///
  /// Closest to the equator because that ring is the longest and therefore the
  /// most demanding; fully captured because an abandoned session's ring is not
  /// a loop and pretending otherwise would report a flattering number for
  /// `partial`.
  List<int>? _closedRing() {
    final byTarget = <int, int>{};
    for (var i = 0; i < _positionCount; i++) {
      byTarget[bundle.positions[i].targetIndex] = i;
    }
    List<int>? best;
    var bestPitch = double.infinity;
    for (final ringIndex in bundle.plan.ringIndices) {
      final targets = bundle.plan.targetsInRing(ringIndex);
      if (targets.length < 4) continue;
      if (!targets.every((t) => byTarget.containsKey(t.index))) continue;
      final pitch = targets.first.pitch.abs();
      if (pitch < bestPitch) {
        bestPitch = pitch;
        best = [for (final t in targets) byTarget[t.index]!];
      }
    }
    return best;
  }

  // ---------------------------------------------------------------- S3

  /// S3 — seam score: the localised gradient discontinuity a seam introduces.
  ///
  /// Seam pixels are found from the label map rather than asked for, so the
  /// metric applies identically to a graph-cut that chose its seam and to a
  /// feather that never knew it drew one.
  ///
  /// §4 proposes gradient magnitude at the seam over the median gradient in a
  /// 32 px neighbourhood. Implemented literally that measures the wrong thing
  /// the moment a seam runs across a door frame or a brick course: the pixel's
  /// own gradient is large because the *scene* has an edge there, the window's
  /// median is the flat wall around it, and the ratio explodes. This is not
  /// hypothetical — it was measured. The reference stitcher on `pristine`,
  /// with exact poses, exact intrinsics and PSNR 43 dB, scored 4.7 by that
  /// definition, on a panorama containing no seam at all. The 95th-percentile
  /// step at its label boundaries is 13.7/255, and all of it is scene content.
  ///
  /// So the content is subtracted instead of averaged around. §4's own opening
  /// sentence is the specification — "seams are *localised* gradient
  /// discontinuities" — and both words do work here:
  ///
  /// - **discontinuity**, not gradient: what counts is how far the stitched
  ///   image's step across the boundary departs from the step the ground truth
  ///   has in the same place. An edge faithfully reproduced contributes
  ///   nothing; a step invented by the seam, or a real edge the blend smeared
  ///   away, both contribute.
  /// - **localised**: that departure is compared with the same departure two to
  ///   four pixels to either side, along the same axis. A stitcher that is
  ///   uniformly soft or uniformly misregistered is not showing a *seam*, and
  ///   S1 and S6 are already the metrics that say so.
  ///
  /// Using the ground truth is legitimate here and not a shortcut: S3 is a
  /// harness-only criterion, excluded from `StitchReport` precisely because it
  /// "needs a reference the device does not have".
  ///
  /// The denominator is floored at one 8-bit level, because a discrepancy below
  /// the output's own quantisation is not a visible seam by definition — that
  /// is the "local noise floor" the criterion is written against.
  ({Metric metric, List<({int x, int y, double ratio})> worst}) _seamScore() {
    final width = canvas.width;
    final height = canvas.height;
    final labels = outcome.labels;

    final ratios = <double>[];
    final located = <({int x, int y, double ratio})>[];

    for (var y = 1; y < height - 1; y++) {
      for (var x = 0; x < width; x++) {
        final here = labels[y * width + x];
        if (here < 0) continue;
        final right = labels[y * width + (x + 1) % width];
        final below = labels[(y + 1) * width + x];
        final acrossX = right >= 0 && right != here;
        final acrossY = below >= 0 && below != here;
        if (!acrossX && !acrossY) continue;

        // Step along the axis the labels change on — the direction a seam
        // would be visible in.
        final ratio = _seamRatioAt(
          outcome.equirect,
          groundTruthImage,
          x,
          y,
          acrossX ? 1 : 0,
          acrossX ? 0 : 1,
        );
        ratios.add(ratio);
        located.add((x: x, y: y, ratio: ratio));
      }
    }

    if (ratios.isEmpty) {
      return (
        metric: const Metric.unavailable(
          id: 's3',
          label: 'seam score',
          reason: 'no seams found',
        ),
        worst: const [],
      );
    }

    ratios.sort();
    final score = ratios[((ratios.length - 1) * 0.95).round()];
    located.sort((a, b) => b.ratio.compareTo(a.ratio));

    return (
      metric: Metric(
        id: 's3',
        label: 'seam score',
        value: score,
        formatted: '${score.toStringAsFixed(2)}x noise',
        target: '< ${targets.seamScore.toStringAsFixed(1)}x',
        pass: score < targets.seamScore,
      ),
      worst: located.take(10).toList(),
    );
  }

  /// One 8-bit level. A luma step below this cannot be seen in the output at
  /// all, so it is the floor the seam ratio is measured against.
  static const double _quantisationStep = 1 / 255;

  /// The darkest luma that is distinguishable from black on a display, and so
  /// the floor above which a black output pixel is a real hole rather than a
  /// rounding difference. See [_unfilledHoles].
  static const double _visibleBlackLevel = 3 / 255;

  /// Wrapping-in-x, clamping-in-y luma tap.
  double _luma(FloatImage image, int x, int y) {
    var xx = x % canvas.width;
    if (xx < 0) xx += canvas.width;
    final yy = y.clamp(0, canvas.height - 1);
    final o = image.offset(xx, yy);
    return 0.299 * image.data[o] +
        0.587 * image.data[o + 1] +
        0.114 * image.data[o + 2];
  }

  /// The S3 ratio at ([x], [y]), stepping along ([dx], [dy]).
  ///
  /// Shared by S3 and the wrap-seam test so the two are the same measurement
  /// applied to different pixels, rather than two definitions that could drift
  /// apart and make the ≤ 1.1× comparison meaningless.
  double _seamRatioAt(
    FloatImage stitched,
    FloatImage truth,
    int x,
    int y,
    int dx,
    int dy,
  ) {
    /// How far the stitched step across position [centre] departs from the step
    /// the ground truth has there.
    double discrepancy(int centre) {
      final ax = x + (centre + 1) * dx;
      final ay = y + (centre + 1) * dy;
      final bx = x + (centre - 1) * dx;
      final by = y + (centre - 1) * dy;
      final got = _luma(stitched, ax, ay) - _luma(stitched, bx, by);
      final want = _luma(truth, ax, ay) - _luma(truth, bx, by);
      return (got - want).abs();
    }

    const offsets = [-4, -3, -2, 2, 3, 4];
    final references = [for (final o in offsets) discrepancy(o)]..sort();
    final local = (references[2] + references[3]) / 2;
    return discrepancy(0) / math.max(local, _quantisationStep);
  }

  // ------------------------------------------------------- S3 at the wrap

  /// The ±180° wrap seam — §2's test, and the one defect a half-panorama
  /// measurement cannot see.
  ///
  /// The equirect's first and last columns are the same meridian in the world,
  /// but every OpenCV `detail::` component treats them as image borders: the
  /// graph cut terminates its seams there instead of continuing across, and the
  /// multi-band pyramid extrapolates the two sides independently. The result is
  /// a hard vertical line at yaw ±180°, and it is the most common defect in
  /// hand-rolled 360 stitchers.
  ///
  /// S3 proper cannot catch it. S3 walks label boundaries, and at `x = 0` the
  /// pixel to the left is the far edge of the image — a place S3's neighbour
  /// lookups reach only by wrapping, and a boundary it has no reason to visit at
  /// all if the frames either side of the meridian happen to carry the same
  /// label. So this measures the same ratio at a *fixed* column instead: the
  /// meridian, for every row, against its own neighbourhood two to four pixels
  /// away. A value near 1.0 means the meridian column is indistinguishable from
  /// the columns beside it, which is precisely what the wrap padding is for.
  ///
  /// §2 specifies rolling the output by W/2 before measuring, and this rolls.
  /// Being straight about why: with a wrapping sampler the arithmetic at
  /// column W/2 of a rolled image is identical to the arithmetic at column 0 of
  /// an unrolled one, so the roll is not what makes the number correct. What it
  /// does is put the seam somewhere a person can look at it — `rolled.png` is
  /// written next to the other artefacts — and keep the harness doing what the
  /// doc says it does rather than something equivalent-but-different.
  Metric _wrapSeamScore() {
    final rolledStitch = rollHalf(outcome.equirect);
    final rolledTruth = rollHalf(groundTruthImage);
    final meridian = canvas.width ~/ 2;
    final labels = outcome.labels;

    final ratios = <double>[];
    for (var y = 1; y < canvas.height - 1; y++) {
      // Uncovered rows have nothing to be discontinuous about, and on `partial`
      // there are plenty of them. A pole-filled pixel is excluded for the same
      // reason it is excluded from SSIM: the fill invented both sides of the
      // step, so it cannot disagree with itself.
      final left = labels[y * canvas.width + (meridian - 1 + canvas.width) % canvas.width];
      final right = labels[y * canvas.width + meridian % canvas.width];
      if (left < 0 || right < 0) continue;
      ratios.add(_seamRatioAt(rolledStitch, rolledTruth, meridian, y, 1, 0));
    }

    if (ratios.isEmpty) {
      return const Metric.unavailable(
        id: 's3_wrap',
        label: 'wrap seam',
        reason: 'the meridian is not covered',
      );
    }
    ratios.sort();
    final score = ratios[((ratios.length - 1) * 0.95).round()];
    return Metric(
      id: 's3_wrap',
      label: 'wrap seam',
      value: score,
      formatted: '${score.toStringAsFixed(2)}x noise',
      target: '< ${targets.wrapSeamScore.toStringAsFixed(2)}x',
      pass: score < targets.wrapSeamScore,
    );
  }

  // ------------------------------------------------------- unfilled holes

  /// Whether stage 14 left any black pixels — `partial`'s exit criterion.
  ///
  /// Measured against the truth rather than as "is this pixel (0,0,0)", because
  /// a construction interior does contain genuinely black pixels and counting
  /// those would make the metric fail for being accurate. A defect is a pixel
  /// the stitcher left at exactly zero where the truth has something to show.
  /// Area-weighted, so a hole at the nadir is not credited with the 4096 columns
  /// an equirect gives it.
  ///
  /// "Something to show" is three levels, not one. At a one-level floor
  /// `hdr_interior` reports 34 pixels out of 4.2 million — a scene with 14 EV
  /// from corner to sky, where the stitcher rounds a near-black pixel to 0 and
  /// the reference rounds it to 1. That is quantisation at the bottom of the
  /// range, invisible on any display, and calling it an unfilled hole would put
  /// the metric permanently 34 pixels from passing for a reason no fill could
  /// address. A real hole is black against content, which is tens of levels.
  Metric _unfilledHoles() {
    var black = 0.0;
    var total = 0.0;
    for (var y = 0; y < canvas.height; y++) {
      final weight = canvas.rowSolidAngleWeight(y);
      for (var x = 0; x < canvas.width; x++) {
        final i = (y * canvas.width + x) * 3;
        total += weight;
        final isBlack =
            outcome.equirect.data[i] == 0 &&
            outcome.equirect.data[i + 1] == 0 &&
            outcome.equirect.data[i + 2] == 0;
        if (!isBlack) continue;
        final truthLuma =
            0.299 * groundTruthImage.data[i] +
            0.587 * groundTruthImage.data[i + 1] +
            0.114 * groundTruthImage.data[i + 2];
        if (truthLuma > _visibleBlackLevel) black += weight;
      }
    }
    final fraction = total == 0 ? 1.0 : black / total;
    return Metric(
      id: 'holes',
      label: 'black pixels',
      value: fraction,
      formatted: '${(fraction * 100).toStringAsFixed(3)}%',
      target: '0%',
      pass: fraction <= 0,
    );
  }

  // ------------------------------------------------- §5 strip equivalence

  /// §5's assertion, when the run was asked to make it: that blending in padded
  /// strips gives the same answer as blending the whole canvas at once.
  ///
  /// The doc is emphatic that this is asserted and not eyeballed, because the
  /// failure mode is quiet — too small a pad produces a panorama that looks
  /// fine and is not the one a full-canvas blend would have produced. `-1` in
  /// the report means the comparison was not requested, and an unrequested
  /// assertion is reported as unavailable rather than as a pass.
  Metric _stripEquivalence() {
    final diff = outcome.diagnostics['strip_vs_full_max_abs_diff'];
    if (diff is! num || diff < 0) {
      return const Metric.unavailable(
        id: 'strip',
        label: 'strip vs full',
        reason: 'not requested (--verify-strips)',
      );
    }
    final value = diff.toDouble();
    return Metric(
      id: 'strip',
      label: 'strip vs full',
      value: value,
      formatted: '${value.toStringAsFixed(0)} levels',
      target: '<= 1',
      pass: value <= 1,
    );
  }

  /// Low-pass radius for the gain metric, in pixels of the output canvas.
  /// Comfortably wider than the misregistration a failing stitcher produces —
  /// the control group's worst is about 6 px at 2048 wide — so registration
  /// error averages out while exposure error does not.
  static const int _gainBlurRadius = 12;

  /// Separable box blur of an image's luma, wrapping in x and clamping in y.
  Float32List _blurredLuma(FloatImage image) {
    final width = canvas.width;
    final height = canvas.height;
    final horizontal = Float32List(width * height);
    final out = Float32List(width * height);
    const radius = _gainBlurRadius;
    const window = 2 * radius + 1;

    double luma(int x, int y) {
      final o = image.offset(x, y);
      return 0.299 * image.data[o] +
          0.587 * image.data[o + 1] +
          0.114 * image.data[o + 2];
    }

    int wrap(int x) {
      final v = x % width;
      return v < 0 ? v + width : v;
    }

    for (var y = 0; y < height; y++) {
      var sum = 0.0;
      for (var k = -radius; k <= radius; k++) {
        sum += luma(wrap(k), y);
      }
      for (var x = 0; x < width; x++) {
        horizontal[y * width + x] = sum / window;
        sum -= luma(wrap(x - radius), y);
        sum += luma(wrap(x + radius + 1), y);
      }
    }

    for (var x = 0; x < width; x++) {
      var sum = 0.0;
      for (var k = -radius; k <= radius; k++) {
        sum += horizontal[k.clamp(0, height - 1) * width + x];
      }
      for (var y = 0; y < height; y++) {
        out[y * width + x] = sum / window;
        sum -= horizontal[(y - radius).clamp(0, height - 1) * width + x];
        sum += horizontal[(y + radius + 1).clamp(0, height - 1) * width + x];
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- S4

  /// S4 — largest inter-frame gain ratio left in the output.
  ///
  /// Measured on the result rather than taken from the compensator: for each
  /// frame's own region of the panorama, how much brighter or darker the
  /// stitched pixels are than the ground truth there. If compensation worked,
  /// every frame's ratio is the same number and their spread is 1.0; if one
  /// frame came out a third of a stop hot, its region says so.
  ///
  /// Keeping it a *photometric* metric rather than a second geometric one takes
  /// two steps. Clipped and near-black pixels are dropped, because a ratio
  /// taken against 255 or against 0 measures the clip. And both images are
  /// **low-pass filtered first**, over [_gainBlurRadius] pixels, because gain
  /// is a low-frequency property and misregistration is not: shifting an edge
  /// by a few pixels changes a raw ratio as violently as a third of a stop
  /// would, so without the blur this metric reports registration error under a
  /// photometric name. Blurred, a displaced edge contributes almost nothing
  /// while a frame that came out hot stays exactly as hot as it was.
  Metric _maxGainRatio() {
    final width = canvas.width;
    final labels = outcome.labels;
    final got = _blurredLuma(outcome.equirect);
    final want = _blurredLuma(groundTruthImage);
    final ratios = List.generate(_positionCount, (_) => <double>[]);

    for (var y = 0; y < canvas.height; y++) {
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        final label = labels[i];
        if (label < 0 || label >= _positionCount) continue;
        if (want[i] < 0.08 || want[i] > 0.92 || got[i] < 0.02) continue;
        ratios[label].add(got[i] / want[i]);
      }
    }

    var lowest = double.infinity;
    var highest = 0.0;
    var measured = 0;
    for (var i = 0; i < _positionCount; i++) {
      if (ratios[i].length < 400) continue;
      ratios[i].sort();
      // The median, not the mean: one blown highlight inside a frame's region
      // should not decide what that frame's gain was.
      final ratio = ratios[i][ratios[i].length ~/ 2];
      if (ratio < lowest) lowest = ratio;
      if (ratio > highest) highest = ratio;
      measured++;
    }
    if (measured < 2) {
      return const Metric.unavailable(
        id: 's4',
        label: 'max gain ratio',
        reason: 'too few frame regions to compare',
      );
    }
    final ratio = highest / lowest;
    return Metric(
      id: 's4',
      label: 'max gain ratio',
      value: ratio,
      formatted: ratio.toStringAsFixed(3),
      target: '< ${targets.gainRatio.toStringAsFixed(2)}',
      pass: ratio < targets.gainRatio,
    );
  }

  // ---------------------------------------------------------------- S5

  /// S5 — coverage, area-weighted so it means "fraction of the sphere".
  Metric _coverage() {
    var total = 0.0;
    var once = 0.0;
    var twice = 0.0;
    for (var y = 0; y < canvas.height; y++) {
      final weight = canvas.rowSolidAngleWeight(y);
      for (var x = 0; x < canvas.width; x++) {
        final count = outcome.counts[y * canvas.width + x];
        total += weight;
        if (count >= 1) once += weight;
        if (count >= 2) twice += weight;
      }
    }
    final atLeastOnce = once / total;
    final atLeastTwice = twice / total;
    // S5a is the hard gate; S5c is a floor against degenerate plans, not a
    // target. The ≥2× figure used to be gated at 0.95, which is algebraically a
    // demand for ω = 0.487 against a documented default of 0.33 — see Math §8
    // for the derivation and the measured cost. S5b (pairwise overlap) is a
    // property of the *plan*, so `coverage_validator` asserts it before the
    // camera opens; by the time a bundle reaches replay it is already settled.
    //
    // `partial` is exempt: it is an abandoned session by construction, so
    // demanding a complete sphere of it would fail it for being what it is. Its
    // criterion is that the fill leaves no black pixels and that the reported
    // figure is honest, which is what `holes` and the coverage cross-check
    // measure instead.
    final pass =
        !targets.requireFullCoverage ||
        (atLeastOnce >= 1 - 1e-6 &&
            atLeastTwice >= CoverageReport.minimumDoubleCoverage);
    return Metric(
      id: 's5',
      label: 'coverage',
      value: atLeastOnce,
      formatted:
          '${atLeastOnce.toStringAsFixed(3)} / ${atLeastTwice.toStringAsFixed(3)}',
      target: targets.requireFullCoverage
          ? '1.0 / '
                '${CoverageReport.minimumDoubleCoverage.toStringAsFixed(2)}'
          : 'reported honestly',
      pass: pass,
      lowerIsBetter: false,
    );
  }

  // ---------------------------------------------------------------- S6

  /// S6 — SSIM and PSNR over the covered, non-pole-filled region.
  ({Metric ssim, Metric psnr, double excludedFraction}) _fidelity() {
    final width = canvas.width;
    final height = canvas.height;
    final labels = outcome.labels;

    // §4: exclude pole-filled areas, or the fill's smooth blur inflates SSIM.
    final valid = Uint8List(width * height);
    var includedWeight = 0.0;
    var totalWeight = 0.0;
    for (var y = 0; y < height; y++) {
      final weight = canvas.rowSolidAngleWeight(y);
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        totalWeight += weight;
        if (labels[i] >= 0) {
          valid[i] = 1;
          includedWeight += weight;
        }
      }
    }
    final excluded = totalWeight == 0 ? 1.0 : 1 - includedWeight / totalWeight;

    // PSNR, over RGB, weighted by each row's solid angle.
    var sumSquares = 0.0;
    var weightTotal = 0.0;
    for (var y = 0; y < height; y++) {
      final weight = canvas.rowSolidAngleWeight(y);
      for (var x = 0; x < width; x++) {
        final i = y * width + x;
        if (valid[i] == 0) continue;
        for (var c = 0; c < 3; c++) {
          final d = outcome.equirect.data[i * 3 + c] -
              groundTruthImage.data[i * 3 + c];
          sumSquares += weight * d * d;
        }
        weightTotal += weight * 3;
      }
    }

    final Metric psnrMetric;
    if (weightTotal == 0) {
      psnrMetric = const Metric.unavailable(
        id: 's6_psnr',
        label: 'psnr',
        reason: 'nothing covered',
      );
    } else {
      final mse = sumSquares / weightTotal;
      final db = mse <= 0 ? 99.0 : 10 * math.log(1 / mse) / math.ln10;
      psnrMetric = Metric(
        id: 's6_psnr',
        label: 'psnr',
        value: db,
        formatted: '${db.toStringAsFixed(1)} dB',
        target: '>= ${targets.psnrDb.toStringAsFixed(0)}',
        pass: db >= targets.psnrDb,
        lowerIsBetter: false,
      );
    }

    final ssim = _ssim(valid);
    final Metric ssimMetric;
    if (ssim == null) {
      ssimMetric = const Metric.unavailable(
        id: 's6_ssim',
        label: 'ssim',
        reason: 'no fully-covered window',
      );
    } else {
      ssimMetric = Metric(
        id: 's6_ssim',
        label: 'ssim',
        value: ssim,
        formatted: ssim.toStringAsFixed(4),
        target: '>= ${targets.ssim.toStringAsFixed(2)}',
        pass: ssim >= targets.ssim,
        lowerIsBetter: false,
      );
    }

    return (ssim: ssimMetric, psnr: psnrMetric, excludedFraction: excluded);
  }

  /// Mean SSIM over 8×8 luma windows on a 4 px stride, skipping any window
  /// that touches an excluded pixel, and weighted by the window's solid angle.
  double? _ssim(Uint8List valid) {
    const window = 8;
    const stride = 4;
    const c1 = 0.01 * 0.01;
    const c2 = 0.03 * 0.03;
    final width = canvas.width;
    final height = canvas.height;

    double luma(FloatImage image, int i) =>
        0.299 * image.data[i * 3] +
        0.587 * image.data[i * 3 + 1] +
        0.114 * image.data[i * 3 + 2];

    var weighted = 0.0;
    var weightTotal = 0.0;

    for (var y = 0; y + window <= height; y += stride) {
      final weight = canvas.rowSolidAngleWeight(y + window ~/ 2);
      for (var x = 0; x < width; x += stride) {
        var meanA = 0.0, meanB = 0.0;
        var ok = true;
        for (var j = 0; j < window && ok; j++) {
          for (var i = 0; i < window; i++) {
            final index = (y + j) * width + (x + i) % width;
            if (valid[index] == 0) {
              ok = false;
              break;
            }
            meanA += luma(outcome.equirect, index);
            meanB += luma(groundTruthImage, index);
          }
        }
        if (!ok) continue;

        const n = window * window;
        meanA /= n;
        meanB /= n;
        var varA = 0.0, varB = 0.0, covariance = 0.0;
        for (var j = 0; j < window; j++) {
          for (var i = 0; i < window; i++) {
            final index = (y + j) * width + (x + i) % width;
            final a = luma(outcome.equirect, index) - meanA;
            final b = luma(groundTruthImage, index) - meanB;
            varA += a * a;
            varB += b * b;
            covariance += a * b;
          }
        }
        varA /= n - 1;
        varB /= n - 1;
        covariance /= n - 1;

        final value =
            ((2 * meanA * meanB + c1) * (2 * covariance + c2)) /
            ((meanA * meanA + meanB * meanB + c1) * (varA + varB + c2));
        weighted += value * weight;
        weightTotal += weight;
      }
    }
    return weightTotal == 0 ? null : weighted / weightTotal;
  }

  // ------------------------------------------------------- residual tilt

  /// Residual tilt — how far the whole panorama's up axis is from gravity.
  ///
  /// A rotation-only bundle adjustment has an exact 3-DOF gauge freedom
  /// (Math §7), so the interesting quantity is not any one frame's error but
  /// the *common* rotation between the solution and the truth. Averaging the
  /// per-frame misalignments gives it, and the angle by which that average tips
  /// world up is the tilt. A pure heading offset leaves this at zero, correctly:
  /// a panorama rotated in yaw is not tilted.
  Metric _residualTilt() {
    if (_positionCount == 0) {
      return const Metric.unavailable(
        id: 'tilt',
        label: 'residual tilt',
        reason: 'no positions',
      );
    }
    final misalignments = <Quaternion>[];
    for (var i = 0; i < _positionCount; i++) {
      final relative =
          outcome.estimatedDeviceToWorld[i] *
              truth.positions[i].trueDeviceToWorld.transposed()
          as Matrix3;
      misalignments.add(Quaternion.fromRotation(relative)..normalize());
    }
    final average = RotationFit.average(misalignments);
    if (average == null) {
      return const Metric.unavailable(
        id: 'tilt',
        label: 'residual tilt',
        reason: 'degenerate rotation set',
      );
    }
    final up = average.rotated(Vector3(0, 1, 0));
    final degrees = math.acos(up.y.clamp(-1.0, 1.0)) * 180 / math.pi;
    return Metric(
      id: 'tilt',
      label: 'residual tilt',
      value: degrees,
      formatted: '${degrees.toStringAsFixed(3)} deg',
      target: '< ${targets.residualTiltDegrees.toStringAsFixed(1)}',
      pass: degrees < targets.residualTiltDegrees,
    );
  }

  // ----------------------------------------------------------- peak RSS

  /// Peak resident set of the replay process.
  ///
  // ------------------------------------------------- Phase 05 §7 dynamic range

  /// Stops away from the metered exposure at which a region counts as beyond what
  /// one exposure can hold.
  ///
  /// A phone JPEG spans about 10 stops, so ±4 is comfortably outside it in both
  /// directions while still selecting a region large enough to measure: on
  /// `hdr_interior` the sky sits at +5.95 and the far corner bottoms out at −5.95.
  /// On a profile whose windows are only 1.5 stops up — `nominal` — neither region
  /// exists, and both metrics correctly report that there is nothing to measure
  /// rather than scoring an empty set.
  static const double _extremeExposureStops = 4.0;

  /// Luma level at or above which a pixel has no highlight detail left.
  static const double _clippedLevel = 250 / 255;

  /// Luma level at or below which a pixel has no shadow detail left.
  static const double _crushedLevel = 4 / 255;

  /// Phase 05's own criterion: is the detail in the extremes of the scene's
  /// dynamic range actually *there* in the panorama?
  ///
  /// The two ends are measured differently, because they fail differently and
  /// because one thing the reference cannot be used for is brightness. The ground
  /// truth is the room's *reflectance*, rendered as if uniformly lit — the 12 stops
  /// of scene radiance live in a separate EV map, which is what makes the fixture
  /// possible at all. So the shadow region's truth sits at luma 142 while any
  /// physically achievable 8-bit rendition of a region seven stops below the
  /// metered exposure sits near 10. A metric comparing levels would be measuring
  /// the impossibility of the reference rather than the quality of the fusion.
  ///
  /// **Highlights fail at the rail.** A blown window is 255, and 255 is not a
  /// contrast problem, it is an absence: the information was destroyed in the
  /// sensor and nothing recovers it. So the highlight number is *headroom* — the
  /// fraction of the region still below the rail, which is exactly the doc's "the
  /// window is a white rectangle and you cannot see whether the frame is
  /// installed". This is also the one honest measure available on this fixture:
  /// its synthetic sky is nearly featureless (local σ of 0.5 levels in the ground
  /// truth against 5.7 in the shadow region), so there is no structure there to
  /// score even in principle. A real window has a façade behind it; if the scene
  /// ever grows one, the structural measure below becomes the better test at both
  /// ends.
  ///
  /// **Shadows fail into noise.** The detail is not destroyed, it is buried, so the
  /// question is whether it survived — measured as the mean local
  /// contrast-and-structure agreement with the truth, SSIM's own
  /// `(2σₐᵦ + C₂)/(σₐ² + σᵦ² + C₂)` over a 7×7 neighbourhood, with the luminance
  /// term dropped for the reason above. Read noise is uncorrelated with the truth,
  /// so a crushed region scores near zero; a faithful-but-darker rendition scores
  /// well. `C₂` is a half-level rather than standard SSIM's `(0.03·L)²`, which at
  /// these amplitudes would dominate both variances and score everything as
  /// agreement.
  Metric _dynamicRange({required bool highlight}) {
    final id = highlight ? 'hdr_window' : 'hdr_shadow';
    final label = highlight ? 'window detail' : 'shadow detail';
    final ev = evMap;
    if (ev == null) {
      return Metric.unavailable(
        id: id,
        label: label,
        reason: 'no EV map; this scene fits in one exposure',
      );
    }

    final width = canvas.width;
    final height = canvas.height;
    final region = Uint8List(width * height);
    var count = 0;
    for (var i = 0; i < region.length; i++) {
      final stops = ev.data[i];
      final inside = highlight
          ? stops >= _extremeExposureStops
          : stops <= -_extremeExposureStops;
      if (!inside) continue;
      region[i] = 1;
      count++;
    }
    // Below a thousandth of the sphere the region is a few hundred pixels and the
    // measurement is dominated by whatever the seam happened to do there.
    if (count < region.length / 1000) {
      return Metric.unavailable(
        id: id,
        label: label,
        reason: 'this scene has no region ${highlight ? 'above' : 'below'} '
            '${highlight ? '+' : '-'}${_extremeExposureStops.toStringAsFixed(0)} EV',
      );
    }

    var lost = 0;
    for (var i = 0; i < region.length; i++) {
      if (region[i] == 0) continue;
      final luma = _lumaAt(outcome.equirect, i);
      if (highlight ? luma >= _clippedLevel : luma <= _crushedLevel) lost++;
    }
    final lostFraction = lost / count;

    final value = highlight ? 1 - lostFraction : _contrastAmplitude(region);
    final target = highlight ? targets.hdrWindowHeadroom : targets.hdrShadowContrast;
    return Metric(
      id: id,
      label: label,
      value: value,
      formatted: highlight
          ? '${(value * 100).toStringAsFixed(1)}% below the rail'
          : '${(value * 100).toStringAsFixed(0)}% of truth, '
                '${(lostFraction * 100).toStringAsFixed(1)}% black',
      target: '>= ${target.toStringAsFixed(2)}',
      pass: value >= target,
      lowerIsBetter: false,
    );
  }

  /// Mean local contrast amplitude over [region], as a fraction of the ground
  /// truth's.
  ///
  /// A *statistic of the region* rather than a per-pixel comparison, and that is
  /// the point. The obvious metric here is SSIM's contrast-and-structure term, and
  /// it was tried first: it returns 0.02 for every variant including the control,
  /// because a per-pixel structural comparison over a 7×7 window is destroyed by a
  /// few pixels of misregistration, and registration is currently 8 px out
  /// (Phase 03's open gap). It was therefore measuring Phase 03 and reporting it
  /// as Phase 05. Contrast amplitude is insensitive to where the content landed
  /// and sensitive to whether it survived, which is the question this stage owns.
  ///
  /// The cost of that choice, stated rather than hidden: noise counts as contrast.
  /// A crushed region is not scored as zero but as whatever its read noise and
  /// quantisation amount to — on `hdr_interior`'s control that is 3.1 levels
  /// against the truth's 5.7 — so the floor of this metric is around 0.5 rather
  /// than 0. The number to read is the *gap* between fused and control, which is
  /// what the phase's exit criterion asks for and what `tools/hdr_ab.dart`
  /// asserts; the absolute target exists to stop a regression, not to certify a
  /// perfect rendition.
  ///
  /// Wraps in x and clamps in y, like every other sampler here: the meridian is
  /// not an edge, and beyond the pole there is only the pole again.
  double _contrastAmplitude(Uint8List region) {
    final measured = _meanLocalDeviation(outcome.equirect, region);
    final reference = _meanLocalDeviation(groundTruthImage, region);
    return reference <= 0 ? 0 : measured / reference;
  }

  /// Mean 7×7 standard deviation of luma over the pixels [region] marks.
  double _meanLocalDeviation(FloatImage image, Uint8List region) {
    const radius = 3;
    const taps = (2 * radius + 1) * (2 * radius + 1);
    final width = canvas.width;
    final height = canvas.height;
    var sum = 0.0;
    var n = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (region[y * width + x] == 0) continue;
        var total = 0.0;
        var totalSquares = 0.0;
        for (var dy = -radius; dy <= radius; dy++) {
          final sy = (y + dy).clamp(0, height - 1);
          for (var dx = -radius; dx <= radius; dx++) {
            var sx = (x + dx) % width;
            if (sx < 0) sx += width;
            final v = _lumaAt(image, sy * width + sx);
            total += v;
            totalSquares += v * v;
          }
        }
        final mean = total / taps;
        sum += math.sqrt(math.max(0.0, totalSquares / taps - mean * mean));
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  double _lumaAt(FloatImage image, int pixel) =>
      0.299 * image.data[pixel * 3] +
      0.587 * image.data[pixel * 3 + 1] +
      0.114 * image.data[pixel * 3 + 2];

  /// Honest about what it is: this measures the *harness*, which holds the
  /// ground truth, the diff image and the metric buffers alongside the stitch.
  /// It is an upper bound on the stitcher's own footprint, not a substitute for
  /// the on-device instrumentation S9 asks for — but a stitcher that blows the
  /// budget here has certainly blown it on a tablet.
  Metric _peakRss() {
    final mb = peakRssBytes / (1024 * 1024);
    return Metric(
      id: 'rss',
      label: 'peak rss',
      value: mb,
      formatted: '${mb.round()} MB',
      target: '< ${targets.peakRssMb.round()}',
      pass: mb < targets.peakRssMb,
    );
  }

  /// Peak resident set of this process, in bytes.
  static int currentPeakRss() => ProcessInfo.maxRss;
}

/// Resamples a ground truth to a different canvas, for when the replay tier
/// asks for an output size the fixture was not rendered at.
///
/// Bicubic and wrapping, like every other sampler here — a bilinear
/// down-sample would soften the reference and quietly hand the stitcher a
/// couple of dB of PSNR it did not earn.
FloatImage resampleEquirect(FloatImage source, EquirectCanvas canvas) {
  if (source.width == canvas.width && source.height == canvas.height) {
    return source;
  }
  final out = FloatImage(canvas.width, canvas.height, 3);
  final rgb = List<double>.filled(3, 0);
  final scaleX = source.width / canvas.width;
  final scaleY = source.height / canvas.height;
  for (var y = 0; y < canvas.height; y++) {
    for (var x = 0; x < canvas.width; x++) {
      source.sampleBicubic(
        (x + 0.5) * scaleX - 0.5,
        (y + 0.5) * scaleY - 0.5,
        rgb,
      );
      final o = out.offset(x, y);
      out.data[o] = rgb[0].clamp(0.0, 1.0);
      out.data[o + 1] = rgb[1].clamp(0.0, 1.0);
      out.data[o + 2] = rgb[2].clamp(0.0, 1.0);
    }
  }
  return out;
}

/// Resamples a single-channel equirect map — depth, or the EV offsets Phase 05's
/// metrics select their regions from — onto [canvas].
///
/// Bilinear and unclamped, unlike [resampleEquirect]: the quantity is smooth by
/// construction, it is not a display value, and it is legitimately negative.
FloatImage resampleScalar(FloatImage source, EquirectCanvas canvas) {
  if (source.width == canvas.width && source.height == canvas.height) {
    return source;
  }
  final out = FloatImage(canvas.width, canvas.height, 1);
  final value = List<double>.filled(1, 0);
  final scaleX = source.width / canvas.width;
  final scaleY = source.height / canvas.height;
  for (var y = 0; y < canvas.height; y++) {
    for (var x = 0; x < canvas.width; x++) {
      source.sampleBilinear((x + 0.5) * scaleX - 0.5, (y + 0.5) * scaleY - 0.5, value);
      out.data[y * canvas.width + x] = value[0];
    }
  }
  return out;
}

/// Rolls an equirect horizontally by half its width, moving the ±180° meridian
/// to the canvas centre.
///
/// A pure shift, so it costs the image nothing — no resampling, no interpolation,
/// nothing that could soften the very discontinuity it exists to expose.
FloatImage rollHalf(FloatImage source) {
  final half = source.width ~/ 2;
  final out = FloatImage(source.width, source.height, source.channels);
  final rowLength = source.width * source.channels;
  final split = half * source.channels;
  for (var y = 0; y < source.height; y++) {
    final start = y * rowLength;
    out.data.setRange(start, start + rowLength - split, source.data, start + split);
    out.data.setRange(start + rowLength - split, start + rowLength, source.data, start);
  }
  return out;
}

/// The plan's own coverage report, restated for the console.
String describeCoverage(CoverageReport report) =>
    '${(report.fractionCoveredAtLeastOnce * 100).toStringAsFixed(1)}% >=1x, '
    '${(report.fractionCoveredAtLeastTwice * 100).toStringAsFixed(1)}% >=2x';

/// Convenience for reporting the focal the stitcher settled on against the
/// truth, which is the direct explanation for most S2 failures.
String describeFocal(CameraIntrinsics estimated, CameraIntrinsics truth) {
  final error = (estimated.fx / truth.fx - 1) * 100;
  return '${estimated.fx.toStringAsFixed(1)} px vs ${truth.fx.toStringAsFixed(1)} '
      '(${error >= 0 ? '+' : ''}${error.toStringAsFixed(1)}%)';
}
