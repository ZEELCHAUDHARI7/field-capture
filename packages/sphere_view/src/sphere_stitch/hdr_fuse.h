// hdr_fuse.h — pipeline stage 5: collapse each position's exposure bracket into
// one well-exposed LDR frame.
//
// This stage runs **before** registration, so everything downstream sees a
// normal single frame per position and needs no changes (Phase 05 §0). Its
// output is a file path, not a Mat, and that is the whole memory strategy: one
// position is fused at a time, written to disk, and freed (§5). A naive
// full-stack float pipeline is ~430 MB per position at 12 MP, which is most of
// the device budget spent on the cheapest stage in the pipeline.
//
// Why Mertens and not Debevec + a tonemapper is argued in §2: no camera
// response function to calibrate per device model, and LDR output means the rest
// of the pipeline is untouched.

#ifndef SV_HDR_FUSE_H
#define SV_HDR_FUSE_H

#include <map>
#include <string>
#include <vector>

#include <opencv2/core.hpp>

#include "registration.h"
#include "sphere_stitch.h"

namespace sv {

/// One exposure of one bracket, exactly as `ExposureShot` recorded it.
struct ShotInput {
  /// Absolute path, already resolved against `bundle_dir`.
  std::string imagePath;

  /// The bias in stops that was **requested**. Used only to identify the 0 EV
  /// reference and to fall back on when the camera reported nothing else — §4
  /// is explicit that the request is not the measurement.
  double evBias = 0.0;

  /// What the camera says it actually did. Zero means "not reported", which is
  /// a real case on the weaker half of the fleet.
  int64_t exposureTimeNs = 0;
  int iso = 0;

  /// `exposureTimeNs · iso`, i.e. how much light this frame collected relative
  /// to its siblings, or 0 when neither number was reported.
  double lightGathered() const {
    return static_cast<double>(exposureTimeNs) * static_cast<double>(iso);
  }
};

/// One capture position's bracket.
struct PositionShots {
  std::vector<ShotInput> shots;

  /// Index into `CaptureBundle.positions`, for warnings that name the position.
  int positionIndex = 0;
};

/// Which estimator finds the inter-frame shift.
enum class HdrAligner {
  /// Skip alignment entirely. Only for the diagnostic that wants to see what
  /// fringing the alignment was preventing.
  kNone,
  /// `cv::createAlignMTB` — median-threshold bitmaps, integer shifts only.
  kMtb,
  /// `cv::findTransformECC` on gradient magnitude, sub-pixel.
  kEcc,
  /// [kEcc], falling back to [kMtb] for the frames ECC cannot solve.
  ///
  /// **Not** the default, and the measurement is why. Benchmarked on a synthetic
  /// bracket at four known shifts — 0, 3, 8 and a fractional 2.4 px, each across
  /// 3 EV — the search-plus-ECC path is worst-case 0.07 px in 21 ms per pair, and
  /// `AlignMTB` is worst-case 2.2 px in 1.4 ms. On `hdr_interior`, whose bracket is
  /// rendered from one pose so every true shift is zero, MTB's worst false shift
  /// was 89 px against ECC's 1.5 px: a median-threshold bitmap thresholds each
  /// frame at its own median, which is exposure-invariant only when the scene's
  /// brightness is roughly uniform, and an interior with a window at one end is the
  /// opposite of that.
  ///
  /// MTB is thirty times faster, and on a stage with a 45 s budget that buys
  /// nothing worth having. A fallback is worse than no fallback here because it
  /// fires exactly where it should least be believed — the dark frames ECC
  /// declines to solve — and a false shift that lands under §3.2's limit is
  /// applied rather than refused.
  kEccThenMtb,
};

/// Everything §2-§5 fixes numerically, gathered so a test can move one.
struct HdrFuseOptions {
  /// Off means "use the 0 EV shot of each bracket verbatim", which is what the
  /// pipeline did before this stage existed. It is the control group the phase's
  /// second exit criterion is measured against, so it has to stay reachable.
  bool enabled = true;

