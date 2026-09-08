import 'camera_intrinsics.dart';
import 'json_codec.dart';
import 'sphere_capture_config.dart';
import 'stitch_warning.dart';

/// The measured quality of one stitch, against the criteria in architecture §1.
///
/// This type is what turns "perfect" from an opinion into a number, in the
/// synthetic harness and in the field alike. It also carries the project's
/// **never silently degrade** rule (architecture §8): every compromise the
/// pipeline made — a pair that fell back to the IMU prior, a dropped position,
/// a downgraded tier after an OOM retry — lands in [warnings] and reaches the
/// caller. A panorama that came out worse than it should have must be able to
/// say why, in the field, months later, from the report alone.
class StitchReport {
  /// Creates a report. Produced by the native `report.cpp` stage, never by
  /// hand outside tests.
  const StitchReport({
    required this.rmsReprojectionErrorPx,
    required this.loopClosureErrorDegrees,
    required this.maxGainRatio,
    required this.coverageFraction,
    required this.refinedFocalPx,
    required this.refinedIntrinsics,
    this.capturedIntrinsics,
    required this.residualTiltDegrees,
    required this.droppedPositionIndices,
    required this.warnings,
    required this.elapsedMs,
    required this.tierUsed,
  });

  /// S1 target: RMS reprojection error must be under this, in pixels at
  /// registration scale.
  static const double maxRmsReprojectionErrorPx = 1.0;

  /// S2 target: yaw error after a full 360° traverse, in degrees.
  static const double maxLoopClosureErrorDegrees = 0.25;

  /// S4 target: maximum inter-frame gain ratio after compensation.
  static const double maxAcceptableGainRatio = 1.03;

  /// Math §7 acceptance: residual tilt after Kabsch levelling, in degrees.
  static const double maxResidualTiltDegrees = 0.2;

  /// S1 — bundle adjustment's RMS reprojection residual, in pixels at
  /// registration scale.
  final double rmsReprojectionErrorPx;

  /// S2 — yaw error accumulated around a full turn. The honest test of whether
  /// the focal estimate was right.
  final double loopClosureErrorDegrees;

  /// S4 — largest inter-frame gain ratio left after gain compensation. Above
  /// ~1.03 the banding is visible.
  final double maxGainRatio;

  /// S5 — fraction of sphere directions present in the output. Below 1.0 means
  /// a partial panorama was emitted deliberately rather than faked.
  final double coverageFraction;

  /// Focal length in pixels after `BundleAdjusterRay` refined it from the
  /// imagery. Compared against the input focal, this is how a weak intrinsics
  /// path gets caught (Math §4.3).
  final double refinedFocalPx;

  /// The full intrinsics after refinement, with `source` set to
  /// `IntrinsicsSource.refinedByStitcher`.
  final CameraIntrinsics refinedIntrinsics;

  /// What the stitcher was *given* — the device's own intrinsics, before any
  /// refinement.
  ///
  /// Reported so [refinedIntrinsics] can be read against something. Without it
  /// a refined focal is unfalsifiable: a real capture came back claiming a
  /// 23.5 degree field of view on a camera that has about 67, and no number in
  /// the report said what the device had actually reported, so there was no way
  /// to tell a lying platform from a runaway solver. Absent on reports written
  /// before this existed, which is why it is nullable rather than required.
  final CameraIntrinsics? capturedIntrinsics;

  /// Tilt left after levelling against measured gravity (Math §7). The whole
  /// point of not calling `waveCorrect` is that this number can be asserted.
  final double residualTiltDegrees;

  /// Positions the pipeline could not use, by their `CapturedPosition`
  /// index — blurred, unmatched, or fused badly.
  final List<int> droppedPositionIndices;

  /// Every compromise made, as a code plus the numbers behind it. Empty is the
  /// goal; non-empty must reach the user.
  ///
  /// Coded rather than pre-written prose (Phase 12 §2). The sentence a user reads
  /// is [StitchWarning.message], composed in one reviewable place from the code
  /// and its data — which is what lets `warning_messages_test.dart` prove that
  /// every warning the pipeline can emit has a sentence, and what stopped the
  /// wording from being whatever the engineer who found the condition typed at
  /// the site that found it.
  final List<StitchWarning> warnings;

