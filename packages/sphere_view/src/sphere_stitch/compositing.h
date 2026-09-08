// compositing.h — pipeline stages 10-13 and 15: spherical warp, exposure
// compensation, graph-cut seam finding, multi-band blending in padded strips,
// and encode.
//
// Registration decided whether the panorama *can* be seam-free. This decides
// whether it *looks* seam-free, and it is where the two hard engineering
// problems live: the ±180° wrap seam (Phase 04 §2) and the memory ceiling
// (architecture §7).

#ifndef SV_COMPOSITING_H
#define SV_COMPOSITING_H

#include <functional>
#include <map>
#include <string>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/stitching/detail/seam_finders.hpp>

#include "registration.h"
#include "sphere_stitch.h"

namespace sv {

/// How the overlap between two frames is resolved.
enum class SeamMode {
  /// `GraphCutSeamFinder` with `COST_COLOR_GRAD` (§4). The stage that *hides*
  /// parallax, and the justification for the whole native pipeline.
  kGraphCut,
  /// No seam finder at all: every frame keeps its full warped mask and the
  /// blender feathers across the entire overlap. This is what the old Dart
  /// stitcher did, and it exists so §8's "graph-cut vs feather on parallax_1m"
  /// comparison is an experiment rather than an assertion.
  kFeather,
};

/// Which blender collapses the overlaps.
enum class BlendMode {
  /// `MultiBandBlender`, 5 bands, in padded horizontal strips (§5).
  kMultiBand,
  /// `FeatherBlender`. Only used by the graph-cut-vs-feather comparison.
  kFeather,
};

/// Everything §1-§7 fixes numerically, gathered so a test can move one.
struct CompositingOptions {
  /// Equirect width; height is always `outputWidth / 2`. From the tier table
  /// (architecture §6.5) unless the caller overrides it — `tools/replay`
  /// does, so S6 compares like with like against a ground truth rendered at
  /// its own size.
  int outputWidth = 6144;

  /// Horizontal strips the blender splits the canvas into (§5). Peak memory
  /// drops by roughly this factor with bit-identical output.
  int stripCount = 6;

  /// Duplicated content on each side of the canvas so the ±180° meridian is
  /// interior rather than a border (§2). Cropped off at the end.
  int wrapPadPx = 256;

  /// Multi-band pyramid depth. Zero means "derive it from [outputWidth]", which
  /// is [bandsForWidth] and is what ships.
  ///
  /// §5 specifies 5, and 5 is right *at the size §5 is written about* — the
  /// coarsest level of a 5-band pyramid on an 8192-wide equirect is a /32
  /// reduction, so the blend's widest transition covers about 1.4° of arc. What
  /// matters to the eye is that angle, not the pixel count, so holding the band
  /// count fixed while the canvas shrinks quietly widens the blend: the same 5
  /// bands on the 2048-wide canvas `tools/replay` measures at spread the
  /// transition over 5.6°, four times the intended arc. Measured on `pristine`,
  /// that over-blending costs 4 dB of PSNR against 3 bands — so a fixed 5 would
  /// have the harness scoring a blend the device never performs.
  int numBands = 0;

  /// Vertical padding on each strip, discarded after blending. Zero means
  /// "derive it", which is [stripPadForBands].
  int stripPadPx = 0;

  /// §1: erode each frame's mask by this fraction of its **smaller**
  /// dimension, so a seam is never placed on the outermost ring of pixels
  /// where undistortion, the pinhole model and vignetting are all at their
  /// worst. `coverage_validator` shrinks the frame rectangle by exactly this
  /// before certifying coverage, so the two must stay equal.
  double borderErosionFraction = 0.015;

  /// §4: seam finding runs at `sqrt(this / canvas_area)`. Seam paths do not
  /// need full resolution — the blender feathers across them anyway.
  double seamTargetPixels = 0.1e6;

  SeamMode seamMode = SeamMode::kGraphCut;
  BlendMode blendMode = BlendMode::kMultiBand;

  /// §5: blend a second time on the full canvas and record the largest
  /// absolute difference. Doubles the blend cost and the blend's peak memory,
  /// so it is a test switch, not a shipping one — but §5 is explicit that the
  /// strip equivalence must be *asserted*, not eyeballed.
  bool verifyStripEquivalence = false;

  /// §7: emit a small preview alongside the full file so the UI can show a
  /// result instantly. Set at `high` tier.
  bool emitPreview = false;
  int previewWidth = 2048;

  /// Writes the per-pixel winning-frame and coverage-count maps next to the
  /// output. `tools/replay` needs them: S3 derives seam paths from label
  /// boundaries and S5 counts coverage on the *output* rather than trusting
  /// the plan. Off on device — at `high` tier the label map alone is 134 MB.
  bool emitDebugMaps = false;

  /// Stage 14. Off only for the diagnostic that wants to see the real holes.
  bool fillPoles = true;

  /// Stage 11. Off only to answer "is the compensator helping or hurting?",
  /// which on a profile with no exposure error at all is a real question — a
  /// compensator fed perfect frames should find gains of 1.0 and any deviation
  /// it invents is damage.
  bool compensateExposure = true;