  /// §2's weights. `exposure_weight` is the one that was measured rather than
  /// assumed, and the measurement moved it.
  ///
  /// §2 sets it to 0 — the well-exposedness term is a Gaussian around mid-grey,
  /// and pulling a 12 EV interior toward mid-grey is exactly the flattening this
  /// stage exists to avoid — and then says: *"if flattening is visible, raise it
  /// to ~0.2, but start at 0 and measure."* So it was measured, on `hdr_interior`,
  /// against the two numbers the phase's exit criteria are about — how much of the
  /// blown-window region is still below the 8-bit rail, and how much local
  /// contrast survives in the region four or more stops down:
  ///
  /// | `exposure_weight` | window headroom | shadow contrast | S1 |
  /// |---|---|---|---|
  /// | 0.0 (§2's value) | 100% | 49% of truth, 4.5% black — **fails** | 31.4 px |
  /// | 0.2 (§2's fallback) | 100% | 86%, 1.9% black | 13.9 px |
  /// | **0.35** | **99.4%** | **83%, 0.2% black** | **7.6 px** |
  /// | 0.5 | 95.0% | 83%, 0.0% black | 7.8 px |
  /// | 1.0 (OpenCV's default) | 82% — **fails** | 90%, 0.0% black | 7.8 px |
  /// | single exposure (control) | 24.9% — **fails** | 65%, 5.4% black — **fails** | 11.6 px |
  ///
  /// The trade is monotone in both directions and it is not the one §2 predicted:
  /// the term does not merely flatten, it is *how the deep shadows become legible
  /// at all*, and past about 0.5 it is also what walks the recovered window back
  /// toward the rail. 0.35 clears both ends with margin and, not coincidentally,
  /// gives the best S1 in the table: a fused frame that is neither railed nor
  /// noise-dominated is also the one the feature matcher can work with. At 0 the
  /// shadows are worse than the single-exposure control they exist to beat, and S1
  /// collapses to 31 px — read noise has excellent local contrast, so with nothing
  /// weighting against it the darkest exposure wins the vote and the matcher is
  /// handed noise.
  ///
  /// `contrast_weight` stays at §2's 1.0. Raising it to 2.0 was tried as the
  /// alternative route to legible shadows — sharpen the per-band winner instead of
  /// biasing toward mid-grey — and it made 40% of the shadow region black while
  /// *raising* the measured contrast, which is the signature of noise winning the
  /// vote rather than detail.
  float contrastWeight = 1.0f;
  float saturationWeight = 1.0f;
  float exposureWeight = 0.35f;

  /// A bounded cross-correlation search for the integer shift, refined to
  /// sub-pixel by ECC. No MTB fallback — see [HdrAligner::kEccThenMtb].
  HdrAligner aligner = HdrAligner::kEcc;

  /// §3.2. Above this fraction of the frame width the shift is not a handheld
  /// wobble any more, and fusing across it produces coloured fringing on every
  /// edge — worse than not bracketing at all. That exposure is then dropped from
  /// the stack, and if nothing alignable is left the 0 EV shot stands alone.
  double maxShiftFraction = 0.015;

  /// Below this, in pixels, an estimated shift is treated as zero and the frame
  /// is not warped at all.
  ///
  /// Not a micro-optimisation: a sub-pixel bilinear warp is a mild low-pass, so
  /// "correcting" a shift smaller than the estimator's own noise floor costs real
  /// sharpness in exchange for nothing. ECC's measured worst-case error on a
  /// bracket that did not move is 1.5 px, and its typical error is well under
  /// half a pixel, which is where this sits.
  double minShiftPx = 0.5;

  /// ECC's stopping rule. 50 iterations at 1e-4 is §3.1's.
  int eccIterations = 50;
  double eccEpsilon = 1e-4;
  int eccGaussianFilterSize = 5;

  /// §3.3. A pixel whose exposure-normalised value disagrees across the stack
  /// by more than this many stops did not sit still, and no fusion can help it.
  bool ghostSuppression = true;
  double ghostThresholdStops = 0.6;

  /// Radius of the feather on the ghost mask, as a fraction of frame width. A
  /// hard mask edge would replace ghosting with a visible outline, which is not
  /// an improvement.
  double ghostFeatherFraction = 0.01;

  /// Below this the pixel is read noise rather than signal, above it the pixel
  /// is clipped; both carry no information about exposure ratios (§4) and are
  /// excluded from the fit, from the ECC mask, and from the ghost test.
  int clipHighLevel = 250;
  int clipLowLevel = 4;

  /// §8.5. Exposure normalisation is linear, so the 8-bit frames are linearised
  /// through `x^2.2` first. Only the normalisation and the ghost test care;
  /// Mertens itself is left to work on the display-referred pixels it expects.
  double displayGamma = 2.2;

  /// §5. Frame resolution beyond what the output canvas can use is waste, and it
  /// is waste in the most expensive stage in the pipeline. A frame is downscaled
  /// only when it oversamples the output by more than this, and then only back
  /// to this — see [oversamplingFor].
  double maxOversampling = 2.0;

  /// Equirect width the panorama will be built at, which is what decides how
  /// much frame resolution is usable. Zero disables the §5 downscale entirely.
  int outputWidth = 0;

  /// Where fused frames are written. They are deleted after the stitch unless
  /// [keepFusedFrames] is set.
  std::string workDir;