  /// Wall-clock duration of the stitch, checked against S8's 60 s budget.
  final int elapsedMs;

  /// The tier actually used, which may be lower than the one requested if the
  /// pipeline degraded and retried after an OOM.
  final QualityTier tierUsed;

  /// The coverage a passing stitch must reach.
  ///
  /// Not 1.0. `coverageFraction` is `covered / 40000` over a Fibonacci lattice, so
  /// a single uncovered sample lands 2.5e-5 below one — and the exact test this
  /// used to make (`>= 1.0 - 1e-9`) is 25 000x too tight to admit even that. The
  /// native side worked this out and abandoned the same comparison; keeping it
  /// here meant `meetsQualityTargets` was unreachable on every real capture, which
  /// silently disabled the example's storage policy rather than failing loudly.
  static const double minimumCoverageFraction = 0.995;

  /// Whether this stitch met the quality criteria S1, S2, S4, S5 and the
  /// Math §7 levelling acceptance.
  ///
  /// S3 (seam score) and S6 (SSIM/PSNR) are excluded because they need a
  /// reference the device does not have — they are asserted by the synthetic
  /// harness in Phase 02, not at runtime. S7–S9 are budgets, not quality, and
  /// are reported separately rather than gating.
  bool get meetsQualityTargets =>
      rmsReprojectionErrorPx < maxRmsReprojectionErrorPx &&
      loopClosureErrorDegrees < maxLoopClosureErrorDegrees &&
      maxGainRatio < maxAcceptableGainRatio &&
      residualTiltDegrees < maxResidualTiltDegrees &&
      coverageFraction >= minimumCoverageFraction;

  /// Returns a copy carrying [warnings] instead of this report's.
  ///
  /// The only field with a copier, because it is the only one a later stage
  /// legitimately adds to: the metadata writer and the tier downgrade both
  /// happen after the native report is built and both are compromises
  /// architecture §8 says must reach the caller. Every other number is a
  /// measurement, and a measurement that can be edited after the fact is not
  /// one.
  StitchReport copyWithWarnings(List<StitchWarning> warnings) => StitchReport(
    rmsReprojectionErrorPx: rmsReprojectionErrorPx,
    loopClosureErrorDegrees: loopClosureErrorDegrees,
    maxGainRatio: maxGainRatio,
    coverageFraction: coverageFraction,
    refinedFocalPx: refinedFocalPx,
    refinedIntrinsics: refinedIntrinsics,
    capturedIntrinsics: capturedIntrinsics,
    residualTiltDegrees: residualTiltDegrees,
    droppedPositionIndices: droppedPositionIndices,
    warnings: warnings,
    elapsedMs: elapsedMs,
    tierUsed: tierUsed,
  );

  /// Serialises; this is the shape `sv_stitch` returns across the ABI.
  Map<String, Object?> toJson() => {
    'rms_reprojection_error_px': rmsReprojectionErrorPx,
    'loop_closure_error_degrees': loopClosureErrorDegrees,
    'max_gain_ratio': maxGainRatio,
    'coverage_fraction': coverageFraction,
    'refined_focal_px': refinedFocalPx,
    'refined_intrinsics': refinedIntrinsics.toJson(),
    if (capturedIntrinsics != null)
      'captured_intrinsics': capturedIntrinsics!.toJson(),
    'residual_tilt_degrees': residualTiltDegrees,
    'dropped_position_indices': droppedPositionIndices,
    'warnings': [for (final warning in warnings) warning.toJson()],
    'elapsed_ms': elapsedMs,
    'tier_used': tierUsed.name,
  };

