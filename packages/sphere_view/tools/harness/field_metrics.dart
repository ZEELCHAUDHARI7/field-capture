import 'dart:math' as math;

import 'package:sphere_view/src/api/models/capture_bundle.dart';

import 'camera_model.dart';
import 'metrics.dart';
import 'stitcher_backend.dart';

/// What can honestly be measured about a **real** capture, and nothing more.
///
/// Phase 12 §4 puts real-site captures into the quality gate, which is what stops
/// "the stitcher meets its targets" from being a synthetic-only claim. But a real
/// capture has no ground truth — nobody surveyed the building, nobody knows where
/// the camera really was — and four of the ten criteria are defined against a
/// reference:
///
/// | criterion | synthetic | field |
/// |---|---|---|
/// | S1 geometric accuracy | reprojection against the true camera | **not measurable** |
/// | S2 loop closure | the pairwise chain through true correspondences | **not measurable** |
/// | S3 seam | stitched gradient step *minus the truth's step* | reference-free variant, own id |
/// | S4 gain ratio | the compensator's own output | same |
/// | S5 coverage | the count map | same |
/// | S6 SSIM/PSNR | against the reference image | **not measurable** |
/// | residual tilt | against the true rotations | **not measurable** |
///
/// ## The one rule this class exists to enforce
///
/// **A self-reported number never inherits a truth-referenced metric's name.**
///
/// The tempting move is to fill the four gaps with what the stitcher says about
/// itself — bundle adjustment's residual for S1, the report's loop closure for
/// S2 — and keep the ids, so the field rows line up with the synthetic ones in
/// one table. That would be a lie of exactly the kind this project has already
/// made twice. Bundle adjustment's residual measures *self-consistency*, and a
/// solution can be smoothly, confidently, self-consistently wrong: a focal error
/// does precisely that, which is why Phase 03's original loop-closure measurement
/// was a tautology (composing absolute rotations around a ring telescopes to the
/// identity whatever they are) and why S1 computed over only the frames that
/// registered read 0.295 px against a truth-referenced 4.65 px.
///
/// So the reported figures appear as `s1_reported`, `s2_reported`,
/// `tilt_reported`, plainly labelled "self-reported", and a baseline can never
/// confuse one for the other because the ids differ. What they are good for is
/// *movement*: the same bundle re-stitched after a change should give the same
/// self-reported residual, and if it does not, something moved. That is the whole
/// job of a regression corpus, and it does not require the number to be true.
class FieldMetricsEngine {
  /// Creates an engine over one stitch of a real capture.
  FieldMetricsEngine({
    required this.bundle,
    required this.outcome,
    required this.canvas,
    required this.peakRssBytes,
    required this.scene,
    this.reportedRmsPx,
    this.reportedLoopDegrees,
    this.reportedTiltDegrees,
  });

  /// The capture that was stitched.
  final CaptureBundle bundle;

  /// What the stitcher produced.
  final StitchOutcome outcome;

  /// Output canvas geometry.
  final EquirectCanvas canvas;

  /// Peak resident set of the replay process, in bytes.
  final int peakRssBytes;

  /// Which of §4's seven scenes this is, and what it is allowed to cost.
  final FieldScene scene;

  /// The stitcher's own S1, S2 and levelling residual, if the report carried
  /// them. Reported under `*_reported` ids; see the class docs.
  final double? reportedRmsPx;
  final double? reportedLoopDegrees;
  final double? reportedTiltDegrees;

  /// Runs every metric a field bundle supports.
  List<Metric> compute() => [
    _seamScore(),
    _wrapSeamScore(),
    _maxGainRatio(),
    _coverage(),
    _unfilledHoles(),
    _selfReported(
      id: 's1_reported',
      label: 'rms reproj (self)',
      value: reportedRmsPx,
      unit: 'px',
      target: scene.reportedRmsPx,
    ),
    _selfReported(
      id: 's2_reported',
      label: 'loop closure (self)',
      value: reportedLoopDegrees,
      unit: 'deg',
      target: scene.reportedLoopDegrees,
    ),
    _selfReported(
      id: 'tilt_reported',
      label: 'residual tilt (self)',
      value: reportedTiltDegrees,
      unit: 'deg',
      target: scene.reportedTiltDegrees,
    ),
    _peakRss(),
  ];

  // ---------------------------------------------------------------- S3

