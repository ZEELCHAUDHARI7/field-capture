// sv_warnings.h — the closed set of things the pipeline can complain about.
//
// Phase 12 §2 asks for a plain-language sentence per warning, and §5 asks for a
// test that "a new warning cannot ship without a message". Neither is possible
// while a warning is a free-form string built at the site that noticed the
// problem: nothing downstream can enumerate the set, so nothing can prove the set
// is covered. So a warning is a **code** plus the numbers behind it, and the
// sentence a user reads is composed in one place on the Dart side
// (`lib/src/api/models/stitch_warning.dart`), where the copy can be reviewed as
// copy and where a `switch` over the enum makes coverage a compile error.
//
// The technical sentence written here does not go away — it travels as `detail`.
// It is the better message for a bug report, it is what the C++ tests read, and
// it is what a developer replaying a bundle six months later wants. What changes
// is that it is no longer the *only* thing available, and it is no longer what a
// site manager is shown.
//
// Two rules for adding a code:
//
//   1. Add it to `SvWarningCode` and to `svWarningCodeName`. The library is built
//      with `-Werror=switch`, so a code with no name fails the build.
//   2. Add the sentence to the Dart table. `warning_messages_test.dart` reads
//      this header, so a code with no sentence fails the test suite — in Dart,
//      naming the code that is missing.

#ifndef SV_WARNINGS_H
#define SV_WARNINGS_H

#include <string>
#include <vector>

#include "sv_json.h"

namespace sv {

/// Every compromise the pipeline can report, in pipeline order.
///
/// The names are the wire format: they are serialised verbatim into the report's
/// `warnings[].code` and matched against the Dart enum by name, so renaming one
/// is an ABI change and is caught by `warning_messages_test.dart`.
enum class SvWarningCode {
  // ── stage 5, exposure fusion ───────────────────────────────────────────────
  /// Frames oversampled the canvas, so they were decoded smaller (Phase 05 §5).
  kFramesDownscaled,
  /// One bracket could not be fused and fell back to its 0 EV exposure.
  kBracketRefused,
  /// One bracket fused, but with a compromise — a dropped exposure, a
  /// substituted ratio, a ghost-suppressed region.
  kBracketCompromised,
  /// Several brackets fell back, reported once with the count.
  kBracketsRejected,
  /// The exposure ratios the camera reported disagree with what its pixels show.
  kExposureMetadataDisagrees,

  // ── stages 6-9, registration ───────────────────────────────────────────────
  /// No lens distortion model was available, so undistortion was skipped.
  kNoDistortionModel,
  /// An iOS distortion lookup table could not be fitted to a radial model.
  kDistortionLutUnfittable,
  /// No model was published, so the lens was solved from the photographs.
  kDistortionEstimated,
  /// Intrinsics are on the weakest rung R2 describes.
  kWeakIntrinsics,
  /// Some frames had too few inliers and kept their IMU prior.
  kImuOnlyFrames,
  /// Most of the capture is positioned from the IMU alone.
  kMostlyImuOnly,
  /// Nothing registered photometrically at all — the refusal.
  kNothingRegistered,
  /// The match graph split into disconnected components.
  kMatchGraphSplit,
  /// Bundle adjustment did not converge for one component.
  kBundleAdjustmentPartialFailure,
  /// Bundle adjustment converged for no part of the capture.
  kBundleAdjustmentFailed,
  /// S1 over every frame is much worse than S1 over the registered ones.
  kImuOnlyDominatesResidual,
  /// A large share of pairwise inliers was globally inconsistent.
  kInconsistentInliersDiscarded,
  /// BA's refined focal was rejected as the rotation/focal degeneracy.
  kFocalRefinementRejected,
  /// The solved cameras span far less of the sphere than the plan asked for, so
  /// the solution was discarded for the IMU priors.
  kSolutionCollapsed,

  // ── stages 10-15, compositing ──────────────────────────────────────────────
  /// A frame warped entirely off the canvas.
  kFrameWarpedOffCanvas,
  /// No frame reached a wrap pad, so the meridian was composited as a border.
  kWrapPadUnreached,
  /// Exposure compensation threw; the panorama is blended without it.
  kGainCompensationFailed,
  /// Compensation had to move frames further than an AE lock should allow.
  kGainRatioTooLarge,
  /// Graph-cut seam finding threw; the blender feathered the whole overlap.
  kSeamFindingFailed,
  /// Strip blending did not match a full-canvas blend.
  kStripBlendMismatch,
  /// Nothing was covered, so there was no colour to extrapolate into the poles.
  kNothingCovered,
  /// The panorama was written but its preview was not.
  kPreviewNotWritten,
  /// A debug map could not be written.
  kDebugMapNotWritten,

  // ── whole-run ──────────────────────────────────────────────────────────────
  /// The capture plan cannot be registered — refused before stage 5.
  kPlanCannotRegister,
  /// The run stopped after registration, so the photometric criteria are
  /// placeholders rather than measurements.
  kRegistrationOnlyRun,
};

/// One reported compromise: what it was, the numbers behind it, and the
/// technical sentence the detecting site wrote.
struct SvWarning {
  SvWarningCode code = SvWarningCode::kRegistrationOnlyRun;

  /// The technical sentence. Kept for bug reports and for the C++ tests; not
  /// what a site manager is shown.
  std::string detail;

  /// The numbers the Dart sentence interpolates. Keys are snake_case and are
  /// part of the contract with the message table, so a message that reads
  /// `data['frames']` needs the site to have written `frames`.
  Json data = Json::object();
};

/// The wire name of [code]. One `switch`, no default, so `-Werror=switch` makes
/// a missing entry a build failure rather than an empty string in a report.
const char* svWarningCodeName(SvWarningCode code);

/// Appends a warning. A free function rather than a method so the four result
/// structs stay plain data.
void addWarning(std::vector<SvWarning>& warnings,
                SvWarningCode code,
                std::string detail,
                Json data = Json::object());

/// Serialises a warning list into the report's `warnings` array.
Json warningsToJson(const std::vector<SvWarning>& warnings);

}  // namespace sv

#endif  // SV_WARNINGS_H