  /// Inverse of [toJson].
  factory StitchReport.fromJson(Map<String, Object?> json) {
    const ctx = 'StitchReport';
    return StitchReport(
      rmsReprojectionErrorPx: jsonDouble(
        json,
        'rms_reprojection_error_px',
        context: ctx,
      ),
      loopClosureErrorDegrees: jsonDouble(
        json,
        'loop_closure_error_degrees',
        context: ctx,
      ),
      maxGainRatio: jsonDouble(json, 'max_gain_ratio', context: ctx),
      coverageFraction: jsonDouble(json, 'coverage_fraction', context: ctx),
      refinedFocalPx: jsonDouble(json, 'refined_focal_px', context: ctx),
      refinedIntrinsics: CameraIntrinsics.fromJson(
        jsonObject(json, 'refined_intrinsics', context: ctx),
      ),
      capturedIntrinsics: json.containsKey('captured_intrinsics')
          ? CameraIntrinsics.fromJson(
              jsonObject(json, 'captured_intrinsics', context: ctx),
            )
          : null,
      residualTiltDegrees: jsonDouble(
        json,
        'residual_tilt_degrees',
        context: ctx,
      ),
      droppedPositionIndices: jsonIntList(
        json,
        'dropped_position_indices',
        context: ctx,
      ),
      warnings: jsonList(
        json,
        'warnings',
        StitchWarning.fromJson,
        context: ctx,
      ),
      elapsedMs: jsonInt(json, 'elapsed_ms', context: ctx),
      tierUsed: jsonEnum(json, 'tier_used', QualityTier.values, context: ctx),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StitchReport &&
      other.rmsReprojectionErrorPx == rmsReprojectionErrorPx &&
      other.loopClosureErrorDegrees == loopClosureErrorDegrees &&
      other.maxGainRatio == maxGainRatio &&
      other.coverageFraction == coverageFraction &&
      other.refinedFocalPx == refinedFocalPx &&
      other.refinedIntrinsics == refinedIntrinsics &&
      other.residualTiltDegrees == residualTiltDegrees &&
      other.elapsedMs == elapsedMs &&
      other.tierUsed == tierUsed &&
      listEquals(other.droppedPositionIndices, droppedPositionIndices) &&
      listEquals(other.warnings, warnings);

  @override
  int get hashCode => Object.hash(
    rmsReprojectionErrorPx,
    loopClosureErrorDegrees,
    maxGainRatio,
    coverageFraction,
    refinedFocalPx,
    refinedIntrinsics,
    residualTiltDegrees,
    listHash(droppedPositionIndices),
    listHash(warnings),
    elapsedMs,
    tierUsed,
  );

  @override
  String toString() =>
      'StitchReport(rms: ${rmsReprojectionErrorPx.toStringAsFixed(2)}px, '
      'loop: ${loopClosureErrorDegrees.toStringAsFixed(3)}°, '
      'gain: ${maxGainRatio.toStringAsFixed(3)}, '
      'coverage: ${(coverageFraction * 100).toStringAsFixed(1)}%, '
      'tier: ${tierUsed.name}, ${elapsedMs}ms, '
      '${warnings.length} warnings)';
}

/// The finished panorama: where it is, how big, and how good.
///
/// [report] is not optional and not a side channel. Bundling the measurement
/// with the artefact is what makes it awkward to ship a caller that ignores
/// quality — which is the intended pressure, given that the failure mode this
/// project is most exposed to is a panorama that looks fine in a thumbnail and
/// falls apart when a manager zooms in on a defect.
class StitchResult {
  /// Creates a result.
  const StitchResult({
    required this.equirectPath,
    required this.width,
    required this.height,
    required this.report,
  });

  /// Absolute path to the encoded equirectangular JPEG, XMP GPano already
  /// written (Math §5).
  final String equirectPath;

  /// Output width in pixels; always twice [height].
  final int width;

  /// Output height in pixels.
  final int height;

  /// The measured quality of this stitch.
  final StitchReport report;

  /// Serialises for logs and for the isolate boundary.
  Map<String, Object?> toJson() => {
    'equirect_path': equirectPath,
    'width': width,
    'height': height,
    'report': report.toJson(),
  };

  /// Inverse of [toJson].
  factory StitchResult.fromJson(Map<String, Object?> json) {
    const ctx = 'StitchResult';
    return StitchResult(
      equirectPath: jsonString(json, 'equirect_path', context: ctx),
      width: jsonInt(json, 'width', context: ctx),
      height: jsonInt(json, 'height', context: ctx),
      report: StitchReport.fromJson(jsonObject(json, 'report', context: ctx)),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StitchResult &&
      other.equirectPath == equirectPath &&
      other.width == width &&
      other.height == height &&
      other.report == report;

  @override
  int get hashCode => Object.hash(equirectPath, width, height, report);

  @override
  String toString() =>
      'StitchResult($equirectPath, ${width}x$height, $report)';
}
