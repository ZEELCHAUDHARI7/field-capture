// registration.h — pipeline stages 6-9: undistort, features, IMU-gated
// matching, bundle adjustment, levelling.
//
// This is the phase that decides whether the panorama can ever be seam-free;
// compositing can only hide what registration leaves behind.

#ifndef SV_REGISTRATION_H
#define SV_REGISTRATION_H

#include <map>
#include <string>
#include <vector>

#include <opencv2/core.hpp>

#include "sphere_stitch.h"
#include "sv_geometry.h"
#include "sv_warnings.h"

namespace sv {

/// One capture position, reduced to what registration needs.
struct FrameInput {
  std::string imagePath;  ///< absolute, already resolved against bundle_dir
  Pose pose;
  int positionIndex = 0;  ///< index into CaptureBundle.positions
  int targetIndex = 0;
};

/// The measured camera model, at full capture resolution.
///
/// Carries [source] rather than just the numbers because R2 established that
/// intrinsics quality is a **gradient, not a constant** — a soft panorama has
/// to be attributable to a weak focal estimate rather than blamed on the
/// stitcher (Phase 03 §2).
struct Intrinsics {
  double fx = 0, fy = 0, cx = 0, cy = 0;
  double width = 0, height = 0;
  std::string source = "derivedFromPhysics";

  /// `null` distortion is the **expected** case on iOS, not an error: R2 found
  /// calibrated intrinsics need a multi-camera device, which excludes base
  /// iPad, Air and mini outright.
  bool hasDistortion = false;

  /// Brown-Conrady, OpenCV order. On the Android path these arrive as a pure
  /// reorder of `LENS_DISTORTION` — `{κ1,κ2,κ4,κ5,κ3}` — with no value
  /// transform (R2, verified against AOSP).
  double k1 = 0, k2 = 0, p1 = 0, p2 = 0, k3 = 0;

  /// iOS radial magnification LUT. Fitted to radial-only coefficients with
  /// `p1 = p2 = 0` forced, because Apple's table gives no basis for tangential
  /// terms and fitting them would be fitting noise.
  bool isLookupTable = false;
  std::vector<double> magnifications;
  double lutCenterX = 0, lutCenterY = 0;

  double hfovRadians() const;
  double vfovRadians() const;
};

/// Stage 6, as a reusable plan.
///
/// The critical part is that undistortion changes the effective camera matrix.
/// Carrying the OLD K forward is a silent ~1% focal error that BA partly
/// absorbs — which masks the bug rather than surfacing it (Phase 03 §2).
///
/// Public because Phase 04 has to rectify the **full-resolution** frames the
/// exact same way registration rectified the downscaled ones. Building the plan
/// twice is cheaper and far safer than caching megabytes of maps between the
/// two phases, and it guarantees one definition of the rectified camera rather
/// than two that can drift.
struct UndistortPlan {
  bool active = false;
  cv::Mat map1, map2;
  cv::Mat newCameraMatrix;
  double fx = 0, fy = 0, cx = 0, cy = 0;
};

/// Builds the stage-6 plan for [intrinsics], appending any compromise it had to
/// make to [warnings]. An inactive plan is the **expected** iOS case, not a
/// failure (R2).
UndistortPlan buildUndistortPlan(const Intrinsics& intrinsics,
                                 std::vector<SvWarning>& warnings);

/// The stage-6 plan for a lens that was **solved from the photographs** rather
/// than published by the device — see `RegistrationOptions::estimateDistortion`.
///
/// Separate from [buildUndistortPlan] because of one deliberate difference: the
/// output camera matrix is the *input* one, unchanged. The estimator corrects
/// feature **coordinates** and leaves the normalisation they were measured in
/// alone, so bundle adjustment solved its focal against the original `fx`/`cx`.
/// Rectifying the pixels to `getOptimalNewCameraMatrix`'s suggestion instead —
/// which is right when the device published the model, because then registration
/// rectified to it too — would hand compositing a camera the solve never saw, and
/// a focal error is not something bundle adjustment absorbs.
///
/// Inactive when both coefficients are zero, which is the "nothing was solved"
/// case and costs a full pass over every frame to say so.
UndistortPlan buildEstimatedUndistortPlan(const Intrinsics& intrinsics,
                                          double k1, double k2);

/// Knobs the phase doc fixes numerically, gathered so a test can move one.
struct RegistrationOptions {
  /// Quarter turns from the DEVICE frame to the CAPTURE frame, i.e. how far the
  /// JPEG's own axes are rolled from the screen's.
  ///
  /// The pose is device-frame and the image is capture-frame; §2's `C = N·D`
  /// assumes they agree, which holds only for a sensor mounted square to the
  /// display. `sv_geometry.cpp` has the derivation and why this is not something
  /// bundle adjustment absorbs. 0 on the synthetic harness, which renders and
  /// records in one frame.
  int captureQuarterTurns = 0;