  int jpegQuality = 92;

  /// Absolute path. The extension picks the writer: `.jpg` for the device, or
  /// `.svraw` for raw BGR with a 16-byte header, which is what `tools/replay`
  /// asks for.
  ///
  /// Replay needs a lossless panorama because a JPEG's own quantisation lands
  /// right on top of S6's 42 dB `pristine` target and would be indistinguishable
  /// from a stitching error. It cannot simply ask for a PNG: the pinned OpenCV
  /// build has JPEG and nothing else, deliberately (it keeps zlib out of the
  /// device binary), and PHASE_02 §2 requires replay to run that same build
  /// rather than a more capable one.
  std::string outputPath;

  /// Scratch directory for the warped frames (§5: memory-mapped per strip, not
  /// all held in RAM). Created and removed by the compositor. Empty means
  /// "alongside the output".
  std::string workDir;
};

/// Runs [finder] one overlapping pair at a time, polling `progress->cancel`
/// between pairs, and returns `SV_ERR_CANCELLED` if it is set.
///
/// Exists because `GraphCutSeamFinder::find` is a single call with no poll
/// point, long enough on a device to blow Phase 10 §3's 500 ms cancellation
/// bound on its own. The decomposition reproduces `PairwiseSeamFinder::run`
/// exactly — same pairs, same order, masks carried forward — so the output is
/// bit-identical; the implementation comment gives the argument and
/// `testPairwiseSeamMatchesSingleCall` gives the proof.
///
/// Declared here only so that test can reach it.
/// [slowestPairMs], when given, receives the longest single pair — the number
/// that *is* the stage's cancellation bound.
int32_t findSeamsPairwise(cv::detail::SeamFinder& finder,
                          const std::vector<cv::UMat>& images,
                          const std::vector<cv::Point>& corners,
                          std::vector<cv::UMat>& masks,
                          SvProgress* progress,
                          std::string& error,
                          int* slowestPairMs = nullptr);

/// §5's padding rule: `2^bands · 4`.
int stripPadForBands(int numBands);

/// The band count that gives [outputWidth] the same angular blend width that
/// §5's 5 bands give an 8192-wide equirect: one fewer band per halving.
int bandsForWidth(int outputWidth);

/// Rows per strip for a [canvasHeight] canvas cut into about [stripCount]
/// pieces, rounded **up to a multiple of `2^numBands`**.
///
/// The rounding is what makes §5's bit-identical claim true rather than nearly
/// true. `MultiBandBlender` builds its pyramid on a grid anchored at the ROI's
/// top-left, so level *k* samples rows `roi.y + m·2^k`. A strip whose work
/// rectangle starts at an arbitrary row therefore reduces on a *different* grid
/// from a full-canvas blend, and no amount of padding fixes a phase difference —
/// the two would disagree by a few levels everywhere, not just at the edges.
/// Aligning every strip boundary (and hence, since the pad is itself
/// `2^numBands · 4`, every work rectangle) to the same lattice the full canvas
/// uses leaves border extrapolation as the only difference, and that is what the
/// padding does handle.
int alignedStripHeight(int canvasHeight, int stripCount, int numBands);

/// Everything Phase 04 measures, for `StitchReport`.
struct CompositingResult {
  int canvasWidth = 0;
  int canvasHeight = 0;
  int paddedCanvasWidth = 0;

  /// S4. The spread of the **per-frame** gains the compensator applied:
  /// `max_i median(gain_i) / min_i median(gain_i)`. Above ~1.15 the AE lock is
  /// not holding, which is a Phase 06 bug surfacing here (§3).
  double maxGainRatio = 1.0;

  /// The largest *within* a single frame's gain map. This is the vignetting
  /// the block compensator exists to absorb, and it is reported separately
  /// because confusing it with the number above would blame the camera for the
  /// lens (§3).
  double maxIntraFrameGainRatio = 1.0;

  /// S5, area-weighted, measured on the output and **before** pole filling.
  /// The report has to state how much of the sphere is real photography (§6).
  double coverageFraction = 0.0;
  double doubleCoverageFraction = 0.0;

  /// Area-weighted fraction stage 14 invented.
  double poleFilledFraction = 0.0;

  double seamScale = 1.0;
  int bandsUsed = 0;
  int stripsUsed = 0;
  int stripPadPx = 0;
  int framesWarped = 0;

  /// Tiles the wrap padding added on top of one per frame (§2). Zero means no
  /// frame reached either pad, which on a full sphere means the wrap handling
  /// never engaged and the test that would have caught it is not running.
  int wrapDuplicateTiles = 0;

  /// §5's assertion. `-1` when it was not run; otherwise the largest absolute
  /// per-channel difference between the strip blend and a full-canvas blend,
  /// which must be ≤ 1.
  int stripVsFullMaxAbsDiff = -1;