  /// S3 without a reference: the luma step across a seam against the steps
  /// either side of it.
  ///
  /// Architecture §1 states S3 reference-free — "no seam detectable by the
  /// gradient-discontinuity metric above 2× local noise floor" — and this is that
  /// reading. The synthetic version is *stricter*, because it subtracts the
  /// gradient the ground truth has at the same place, so a real edge in the scene
  /// cannot be scored as a seam. Here there is nothing to subtract, so a seam that
  /// happens to run along a door frame is indistinguishable from the door frame,
  /// and the number is correspondingly noisier and biased upward.
  ///
  /// Which is why it has its own id (`s3_field`) and its own baseline. Comparing
  /// it against a synthetic `s3` would be comparing two different measurements.
  Metric _seamScore() => _seamMetric(
    id: 's3_field',
    label: 'seam (no ref)',
    target: scene.seamScore,
    interior: true,
  );

  /// The same measurement at the ±180° meridian, which is the one defect a
  /// non-wrapping check cannot see.
  Metric _wrapSeamScore() => _seamMetric(
    id: 's3_field_wrap',
    label: 'wrap seam (no ref)',
    target: scene.wrapSeamScore,
    interior: false,
  );

  Metric _seamMetric({
    required String id,
    required String label,
    required double target,
    required bool interior,
  }) {
    final ratios = <double>[];
    final labels = outcome.labels;
    for (var y = 2; y < canvas.height - 2; y++) {
      final xs = interior
          ? Iterable<int>.generate(canvas.width - 4, (i) => i + 2)
          : <int>[0, canvas.width - 1];
      for (final x in xs) {
        final here = labels[y * canvas.width + x];
        // A seam is where two different frames meet. Uncovered pixels and
        // pole-filled ones are not seams and would swamp the statistic.
        if (here == StitchOutcome.uncovered) continue;
        final rightX = (x + 1) % canvas.width;
        final right = labels[y * canvas.width + rightX];
        if (right == StitchOutcome.uncovered || right == here) continue;
        ratios.add(_ratioAt(x, y));
      }
    }
    if (ratios.isEmpty) {
      return Metric.unavailable(
        id: id,
        label: label,
        reason: 'no frame boundaries found in the output',
      );
    }
    ratios.sort();
    // The 95th percentile, as the synthetic S3 uses: a mean would be dominated
    // by the great majority of seams that are invisible, which is not the
    // question — one visible seam ruins a panorama.
    final score = ratios[(0.95 * (ratios.length - 1)).floor()];
    return Metric(
      id: id,
      label: label,
      value: score,
      formatted: '${score.toStringAsFixed(2)}x noise',
      target: '< ${target.toStringAsFixed(1)}',
      pass: score < target,
    );
  }

  /// The luma step across ([x], [y]) against the median step either side.
  double _ratioAt(int x, int y) {
    double step(int centre) {
      final a = _luma(x + centre + 1, y);
      final b = _luma(x + centre - 1, y);
      return (a - b).abs();
    }

    const offsets = [-4, -3, -2, 2, 3, 4];
    final references = [for (final o in offsets) step(o)]..sort();
    final local = (references[2] + references[3]) / 2;
    // The same 1/255 floor the synthetic metric uses: without it a perfectly
    // flat wall makes every ratio infinite.
    return step(0) / math.max(local, 1 / 255);
  }

  double _luma(int x, int y) {
    var xx = x % canvas.width;
    if (xx < 0) xx += canvas.width;
    final yy = y.clamp(0, canvas.height - 1);
    final o = outcome.equirect.offset(xx, yy);
    final data = outcome.equirect.data;
    return 0.299 * data[o] + 0.587 * data[o + 1] + 0.114 * data[o + 2];
  }

  // ---------------------------------------------------------------- S4

  Metric _maxGainRatio() {
    final reported = outcome.diagnostics['max_gain_ratio'];
    if (reported is! num) {
      return const Metric.unavailable(
        id: 's4',
        label: 'max gain ratio',
        reason: 'the stitcher reported none',
      );
    }
    final value = reported.toDouble();
    return Metric(
      id: 's4',
      label: 'max gain ratio',
      value: value,
      formatted: value.toStringAsFixed(3),
      target: '< ${scene.gainRatio.toStringAsFixed(2)}',
      pass: value < scene.gainRatio,
    );
  }

  // ---------------------------------------------------------------- S5

