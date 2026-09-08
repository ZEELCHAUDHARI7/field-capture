#include "report.h"

#include <opencv2/core/version.hpp>

namespace sv {

Json buildReport(const RegistrationResult& result,
                 const Intrinsics& intrinsics,
                 const std::string& tier,
                 int elapsedMs,
                 const CompositingResult* compositing,
                 const HdrFuseResult* hdr) {
  Json report = Json::object();

  // ---- the criteria this phase actually measures ----------------------------
  report.set("rms_reprojection_error_px", Json::number(result.rmsReprojectionErrorPx));
  report.set("loop_closure_error_degrees", Json::number(result.loopClosureErrorDegrees));
  report.set("residual_tilt_degrees", Json::number(result.residualTiltDegrees));


  // ---- the criteria compositing measures ------------------------------------
  // S4 and S5 belong to Phase 04. When it did not run, emitting 0.0 for a gain
  // ratio would read as flawless and 1.0 for coverage would read as a complete
  // sphere, so both are given values that fail their own targets rather than
  // values that flatter a stage which never executed.
  std::vector<SvWarning> warnings;
  // Stage 5's warnings come first because they come first in the pipeline: a
  // position that fell back to one exposure explains a dark corner three stages
  // before anything else in this list does.
  if (hdr) {
    for (const SvWarning& warning : hdr->warnings) warnings.push_back(warning);
  }
  for (const SvWarning& warning : result.warnings) warnings.push_back(warning);
  if (compositing) {
    report.set("max_gain_ratio", Json::number(compositing->maxGainRatio));
    report.set("coverage_fraction", Json::number(compositing->coverageFraction));
    for (const SvWarning& warning : compositing->warnings) warnings.push_back(warning);
  } else {
    report.set("max_gain_ratio", Json::number(0.0));
    report.set("coverage_fraction", Json::number(0.0));
    addWarning(warnings, SvWarningCode::kRegistrationOnlyRun,
               "This run stopped after registration, so max_gain_ratio and "
               "coverage_fraction are placeholders rather than measurements. They "
               "are deliberately set to values that fail their targets, so a "
               "registration-only run cannot be mistaken for a passing stitch.");
  }

  // Intrinsics as refined by BA, expressed for the ORIGINAL captured image.
  //
  // Bundle adjustment refines the focal of the *rectified* camera, because that
  // is the image it was given. Reporting that number directly would be a subtle
  // lie: a consumer reading `refined_intrinsics` means "the camera that took
  // these photos", and comparing a rectified focal against a real one shows a
  // couple of percent of error that is really just the difference between two
  // coordinate systems. Measured on `nominal_best`, that mismatch made the
  // replay harness report 5.06 px against the native pipeline's 0.295 px —
  // same solution, two different questions.
  //
  // So the refined focal is mapped back through the same ratio undistortion
  // applied, and the distortion model travels with it. `refinedByStitcher` is
  // the provenance the whole IntrinsicsSource gradient exists to record (R2).
  //
  // The stage-5 downscale (Phase 05 §5) adds one more coordinate system to keep
  // straight: registration solved for the *resized* frames, so its focal is in
  // their pixels. `frameScale` undoes that, and `capturedFx` is the same camera
  // expressed in the pixels the solver actually saw — which is what the rectify
  // ratio has to be formed from, or the two corrections would fight.
  const double frameScale = (hdr && hdr->frameScale > 0) ? hdr->frameScale : 1.0;
  const double capturedFx = intrinsics.fx * frameScale;
  const double rectifyRatio =
      (result.undistortActive && result.undistortFx > 0 && capturedFx > 0)
          ? capturedFx / result.undistortFx
          : 1.0;
  const double refinedOriginalFx = result.refinedFocalPx * rectifyRatio / frameScale;

  Json refined = Json::object();
  const double aspect = intrinsics.fx > 0 ? intrinsics.fy / intrinsics.fx : 1.0;
  refined.set("fx", Json::number(refinedOriginalFx));
  refined.set("fy", Json::number(refinedOriginalFx * aspect));
  refined.set("cx", Json::number(intrinsics.cx));
  refined.set("cy", Json::number(intrinsics.cy));
  Json size = Json::object();
  size.set("width", Json::number(intrinsics.width));
  size.set("height", Json::number(intrinsics.height));
  refined.set("image_size", size);
  refined.set("source", Json::string("refinedByStitcher"));

  // The distortion the frames actually carry. Undistortion removed it from the
  // pixels the solver saw, but it is still a property of the camera, and a
  // consumer reprojecting through these intrinsics against original frames
  // needs it.
  if (intrinsics.hasDistortion && !intrinsics.isLookupTable) {
    Json distortion = Json::object();
    distortion.set("type", Json::string("brown_conrady"));
    distortion.set("k1", Json::number(intrinsics.k1));
    distortion.set("k2", Json::number(intrinsics.k2));
    distortion.set("p1", Json::number(intrinsics.p1));
    distortion.set("p2", Json::number(intrinsics.p2));
    distortion.set("k3", Json::number(intrinsics.k3));
    refined.set("distortion", distortion);
  } else {
    refined.set("distortion", Json::null());
  }
  report.set("refined_intrinsics", refined);

  // What the solver started from, beside what it ended at.
  //
  // Reporting only the refined figure made a 3x divergence unreadable: a real
  // capture reported a 9804 px focal — a 23.5 degree field of view on a camera
  // that has about 67 — and nothing in the report said what the device had
  // actually claimed, so there was no way to tell whether the platform had lied
  // or bundle adjustment had run away. Two numbers next to each other answer that
  // immediately, which is the whole reason this is here.
  Json seed = Json::object();
  seed.set("fx", Json::number(intrinsics.fx));
  seed.set("fy", Json::number(intrinsics.fy));
  seed.set("cx", Json::number(intrinsics.cx));
  seed.set("cy", Json::number(intrinsics.cy));
  Json seedSize = Json::object();
  seedSize.set("width", Json::number(intrinsics.width));
  seedSize.set("height", Json::number(intrinsics.height));
  seed.set("image_size", seedSize);
  // The rung the device actually reached, carried through from `bundle.json`
  // rather than invented here — that provenance is the whole point of reporting
  // the seed, and `CameraIntrinsics.fromJson` requires it.
  seed.set("source", Json::string(intrinsics.source));
  report.set("captured_intrinsics", seed);
  report.set("focal_refinement_clamped", Json::boolean(result.focalRefinementClamped));
  report.set("levelling_rotation_degrees",
             Json::number(result.levellingRotationDegrees));

  // The rectified-frame focal is still reported, under its own name, because it
  // is the number that matters when debugging the solver itself.
  report.set("refined_focal_px", Json::number(refinedOriginalFx));
  report.set("refined_focal_rectified_px", Json::number(result.refinedFocalPx));

  Json dropped = Json::array();
  for (int index : result.droppedPositionIndices) dropped.push(Json::integer(index));
  report.set("dropped_position_indices", dropped);

  // `{code, detail, data}` per entry, not a sentence. Phase 12 §2's plain-language
  // message is composed on the Dart side from the code and the data, where a
  // `switch` over the enum makes a missing message a compile error and where the
  // copy can be reviewed as copy. `detail` carries the technical sentence this
  // side wrote, which is still the better line in a bug report.
  report.set("warnings", warningsToJson(warnings));

  report.set("elapsed_ms", Json::integer(elapsedMs));
  report.set("tier_used", Json::string(tier));

  // ---- Phase 05 diagnostics -------------------------------------------------
  // The exit criteria for this stage are "how many brackets fused", "how far did
  // the exposures move", and "how much of the frame was moving" — none of which
  // is derivable from the panorama, and all of which decide whether a dark
  // corner is the scene, the fusion, or the fallback.
  if (hdr) {
    Json block = Json::object();
    block.set("enabled", Json::boolean(hdr->enabled));
    block.set("positions", Json::integer(static_cast<int64_t>(hdr->positions.size())));
    block.set("fused", Json::integer(hdr->fusedCount));
    block.set("passthrough", Json::integer(hdr->passthroughCount));
    block.set("rejected", Json::integer(hdr->rejectedCount));
    block.set("partially_fused", Json::integer(hdr->partiallyFusedCount));
    block.set("aligned_by_ecc", Json::integer(hdr->eccCount));
    block.set("aligned_by_mtb", Json::integer(hdr->mtbCount));
    block.set("max_shift_px", Json::number(hdr->maxShiftPx));
    block.set("mean_ghost_fraction", Json::number(hdr->meanGhostFraction));
    block.set("max_ghost_fraction", Json::number(hdr->maxGhostFraction));
    block.set("max_measured_vs_metadata_stops",
              Json::number(hdr->maxMeasuredVsMetadataStops));
    block.set("frame_scale", Json::number(hdr->frameScale));
    block.set("oversampling", Json::number(hdr->oversampling));
    block.set("downscaled_width", Json::integer(hdr->downscaledWidth));
    block.set("decode_reduction", Json::integer(hdr->decodeReduction));
    block.set("peak_rss_mb", Json::integer(hdr->peakRssMb));

    Json timings = Json::object();
    for (const auto& entry : hdr->stageMilliseconds) {
      timings.set(entry.first, Json::integer(entry.second));
    }
    block.set("stage_ms", timings);

    // Per position, and only for the ones that are not the boring case. A list of
    // 29 identical entries would be noise; the two that fell back are the whole
    // point of recording it.
    Json exceptions = Json::array();
    for (const PositionFuseInfo& info : hdr->positions) {
      if (info.fused && info.shotsUsed == info.shotCount &&
          info.ghostFraction <= 0 && info.maxShiftPx < 1.0) {
        continue;
      }
      Json entry = Json::object();
      entry.set("position", Json::integer(info.positionIndex));
      entry.set("shots", Json::integer(info.shotCount));
      entry.set("shots_used", Json::integer(info.shotsUsed));
      entry.set("fused", Json::boolean(info.fused));
      entry.set("aligner", Json::string(info.aligner));
      entry.set("max_shift_px", Json::number(info.maxShiftPx));
      entry.set("ghost_fraction", Json::number(info.ghostFraction));
      if (!info.reason.empty()) entry.set("reason", Json::string(info.reason));
      exceptions.push(entry);
    }
    block.set("positions_of_note", exceptions);
    report.set("hdr", block);
  }

  // ---- Phase 03 diagnostics -------------------------------------------------
  // Additive: StitchReport.fromJson ignores keys it does not know, so this
  // block can carry whatever the harness needs without touching the Dart model.
  // It exists because "S1 was 0.8 px" is not actionable on its own — whether
  // the gate admitted 70 pairs or 406, and how many frames fell back to their
  // prior, is what tells you which knob moved it.
  Json registration = Json::object();
  registration.set("registration_scale", Json::number(result.registrationScale));
  registration.set("refined_focal_registration_px", Json::number(result.refinedFocalRegPx));
  registration.set("median_reprojection_error_px", Json::number(result.medianReprojectionErrorPx));
  registration.set("p95_reprojection_error_px", Json::number(result.p95ReprojectionErrorPx));
  registration.set("inlier_count", Json::integer(result.inlierCount));
  registration.set("rms_reprojection_registered_px",
                   Json::number(result.rmsReprojectionRegisteredPx));
  registration.set("inlier_count_registered",
                   Json::integer(result.inlierCountRegistered));
  registration.set("outlier_rejected_fraction", Json::number(result.outlierRejectedFraction));
  registration.set("residual_scale_correlation",
                   Json::number(result.residualScaleCorrelation));
  registration.set("loop_ring_frames", Json::integer(result.loopRingFrames));
  registration.set("undistort_active", Json::boolean(result.undistortActive));
  registration.set("undistort_fx", Json::number(result.undistortFx));
  registration.set("undistort_fy", Json::number(result.undistortFy));
  registration.set("undistort_cx", Json::number(result.undistortCx));
  registration.set("undistort_cy", Json::number(result.undistortCy));
  registration.set("matches_dropped_by_prior", Json::integer(result.matchesDroppedByPrior));
  registration.set("matches_dropped_by_solution", Json::integer(result.matchesDroppedBySolution));
  registration.set("candidate_pairs", Json::integer(result.candidatePairs));
  registration.set("total_pairs", Json::integer(result.totalPairs));
  registration.set("matched_pairs", Json::integer(result.matchedPairs));
  registration.set("imu_only_count", Json::integer(result.imuOnlyCount));
  registration.set("component_count", Json::integer(result.componentCount));
  registration.set("intrinsics_source", Json::string(intrinsics.source));
  registration.set("had_distortion_model", Json::boolean(intrinsics.hasDistortion));

  Json imuOnly = Json::array();
  for (size_t i = 0; i < result.imuOnly.size(); ++i) {
    if (result.imuOnly[i]) imuOnly.push(Json::integer(static_cast<int64_t>(i)));
  }
  registration.set("imu_only_frames", imuOnly);

  Json rotations = Json::array();
  for (const cv::Matx33d& r : result.rotations) {
    Json row = Json::array();
    for (int i = 0; i < 3; ++i)
      for (int j = 0; j < 3; ++j) row.push(Json::number(r(i, j)));
    rotations.push(row);
  }
  registration.set("rotations_camera_to_pano", rotations);

  Json timings = Json::object();
  for (const auto& entry : result.stageMilliseconds) {
    timings.set(entry.first, Json::integer(entry.second));
  }
  registration.set("stage_ms", timings);
  registration.set("opencv_version", Json::string(CV_VERSION));

  report.set("registration", registration);

  // ---- Phase 04 diagnostics -------------------------------------------------
  // Same reasoning as the block above: "S3 was 2.4" is not actionable, but
  // "the seam ran at 0.19 scale over 8 strips and the strip blend matched a
  // full-canvas one to 1 level" tells you which of the four stages to look at.
  if (compositing) {
    Json block = Json::object();
    block.set("canvas_width", Json::integer(compositing->canvasWidth));
    block.set("canvas_height", Json::integer(compositing->canvasHeight));
    block.set("padded_canvas_width", Json::integer(compositing->paddedCanvasWidth));
    block.set("frames_warped", Json::integer(compositing->framesWarped));
    block.set("wrap_duplicate_tiles", Json::integer(compositing->wrapDuplicateTiles));
    block.set("seam_scale", Json::number(compositing->seamScale));
    block.set("num_bands", Json::integer(compositing->bandsUsed));
    block.set("strips", Json::integer(compositing->stripsUsed));
    block.set("strip_pad_px", Json::integer(compositing->stripPadPx));
    block.set("strip_vs_full_max_abs_diff",
              Json::integer(compositing->stripVsFullMaxAbsDiff));
    // Phase 10 §3's cancellation bound, measured on this run. The longest
    // stretch anywhere in the pipeline during which the cancel flag is not
    // looked at is one seam pair, so this number is what the 500 ms claim
    // stands on — and it belongs in the report so a device run can check it
    // rather than inherit a desktop figure.
    block.set("seam_pair_max_ms", Json::integer(compositing->seamPairMaxMs));
    block.set("max_intra_frame_gain_ratio",
              Json::number(compositing->maxIntraFrameGainRatio));
    block.set("double_coverage_fraction",
              Json::number(compositing->doubleCoverageFraction));
    block.set("pole_filled_fraction", Json::number(compositing->poleFilledFraction));
    block.set("output_path", Json::string(compositing->outputPath));
    block.set("preview_path", Json::string(compositing->previewPath));
    block.set("label_map_path", Json::string(compositing->labelMapPath));
    block.set("count_map_path", Json::string(compositing->countMapPath));

    Json timings = Json::object();
    for (const auto& entry : compositing->stageMilliseconds) {
      timings.set(entry.first, Json::integer(entry.second));
    }
    block.set("stage_ms", timings);

    Json rss = Json::object();
    for (const auto& entry : compositing->stagePeakRssMb) {
      rss.set(entry.first, Json::integer(entry.second));
    }
    block.set("stage_peak_rss_mb", rss);
    report.set("compositing", block);
  }

  return report;
}

}  // namespace sv