  /// The slowest single overlapping pair in stage 12, in milliseconds.
  ///
  /// This is Phase 10 §3's cancellation bound, measured rather than argued:
  /// once graph-cut seam finding is decomposed pair by pair, the longest
  /// stretch in which the cancel flag cannot be seen anywhere in the pipeline
  /// is one `findInPair`. Reported so a device run can check the 500 ms claim
  /// instead of inheriting it from a desktop measurement.
  int seamPairMaxMs = 0;

  std::string outputPath;
  std::string previewPath;
  std::string labelMapPath;
  std::string countMapPath;

  std::map<std::string, int> stageMilliseconds;

  /// Running peak RSS in MB, sampled at each stage boundary.
  ///
  /// A high-water mark, so each entry is "the most memory this process had ever
  /// touched by the end of that stage" — which is what makes it useful: the stage
  /// whose number jumps is the stage that set the peak. Criterion S9 is a budget
  /// (< 700 MB at `high`), and a single end-of-run figure says whether it was
  /// missed without saying by what, so it cannot be acted on.
  std::map<std::string, int> stagePeakRssMb;

  std::vector<SvWarning> warnings;
};

/// Runs stages 10-15 over the frames [registration] solved.
///
/// Returns SV_OK, or an SV_ERR_* code with [error] filled. [progress] may be
/// null; when it is not, `cancel` is polled between frames and between strips,
/// because a stage that takes twenty seconds cannot only be cancellable at its
/// boundary.
int compositePanorama(const std::vector<FrameInput>& frames,
                      const Intrinsics& intrinsics,
                      const RegistrationResult& registration,
                      const CompositingOptions& options,
                      SvProgress* progress,
                      CompositingResult& result,
                      std::string& error);

// ─────────────────────────── exposed for the tests ───────────────────────────

/// The equirect rectangle a frame warps onto, in warper coordinates
/// (`u ∈ [−W/2, W/2]`, `v ∈ [0, H]`).
///
/// This is `SphericalWarper::warpRoi` corrected at the poles, and it is exposed
/// because the correction is the fix for a bug that cost 3% of the sphere: stock
/// `detectResultRoi` picks which pole a frame contains from the sign of
/// `±rinv[4]`, which is ≈ 0 for a frame aimed at a pole, so both the zenith and
/// the nadir frame had their ROI extended toward the pole they do *not* contain
/// and their own polar cap was never rendered. A unit test pins the corrected
/// behaviour so it cannot quietly come back.
cv::Rect sphericalWarpRoi(double warpScale, const cv::Mat& k, const cv::Mat& rotation,
                          cv::Size srcSize, int canvasWidth, int canvasHeight);

/// One rectangle of warped content waiting to be blended.
///
/// [fetch] materialises a sub-rectangle on demand rather than the whole tile,
/// which is what lets the shipping path memory-map its warped frames from disk
/// and the unit test hand over two `cv::Mat`s it built in RAM. Both then go
/// through the identical blender, so the strip-equivalence assertion is testing
/// the code that actually runs.
struct BlendTile {
  /// Position on the padded canvas.
  cv::Rect rect;

  /// Fills [bgr] (CV_8UC3) and [mask] (CV_8U) for [sub], which is given in
  /// coordinates relative to [rect]'s top-left.
  std::function<void(const cv::Rect& sub, cv::Mat& bgr, cv::Mat& mask)> fetch;
};

/// §5. Blends [tiles] onto a [canvasSize] canvas in [stripCount] horizontal
/// strips, each inflated by [stripPad] rows that are discarded afterwards.
///
/// `stripCount == 1` with the same padding is a full-canvas blend, which is
/// exactly what the equivalence test compares against — so the two sides of
/// that assertion differ in one integer and nothing else.
///
/// [crop] selects the part of the canvas that is actually written out, and
/// [canvas] comes back that size. The pipeline passes §2's crop window, so the
/// wrap-padded canvas — 107 MB at `high` tier — is never materialised: each strip
/// is blended over the full padded width, because that is what makes the meridian
/// continuous, and then only the kept columns are copied out. An empty [crop]
/// means the whole canvas.
///
/// [blendedMask], when not null, comes back as CV_8U over [crop]: 255 where the
/// blender actually produced a pixel. It is not the same thing as the coverage
/// map, and the difference is what stage 14 has to act on — a pixel can be
/// photographed (a warped mask reaches it) and still come out of the blender with
/// no weight, because the seam masks are what the blender is fed and a nearest-
/// neighbour upscale of a seam-scale cut can leave a sliver assigned to nobody.
/// `Blender::blend` writes black there. Feeding the coverage map to the fill
/// instead leaves those slivers black, which is exactly what `partial`'s exit
/// criterion forbids.
int blendTilesInStrips(const std::vector<BlendTile>& tiles,
                       cv::Size canvasSize,
                       cv::Rect crop,
                       int numBands,
                       int stripCount,
                       int stripPad,
                       BlendMode mode,
                       SvProgress* progress,
                       cv::Mat& canvas,
                       cv::Mat* blendedMask,
                       std::string& error);

}  // namespace sv

#endif  // SV_COMPOSITING_H