  /// Coverage, from the count map rather than from the report.
  ///
  /// Measured here even though the report carries a figure, because the two
  /// being computed independently is the only way a disagreement can show up —
  /// and a coverage number the report cannot stand behind is worse than none.
  Metric _coverage() {
    var total = 0.0;
    var once = 0.0;
    var twice = 0.0;
    for (var y = 0; y < canvas.height; y++) {
      final weight = canvas.rowSolidAngleWeight(y);
      for (var x = 0; x < canvas.width; x++) {
        total += weight;
        final count = outcome.counts[y * canvas.width + x];
        if (count >= 1) once += weight;
        if (count >= 2) twice += weight;
      }
    }
    final fraction = total == 0 ? 0.0 : once / total;
    final double_ = total == 0 ? 0.0 : twice / total;
    return Metric(
      id: 's5',
      label: 'coverage',
      value: fraction,
      formatted:
          '${fraction.toStringAsFixed(3)} / ${double_.toStringAsFixed(3)}',
      target: scene.requireFullCoverage ? '1.000 / >= 0.70' : 'honest',
      pass: !scene.requireFullCoverage || fraction >= 1.0 - 1e-9,
      lowerIsBetter: false,
    );
  }

  /// Black pixels left in the output — the pole fill's exit criterion.
  Metric _unfilledHoles() {
    var black = 0;
    final data = outcome.equirect.data;
    final pixels = canvas.width * canvas.height;
    for (var i = 0; i < pixels; i++) {
      final o = i * 3;
      if (data[o] < 3 / 255 && data[o + 1] < 3 / 255 && data[o + 2] < 3 / 255) {
        black++;
      }
    }
    final fraction = pixels == 0 ? 0.0 : black / pixels;
    return Metric(
      id: 'holes',
      label: 'black pixels',
      value: fraction,
      formatted: '${(fraction * 100).toStringAsFixed(3)}%',
      target: '0%',
      // Not zero-tolerance: a real scene can contain genuinely black pixels — an
      // unlit shaft, a dark doorway — which the synthetic room cannot. 0.1% of
      // the sphere is far more than a fill failure leaves and far less than a
      // real dark corner occupies.
      pass: fraction < 0.001,
    );
  }

  // ------------------------------------------------------- self-reported

  Metric _selfReported({
    required String id,
    required String label,
    required double? value,
    required String unit,
    required double target,
  }) {
    if (value == null) {
      return Metric.unavailable(
        id: id,
        label: label,
        reason: 'the report carried no figure',
      );
    }
    return Metric(
      id: id,
      label: label,
      value: value,
      formatted: '${value.toStringAsFixed(unit == 'px' ? 2 : 3)} $unit (self)',
      target: '< ${target.toStringAsFixed(unit == 'px' ? 1 : 2)} (self)',
      pass: value < target,
    );
  }

  Metric _peakRss() {
    final mb = peakRssBytes / (1024 * 1024);
    return Metric(
      id: 'rss',
      label: 'peak rss',
      value: mb,
      formatted: '${mb.round()} MB',
      target: '< 700',
      pass: mb < 700,
    );
  }
}

/// One of the seven scenes Phase 12 §4 asks for, and what it is allowed to cost.
///
/// The per-scene thresholds exist for the same reason `MetricTargets.forProfile`
/// does: holding a tight room at 1 m to the same bar as an open daylight shell
/// would fail it for obeying optics, and holding the daylight shell to the tight
/// room's bar would let a real regression through on the one scene that has no
/// excuses. §4's own words for the first row are "must be excellent, no excuses".
class FieldScene {
  /// Creates a scene definition.
  const FieldScene({
    required this.name,
    required this.stresses,
    required this.shootingNote,
    this.seamScore = 2.5,
    this.wrapSeamScore = 2.5,
    this.gainRatio = 1.10,
    this.reportedRmsPx = 3.0,
    this.reportedLoopDegrees = 1.0,
    this.reportedTiltDegrees = 0.5,
    this.requireFullCoverage = true,
  });

  /// Directory name inside the corpus.
  final String name;

  /// What §4 says this scene is for.
  final String stresses;

  /// How to shoot it, so that a second capture a year later is the same
  /// experiment. Without this a "regression" is just a different afternoon.
  final String shootingNote;

  /// Reference-free S3, 95th percentile. Looser than the synthetic 2.0 because
  /// the reference-free variant cannot subtract real scene edges.
  final double seamScore;