  /// ~0.6 MP. Every pixel-unit metric is reported at this scale and must be
  /// labelled as such (§3).
  double targetRegistrationPixels = 0.6e6;

  /// Workers for the stage 6/7 decode loop, and for feature detection.
  ///
  /// Bounded rather than "all cores", and the bound is a memory decision rather
  /// than a scheduling one. Each decode worker holds a decoded frame plus its
  /// rectified copy — ~72 MB each at 12 MP — so an unbounded `parallel_for_` on
  /// a 10-core machine would add S9's entire 700 MB budget to the peak in order
  /// to save a few seconds. Four captures most of the win because the stage is
  /// decode-bound rather than compute-bound and saturates well before the core
  /// count.
  ///
  /// Feature detection is bounded for the same reason at one remove: it holds
  /// the registration-scale images (0.6 MP each, so cheap) but SIFT's own
  /// pyramids and descriptor buffers are not, and it runs immediately after the
  /// decode on a device whose memory ceiling is the whole reason the tier table
  /// exists.
  ///
  /// Set to 1 to force the serial path — which is what
  /// `testParallelFeaturesMatchSerial` compares against.
  int decodeThreads = 4;
  int featureThreads = 4;

  /// Lowered from SIFT's 0.04 default specifically for bare concrete and
  /// drywall, the surfaces this product actually points at (§3).
  ///
  /// §3 suggests 0.03 and then says to tune it against the `low_texture`
  /// profile, which is what this value is: measured on that profile, 0.03
  /// leaves all 34 frames unmatchable, while 0.01 registers 11 of them and
  /// connects the graph. Going further to 0.004 gives nothing back (24
  /// unmatched) and costs detection time, so the floor is real rather than
  /// monotonic.
  double siftContrastThreshold = 0.01;

  /// Below BestOf2Nearest's 0.65 default: the IMU gate already supplies the
  /// geometry, so here we want recall and let RANSAC plus BA reject the rest.
  float matchConf = 0.3f;

  /// Generous enough to survive `harsh_imu` at 6° RMS — the gate is on a
  /// prior, not on a measurement (§4).
  double imuSlackRadians = 10.0 * CV_PI / 180.0;

  /// Below this total inlier count a frame cannot be registered
  /// photometrically. It is **not** dropped — it falls back to its IMU prior
  /// and is reported as `imu_only` (§4).
  int minInliers = 25;

  /// Skips stage 9 and keeps the IMU priors verbatim.
  ///
  /// A diagnostic, not a mode anyone should ship: because the synthetic
  /// `pristine` profile records exact poses, running with this on must score
  /// ~0 error against ground truth. That makes it the bisection that separates
  /// "bundle adjustment is wrong" from "everything around it is wrong", which
  /// are otherwise indistinguishable from a single bad number.
  bool skipBundleAdjustment = false;

