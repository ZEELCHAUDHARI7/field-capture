#include "sv_warnings.h"

namespace sv {

const char* svWarningCodeName(SvWarningCode code) {
  switch (code) {
    case SvWarningCode::kFramesDownscaled:              return "frames_downscaled";
    case SvWarningCode::kBracketRefused:                return "bracket_refused";
    case SvWarningCode::kBracketCompromised:            return "bracket_compromised";
    case SvWarningCode::kBracketsRejected:              return "brackets_rejected";
    case SvWarningCode::kExposureMetadataDisagrees:     return "exposure_metadata_disagrees";
    case SvWarningCode::kNoDistortionModel:             return "no_distortion_model";
    case SvWarningCode::kDistortionLutUnfittable:       return "distortion_lut_unfittable";
    case SvWarningCode::kDistortionEstimated:           return "distortion_estimated";
    case SvWarningCode::kWeakIntrinsics:                return "weak_intrinsics";
    case SvWarningCode::kImuOnlyFrames:                 return "imu_only_frames";
    case SvWarningCode::kMostlyImuOnly:                 return "mostly_imu_only";
    case SvWarningCode::kNothingRegistered:             return "nothing_registered";
    case SvWarningCode::kMatchGraphSplit:               return "match_graph_split";
    case SvWarningCode::kBundleAdjustmentPartialFailure:
      return "bundle_adjustment_partial_failure";
    case SvWarningCode::kBundleAdjustmentFailed:        return "bundle_adjustment_failed";
    case SvWarningCode::kImuOnlyDominatesResidual:      return "imu_only_dominates_residual";
    case SvWarningCode::kFocalRefinementRejected:       return "focal_refinement_rejected";
    case SvWarningCode::kSolutionCollapsed:             return "solution_collapsed";
    case SvWarningCode::kInconsistentInliersDiscarded:
      return "inconsistent_inliers_discarded";
    case SvWarningCode::kFrameWarpedOffCanvas:          return "frame_warped_off_canvas";
    case SvWarningCode::kWrapPadUnreached:              return "wrap_pad_unreached";
    case SvWarningCode::kGainCompensationFailed:        return "gain_compensation_failed";
    case SvWarningCode::kGainRatioTooLarge:             return "gain_ratio_too_large";
    case SvWarningCode::kSeamFindingFailed:             return "seam_finding_failed";
    case SvWarningCode::kStripBlendMismatch:            return "strip_blend_mismatch";
    case SvWarningCode::kNothingCovered:                return "nothing_covered";
    case SvWarningCode::kPreviewNotWritten:             return "preview_not_written";
    case SvWarningCode::kDebugMapNotWritten:            return "debug_map_not_written";
    case SvWarningCode::kPlanCannotRegister:            return "plan_cannot_register";
    case SvWarningCode::kRegistrationOnlyRun:           return "registration_only_run";
  }
  // Unreachable for a value of the enum; present because a cast from an integer
  // is legal C++ and returning garbage from a name lookup is worse than saying
  // so. Dart maps this to its own unrecognised case rather than crashing.
  return "unknown";
}

void addWarning(std::vector<SvWarning>& warnings,
                SvWarningCode code,
                std::string detail,
                Json data) {
  SvWarning warning;
  warning.code = code;
  warning.detail = std::move(detail);
  warning.data = std::move(data);
  warnings.push_back(std::move(warning));
}

Json warningsToJson(const std::vector<SvWarning>& warnings) {
  Json out = Json::array();
  for (const SvWarning& warning : warnings) {
    Json entry = Json::object();
    entry.set("code", Json::string(svWarningCodeName(warning.code)));
    entry.set("detail", Json::string(warning.detail));
    entry.set("data", warning.data);
    out.push(entry);
  }
  return out;
}

}  // namespace sv