  /// The same at the ±180° meridian.
  final double wrapSeamScore;

  /// S4. Looser than 1.03 on a real device, where the AE lock is imperfect and
  /// vignetting is not synthetic.
  final double gainRatio;

  /// The stitcher's **self-reported** residual. A bound on movement, not a
  /// statement of accuracy — see [FieldMetricsEngine].
  final double reportedRmsPx;
  final double reportedLoopDegrees;
  final double reportedTiltDegrees;

  /// Whether the sphere must be complete. False for the scenes shot partially on
  /// purpose.
  final bool requireFullCoverage;

  /// §4's seven scenes, in its order.
  ///
  /// **None of these bundles exists yet.** They are captured on a real site with
  /// `docs/FIELD_CORPUS.md` in hand, and until they are, the gate reports the
  /// corpus as absent rather than passing without it — see `quality_gate.dart`.
  static const List<FieldScene> all = [
    FieldScene(
      name: 'daylight_shell',
      stresses: 'the easy case — must be excellent, no excuses',
      shootingNote:
          'Open structural shell, daylight, nothing closer than 4 m. Clamp on a '
          'monopod. This is the reference scene the device matrix quotes S1-S6 '
          'on, so it is the one to re-shoot identically if it is ever lost.',
      // §4: no excuses. The tightest bars in the corpus.
      seamScore: 2.0,
      gainRatio: 1.05,
      reportedRmsPx: 1.5,
      reportedLoopDegrees: 0.5,
      reportedTiltDegrees: 0.3,
    ),
    FieldScene(
      name: 'window_interior',
      stresses: 'HDR fusion (Phase 05) — 12+ EV from corner to sky',
      shootingNote:
          'Interior with unshaded window openings, shot when the sun is NOT '
          'behind them. Three-exposure bracket; check the report says every '
          'position fused.',
      gainRatio: 1.15,
    ),
    FieldScene(
      name: 'bare_drywall_corridor',
      stresses: 'low texture, SIFT thresholds, imu_only handling',
      shootingNote:
          'Corridor of taped drywall and poured slab, no fittings in view. This '
          'scene is EXPECTED to produce imu_only frames — the criterion is that '
          'it degrades and says so, not that it succeeds.',
      reportedRmsPx: 12.0,
      reportedLoopDegrees: 3.0,
    ),
    FieldScene(
      name: 'mep_overhead',
      stresses: 'fine repeated structure, zenith coverage',
      shootingNote:
          'Under exposed services or scaffolding, with the repetitive structure '
          'overhead. Shoot every zenith prompt — this is where the matcher can '
          'alias onto the wrong copy of an identical duct hanger.',
      seamScore: 3.0,
    ),
    FieldScene(
      name: 'tight_room_1m',
      stresses: 'parallax — the honest floor',
      shootingNote:
          'A room where the nearest wall is about 1 m away. Shoot it TWICE: once '
          'clamped on a monopod, once handheld pivoting as carefully as a real '
          'operator manages, and keep both as `tight_room_1m` and '
          '`tight_room_1m_handheld`. The pair is the only measurement of the '
          'parallax floor on real texture, and the second is also the fixture '
          'that could settle whether the translation signature of architecture '
          '§3.3 works outside the synthetic room '
          '(`phases/findings/translation_signature.md`).',
      seamScore: 3.5,
      reportedRmsPx: 20.0,
      reportedLoopDegrees: 4.0,
    ),
    FieldScene(
      name: 'active_workers',
      stresses: 'ghost suppression (Phase 05 §3.3), moving subjects',
      shootingNote:
          'An area with people working in it. Do not ask them to stand still — '
          'the point is a worker who walks through the sphere. Expect somebody '
          'to appear once, twice or half-cut; the criterion is that the damage '
          'stays local.',
      seamScore: 3.5,
    ),
    FieldScene(
      name: 'dusk_temporary_light',
      stresses: 'noise, exposure, the sharpness gate',
      shootingNote:
          'Dusk or festoon/temporary lighting only. The shutter is slow here, so '
          'expect the sharpness gate to reject positions — that is the scene '
          'working as intended. Hold steadier than usual.',
      gainRatio: 1.20,
      reportedRmsPx: 6.0,
    ),
  ];

  /// The scene called [name], or `null`.
  static FieldScene? byName(String name) {
    for (final scene in all) {
      if (scene.name == name) return scene;
    }
    return null;
  }
}