  /// Solve a shared radial lens (`k1`, `k2`) from the photographs when the device
  /// publishes no model of its own. **Complete and working; off by default on a
  /// cost and a question, not a defect.**
  ///
  /// Undeclared distortion is the largest single error in this pipeline, measured
  /// by ablation rather than argued — `nominal_no_distortion` exists to make it a
  /// number. It is over half of S1, all of the loop-closure failure, and it steals
  /// the focal: a radial error and a focal error look alike to a ray-angle
  /// residual, so the one parameter BA is free to move absorbs the one that is not
  /// in its model. That is why seeding the true focal changes nothing.
  ///
  /// R2 found the fleet mostly publishes nothing, so "no model" is the common case.
  /// But a rotational panorama at ~33% overlap *is* a calibration rig — the same
  /// point is seen by several frames at different radii — so the lens is solvable
  /// from the capture itself, by searching `k1` then refining `(k1, k2)` against
  /// the post-solve residual. The estimate corrects feature coordinates for the
  /// solve and feeds `buildEstimatedUndistortPlan` so compositing warps through the
  /// same lens.
  ///
  /// On `nominal`, with it on:
  ///
  ///     S1     8.81 -> 7.08 px        SSIM  0.567 -> 0.763   (+35%)
  ///     focal  −1.6% -> exact         wrap seam 3.80 -> 3.45
  ///     S2     1.45° -> 6.81°         stitch 9.7 s -> 20.6 s
  ///
  /// It declines cleanly where there is nothing to find: `pristine` and
  /// `low_texture` come back bit-identical to not running it.
  ///
  /// **Why it is still off.** Two reasons, and neither is "it does not work":
  ///
  /// * **Cost.** The search doubles the stitch. S8 budgets 60 s on device and a
  ///   desktop second here is worth roughly four there, so this is the difference
  ///   between comfortably inside the budget and outside it. Capping the search to
  ///   twelve frames brings it back to 9.2 s and destroys the estimate — the
  ///   members of a component are contiguous on the sphere, so a truncation samples
  ///   one part of one ring and a radial term needs spread. Sampling *across* the
  ///   component instead is the obvious next attempt and is not written yet.
  /// * **S2.** Loop closure goes the wrong way, and it is very likely a
  ///   measurement artefact rather than a real step: `s3_wrap`, which measures the
  ///   actual seam at the ±180° meridian in the finished panorama, *improves*
  ///   (3.80 -> 3.45), and a genuine 6.8° failure to close could not do that.
  ///   `harsh_imu` reports 6.799° against `nominal`'s 6.810° — two different
  ///   captures agreeing to three figures is a property of the correction, not of
  ///   the data. The harness has a known gap of exactly this shape in
  ///   `NativeStitcher._rotationsFrom`. Worth settling before trusting the number
  ///   either way.
  ///
  /// So: turning this on trades roughly twice the stitch time for a third more
  /// fidelity, with one metric unexplained. That is a product call, and the
  /// measurements are here to make it with.
  bool estimateDistortion = false;

  /// Above this fraction of `imu_only` frames the result gets a prominent
  /// warning — but it is still produced. It is a reporting threshold, not a
  /// rejection one: an unregisterable *plan* is caught before the pipeline
  /// starts, from the coverage report, because "the plan was too sparse" and
  /// "the wall was blank" need different answers and only the first is worth
  /// refusing over.
  double maxImuOnlyFraction = 0.6;
};

/// Everything §6 requires in `StitchReport`, plus what Phase 04 will need.
struct RegistrationResult {
  double registrationScale = 1.0;

  /// Camera→pano rotations after BA and after §7 levelling.
  std::vector<cv::Matx33d> rotations;

  /// Per frame: registered from imagery, or fell back to the IMU prior.
  std::vector<bool> imuOnly;

  double refinedFocalPx = 0;          ///< at FULL resolution, not registration scale
  double refinedFocalRegPx = 0;       ///< as BA reported it
  double seedFocalRegPx = 0;          ///< what BA started from, registration scale

  /// Whether a component's refined focal was rejected as the rotation/focal
  /// degeneracy and replaced by the seed. Reported so "the field of view came
  /// from the device, not the solver" is visible rather than inferred.
  bool focalRefinementClamped = false;

  /// The shared radial coefficient solved from the photographs, or 0 when the
  /// device published a model of its own (or the search found nothing better
  /// than a pinhole).
  ///
  /// Reported because it is a measurement of the hardware: the same tablet model
  /// should produce the same number across captures, and a fleet's worth of these
  /// is a calibration table nobody had to shoot a checkerboard for.
  double estimatedK1 = 0.0;

  /// The second radial coefficient, solved alongside [estimatedK1].
  double estimatedK2 = 0.0;

  /// Per-frame focal, as BA left it, in registration-scale pixels.
  ///
  /// `BundleAdjusterRay` refines one focal per camera even though the capture
  /// has one lens, and the spread between them is small but real. Phase 04 §1
  /// warps through `cams[i].K()`, so it needs the per-frame value rather than
  /// the mean; frames that never entered BA carry the mean instead of a stale
  /// seed.
  std::vector<double> frameFocalRegPx;
  double rmsReprojectionErrorPx = 0;  ///< S1, at registration scale