  /// Quality of the fused JPEG the rest of the pipeline reads. High, because
  /// this is an intermediate that gets resampled twice more downstream; a
  /// visible artefact introduced here is one nothing later can remove.
  int jpegQuality = 97;

  /// Keep the fused frames on disk for inspection. `tools/hdr_ab.dart` sets it.
  bool keepFusedFrames = false;

  /// How many source frames are decoded at once. §5 wants the JPEG decode
  /// parallelised — it is embarrassingly parallel and otherwise dominates — but
  /// **within** a position, not across them, because holding several positions'
  /// stacks at once is precisely the 430 MB the memory discipline exists to
  /// avoid.
  bool parallelDecode = true;
};

/// What happened to one position.
struct PositionFuseInfo {
  int positionIndex = 0;
  int shotCount = 0;

  /// How many of [shotCount] exposures survived §3.2 and entered the fusion.
  ///
  /// Fewer is not a failure — §6 requires any stack size to work — but it is a
  /// compromise, so it is counted rather than assumed. A 3-shot bracket that
  /// fuses two of its exposures holds less highlight headroom than one that
  /// fuses three, and that is worth knowing when a window comes back white.
  int shotsUsed = 0;

  /// Whether the frame downstream reads is a fusion. False means it is the 0 EV
  /// shot verbatim — either because there was only one shot, or because §3.2
  /// refused the bracket.
  bool fused = false;

  /// True when [outputPath] *is* the input file, so the frame is byte-identical
  /// to what the camera wrote.
  ///
  /// The single-shot path guarantees this **only while [HdrFuseResult::frameScale]
  /// is 1.0**. Once §5's downscale is active, a single exposure is resampled to
  /// that scale and written like a fused frame, because every frame handed to
  /// registration has to be at the scale the report claims — the intrinsics are
  /// corrected by `frameScale` once for the whole capture, so a full-size frame
  /// among downscaled ones is a frame with double the focal it is solved with.
  ///
  /// It also gates deletion: `cleanUpFusedFrames` must never remove a file the
  /// camera wrote, so anything this stage writes itself has to report `false`.
  bool passthrough = false;

  /// Why it was not fused, in plain language. Empty when it was.
  std::string reason;

  /// Largest shift the aligner estimated, in pixels of the source frame.
  double maxShiftPx = 0.0;

  /// Fraction of the frame the ghost mask claimed.
  double ghostFraction = 0.0;

  /// Largest disagreement between the exposure ratio the metadata implies and
  /// the one the pixels imply, in stops. Large means the camera did not deliver
  /// the bracket it was asked for — the R3 failure mode where two frames come
  /// back identical.
  double measuredVsMetadataStops = 0.0;

  /// True when [fuseStack] returned early because the caller set
  /// `SvProgress.cancel`.
  ///
  /// Distinct from the other reasons a stack comes back unfused, and the
  /// distinction is load-bearing: every other one means "use the 0 EV shot and
  /// warn", while this one means "stop the pipeline". Without a separate flag a
  /// cancelled fusion would present as 29 positions that all quietly declined
  /// to fuse, and the user would get a low-dynamic-range panorama they had
  /// asked not to have at all.
  bool cancelled = false;

  /// Which estimator produced the shifts actually used.
  std::string aligner;

  /// The frame the rest of the pipeline reads.
  std::string outputPath;
};

/// Everything the report needs about stage 5.
struct HdrFuseResult {
  bool enabled = true;
  std::vector<PositionFuseInfo> positions;

  int fusedCount = 0;
  int passthroughCount = 0;
  int rejectedCount = 0;

  /// Positions that fused, but with an exposure short of the full bracket (§3.2
  /// per-exposure rejection). Those hold less dynamic range than their
  /// neighbours, which is a thing to know rather than to hide.
  int partiallyFusedCount = 0;

  /// §5's downscale, as a linear factor on the frame's dimensions. 1.0 means the
  /// frames were already inside [HdrFuseOptions::maxOversampling] and were left
  /// alone — which is the only case in which a fused frame keeps the capture's
  /// own intrinsics.
  double frameScale = 1.0;
  int downscaledWidth = 0;

  /// How many halvings [frameScale] represents, which is what the JPEG decoder is
  /// asked for directly. 0 means no downscale.
  int decodeReduction = 0;
  double oversampling = 0.0;

  double maxShiftPx = 0.0;
  double meanGhostFraction = 0.0;
  double maxGhostFraction = 0.0;
  double maxMeasuredVsMetadataStops = 0.0;

  /// How many positions each estimator solved.
  int eccCount = 0;
  int mtbCount = 0;

  std::string fusedDirectory;
  bool keptFusedFrames = false;