  /// The same residual set as [rmsReprojectionErrorPx], summarised two other
  /// ways. RMS alone cannot distinguish a wrong solution from a correct one
  /// carrying a few false correspondences, and those are fixed in different
  /// places, so all three are reported.
  double medianReprojectionErrorPx = 0;
  double p95ReprojectionErrorPx = 0;
  int inlierCount = 0;

  /// The same residual, restricted to frames that registered photometrically.
  ///
  /// S1 above covers every frame, IMU-only ones included, because that is what
  /// a caller reading "RMS 0.3 px" will assume it means. This one separates
  /// "the solver did badly" from "the solver did well on what it could reach" —
  /// when the two diverge, the gap *is* the IMU-only frames.
  double rmsReprojectionRegisteredPx = 0;
  int inlierCountRegistered = 0;

  /// Share of pairwise inliers that disagreed with the global solution badly
  /// enough to be excluded from S1. Reported, never hidden.
  double outlierRejectedFraction = 0;

  /// Architecture §3.3's translation signature: the correlation between a
  /// residual and the log detection scale of the keypoint behind it.
  ///
  /// Near zero for a capture pivoted about the lens; positive for one where the
  /// lens travelled, because parallax disparity goes as `r/d` and detection
  /// scale is a proxy for `1/d`. Always reported, whether or not it crosses the
  /// threshold that raises a warning — it is the only quantity in the report that
  /// speaks to *technique* rather than to the algorithm, and a station-by-station
  /// trend in it says more than any single value.
  double residualScaleCorrelation = 0;

  /// Correspondences removed by the two global consistency gates: the first
  /// against the IMU prior, the second against BA's own solution. Reported
  /// because a large number here means the matcher is aliasing, which is a
  /// property of the scene worth knowing rather than an internal detail.
  /// The camera matrix undistortion produced, before the registration-scale
  /// factor. Reported because `getOptimalNewCameraMatrix` silently changes both
  /// the focal and the principal point, and forgetting to carry the new one is
  /// the ~1% focal error §2 calls out.
  double undistortFx = 0;
  double undistortFy = 0;
  double undistortCx = 0;
  double undistortCy = 0;
  bool undistortActive = false;

  int matchesDroppedByPrior = 0;
  int matchesDroppedBySolution = 0;
  /// S2. Negative means no closed equatorial ring was available to measure,
  /// which is a different statement from "the loop closed perfectly" and must
  /// not be reported as 0.
  double loopClosureErrorDegrees = 0;

  /// How many frames the S2 traverse actually used.
  int loopRingFrames = 0;

  /// Angle between the solution's own up and measured gravity, **before**
  /// levelling. Measured after levelling it is zero by construction.
  double residualTiltDegrees = 0;

  /// How far the levelling rotation turned the panorama.
  double levellingRotationDegrees = 0;

  int candidatePairs = 0;   ///< pairs the IMU gate admitted
  int totalPairs = 0;       ///< n(n-1)/2, for the "we skipped this many" line
  int matchedPairs = 0;     ///< pairs that survived RANSAC
  int imuOnlyCount = 0;
  int componentCount = 1;

  std::vector<int> droppedPositionIndices;
  std::vector<SvWarning> warnings;
  std::map<std::string, int> stageMilliseconds;
};

/// Runs stages 6-9.
///
/// Returns SV_OK, or an SV_ERR_* code with [error] filled. [progress] may be
/// null; when it is not, `cancel` is polled **between frames**, not only
/// between stages — cancellation that only takes effect at a stage boundary is
/// not cancellation when a stage is 20 seconds long.
int registerFrames(const std::vector<FrameInput>& frames,
                   const Intrinsics& intrinsics,
                   const RegistrationOptions& options,
                   SvProgress* progress,
                   RegistrationResult& result,
                   std::string& error);

/// Least-squares fit of `r'/r = 1 + k1·r² + k2·r⁴ + k3·r⁶` to an iOS radial
/// magnification table, with `p1 = p2 = 0` forced (Math §4.2).
///
/// Exposed for unit testing: a fit that silently returns zeros looks exactly
/// like "no distortion", which is the expected iOS state, so the two must be
/// distinguishable by test rather than by inspection.
bool fitRadialFromLut(const std::vector<double>& magnifications,
                      double maxRadiusNormalized,
                      double& k1, double& k2, double& k3);

}  // namespace sv

#endif  // SV_REGISTRATION_H