  int peakRssMb = 0;
  std::map<std::string, int> stageMilliseconds;
  std::vector<SvWarning> warnings;
};

/// Runs stage 5 over [positions], writing one fused frame per position.
///
/// [intrinsics] is only read for the §5 oversampling decision. [progress] may be
/// null; when it is not, `cancel` is polled **between positions**, because this
/// is the longest stage in the pipeline and a cancel that waits for it is not a
/// cancel.
///
/// Returns SV_OK, or an SV_ERR_* code with [error] filled. A bracket that cannot
/// be fused is **not** an error: it falls back to its 0 EV shot and says so in
/// [HdrFuseResult::warnings]. Only an unreadable frame or an unwritable work
/// directory fails the run.
int fuseBrackets(const std::vector<PositionShots>& positions,
                 const Intrinsics& intrinsics,
                 const HdrFuseOptions& options,
                 SvProgress* progress,
                 HdrFuseResult& result,
                 std::string& error);

/// Deletes the fused frames [result] created, unless it was told to keep them.
void cleanUpFusedFrames(const HdrFuseResult& result);

// ─────────────────────────── exposed for the tests ───────────────────────────

/// Log-luminance of [bgr] as CV_32FC1 — the representation both estimators in
/// [estimateShift] actually run on.
///
/// This is §3.1's requirement, met exactly rather than approximately, and it is
/// the one detail in that section that cannot be skipped: the frames differ by
/// several stops, and an estimator run on raw intensity will happily explain that
/// difference as a translation and return nonsense. On the **log** image an
/// exposure change is a constant offset, which both a correlation coefficient and
/// a cross-power spectrum are invariant to by construction. See the implementation
/// for why this beats the gradient magnitude §3.1 suggests, with the measurement.
///
/// [blurSize] is a Gaussian applied first, in pixels; 0 or 1 disables it.
cv::Mat exposureInvariantImage(const cv::Mat& bgr, int blurSize = 5);

/// One estimated inter-frame translation.
struct ShiftEstimate {
  bool ok = false;

  /// The translation to **apply to the moving frame** to bring it onto the
  /// reference, in pixels.
  ///
  /// Deliberately not an OpenCV warp matrix. `findTransformECC` returns the map
  /// from reference coordinates *into* the moving frame, which has to be applied
  /// with `WARP_INVERSE_MAP` — and §8.3 is right that getting that flag backwards
  /// doubles the misalignment instead of removing it while still looking almost
  /// right. Converting to a plain shift at the point of estimation means the
  /// project has exactly one warp call, with no flag to get backwards, and a test
  /// that pins the sign.
  cv::Point2d shift{0, 0};

  /// Which estimator produced it: "ecc", "mtb", or "none".
  std::string estimator = "none";
};

/// Estimates the shift that brings [moving] onto [reference].
///
/// Both are 8-bit BGR frames of the same size, at different exposures.
ShiftEstimate estimateShift(const cv::Mat& reference, const cv::Mat& moving,
                            const HdrFuseOptions& options);

/// Translates [source] by [shift] with bilinear interpolation, replicating the
/// border. The single warp in this stage.
cv::Mat translateBy(const cv::Mat& source, const cv::Point2d& shift);

/// Fuses one already-loaded stack.
///
/// [shots] describes the stack's exposures and must be the same length as
/// [images]; [baseIndex] is the 0 EV shot. Returns false only when the stack was
/// refused (§3.2) — [info] then says why and [fused] holds a copy of the base
/// shot, so the caller has a usable frame either way.
///
/// Exposed because every one of §7's alignment, rejection and ghosting cases is
/// a statement about this function, and driving it directly is the difference
/// between testing them and testing a bundle loader.
///
/// [progress], when given, is polled between exposures and before the Mertens
/// merge. Phase 10 §3's bound is 500 ms and one 12 MP position measures 841 ms
/// end to end on the desktop host
/// (`testFusionMeetsItsBudgetAtCaptureResolution`), so polling only between
/// positions — which is all §3 asks for — would miss the bound in the longest
/// stage of the pipeline, and the stage a user is most likely to be watching
/// when they change their mind. On cancellation the function returns false with
/// `info.cancelled` set.
bool fuseStack(const std::vector<cv::Mat>& images,
               const std::vector<ShotInput>& shots,
               size_t baseIndex,
               const HdrFuseOptions& options,
               cv::Mat& fused,
               PositionFuseInfo& info,
               SvProgress* progress = nullptr);

/// How much more resolution [intrinsics] carries than an [outputWidth]-wide
/// equirect can represent: frame pixels per degree over canvas pixels per
/// degree. Returns 0 when it cannot be computed.
double oversamplingFor(const Intrinsics& intrinsics, int outputWidth);

}  // namespace sv

#endif  // SV_HDR_FUSE_H
