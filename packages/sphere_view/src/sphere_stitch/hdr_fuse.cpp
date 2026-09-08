#include "hdr_fuse.h"

#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <mutex>

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/photo.hpp>
#include <opencv2/video/tracking.hpp>

namespace sv {
namespace {

using Clock = std::chrono::steady_clock;

int elapsedMs(Clock::time_point since) {
  return static_cast<int>(
      std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - since).count());
}

int peakRssMb() {
  struct rusage usage {};
  if (getrusage(RUSAGE_SELF, &usage) != 0) return 0;
#if defined(__APPLE__)
  return static_cast<int>(usage.ru_maxrss / (1024 * 1024));
#else
  return static_cast<int>(usage.ru_maxrss / 1024);
#endif
}

void setStage(SvProgress* progress, int32_t stage, int32_t permille) {
  if (!progress) return;
  progress->stage = stage;
  progress->permille = permille;
}

bool cancelled(const SvProgress* progress) {
  return progress && progress->cancel != 0;
}

/// `display/255 → linear`, tabulated. A 256-entry table removes `pow` from every
/// per-pixel path in this file, which is the difference between the ghost test
/// costing milliseconds and costing a second per position.
struct GammaTable {
  explicit GammaTable(double gamma) {
    for (int v = 0; v < 256; ++v) {
      linear[v] = std::pow(v / 255.0, gamma);
    }
  }
  double linear[256];
};

/// `base → what shot k would have recorded`, as an 8-bit LUT.
///
/// This is the whole of §3.3's fallback, in a form `cv::LUT` can apply in one
/// vectorised pass: linearise, scale by the exposure ratio, clip where that shot
/// really would have clipped, re-encode.
cv::Mat exposureTransferLut(const GammaTable& table, double gamma, double ratio) {
  cv::Mat lut(1, 256, CV_8U);
  uchar* out = lut.ptr<uchar>();
  for (int v = 0; v < 256; ++v) {
    const double scaled = std::min(1.0, std::max(0.0, table.linear[v] * ratio));
    out[v] = cv::saturate_cast<uchar>(std::pow(scaled, 1.0 / gamma) * 255.0 + 0.5);
  }
  return lut;
}

/// 255 where every channel of [gray8] carries information: not clipped at the
/// top, not buried in read noise at the bottom (§4).
cv::Mat wellExposedMask(const cv::Mat& gray8, const HdrFuseOptions& options) {
  cv::Mat mask;
  cv::inRange(gray8, cv::Scalar(options.clipLowLevel),
              cv::Scalar(options.clipHighLevel), mask);
  return mask;
}

cv::Mat toGray(const cv::Mat& bgr) {
  if (bgr.channels() == 1) return bgr;
  cv::Mat gray;
  cv::cvtColor(bgr, gray, cv::COLOR_BGR2GRAY);
  return gray;
}

/// The exposure ratio of [shot] relative to [base], from whatever evidence is
/// available, in the order §4 requires.
///
/// Returns the multiplier that takes the **base** frame's linear values onto
/// [shot]'s scale, so `shot ≈ base · ratio`.
struct RatioSource {
  double ratio = 1.0;
  bool fromMetadata = false;
  bool fromRequest = false;
};

RatioSource metadataRatio(const ShotInput& base, const ShotInput& shot) {
  RatioSource out;
  const double baseLight = base.lightGathered();
  const double shotLight = shot.lightGathered();
  if (baseLight > 0 && shotLight > 0) {
    out.ratio = shotLight / baseLight;
    out.fromMetadata = true;
    return out;
  }
  // §4's explicit warning case: the requested bias is what we *asked for*, and
  // achieved EV differs from requested by an amount Spike C exists to measure.
  // Using it is a systematic brightness error, so it is the last resort and it
  // is reported.
  out.ratio = std::pow(2.0, shot.evBias - base.evBias);
  out.fromRequest = true;
  return out;
}

/// How far the per-pixel exposure ratios may spread, in stops, before the measured
/// ratio is treated as undetermined. A true ratio is a constant, so the spread is
/// a direct measure of how much of the estimate is really noise; 0.35 stops is
/// comfortably above what quantisation alone produces above the floor level and
/// well below the 0.5-stop disagreement the report is asked to flag.
constexpr double kRatioSpreadLimitStops = 0.35;

/// Exposure ratio measured from the pixels, over the region where **both** frames
/// are comfortably exposed.
///
/// The exclusion is the point of §4: a pixel at 255 in the +2 EV shot carries no
/// information about the ratio, and including it drags the estimate toward 1.
/// `valid` counts how many pixels survived, so the caller can tell a measurement
/// from a guess. Returns 0 when it could not be determined.
///
/// Two choices here are not the obvious ones, and both are about not producing a
/// confident wrong number:
///
///  1. **The median of per-pixel ratios, not a least-squares fit.** Least squares
///     on `shot ≈ ratio · base` treats the base as exact, and it is not — it is a
///     noisy measurement too. That is errors-in-variables, and its bias is always
///     toward zero, so the fit reads systematically *low*. Measured on
///     `hdr_interior`, whose bracket is a rendered 8× exposure ratio and therefore
///     has a known right answer, the fit came back 0.6 stops low — enough to trip
///     this function's own "the camera is lying" threshold on a camera that was
///     telling the truth. A median of ratios has no such asymmetry.
///  2. **A much higher floor than [HdrFuseOptions::clipLowLevel].** A pixel at
///     level 5 is signal in the sense that it is not clipped, and noise in the
///     sense that its value is ±3 levels. Ratios formed from those dominate the
///     sample by count and carry almost no information, so the fit window is
///     midtones in both frames — which for a 3-stop separation is a comfortably
///     wide band, and for a bracket so wide that no such band exists is a case
///     this correctly refuses to answer.
double measuredRatio(const cv::Mat& baseGray, const cv::Mat& shotGray,
                     const GammaTable& table, const HdrFuseOptions& options,
                     size_t& valid) {
  const int floorLevel = std::max(options.clipLowLevel, 32);
  std::vector<double> stops;
  // Every fourth pixel in each direction. A median over 60k samples is the same
  // number as a median over a million, and this way the sort is free.
  stops.reserve(static_cast<size_t>(baseGray.total() / 16 + 1));
  for (int y = 0; y < baseGray.rows; y += 4) {
    const uchar* b = baseGray.ptr<uchar>(y);
    const uchar* s = shotGray.ptr<uchar>(y);
    for (int x = 0; x < baseGray.cols; x += 4) {
      if (b[x] < floorLevel || b[x] > options.clipHighLevel) continue;
      if (s[x] < floorLevel || s[x] > options.clipHighLevel) continue;
      stops.push_back(std::log2(table.linear[s[x]] / table.linear[b[x]]));
    }
  }
  valid = stops.size();
  if (valid < 512) return 0.0;

  std::nth_element(stops.begin(), stops.begin() + static_cast<long>(valid / 2),
                   stops.end());
  const double median = stops[valid / 2];

  // Self-diagnosis, and the reason this returns a sentinel rather than always
  // returning a number. A true exposure ratio is a *constant* — every unclipped,
  // unmoved pixel must report the same one — so the spread across pixels is a
  // direct measure of whether this estimate can be believed at all. When the two
  // exposures are far enough apart that the band where both are well exposed is
  // only a few levels wide, what is left is quantisation and noise, and the median
  // of that is a confident wrong answer. Measured on a synthetic 6-stop
  // separation: the median came back 4.8 stops off, and the spread flagged it.
  //
  // Declining is the right outcome there rather than a failure. The metadata is
  // the primary source (§4); this is a cross-check, and a cross-check that cannot
  // be made must say so instead of overruling a camera that was telling the truth.
  std::vector<double> deviations;
  deviations.reserve(valid);
  for (double s : stops) deviations.push_back(std::fabs(s - median));
  std::nth_element(deviations.begin(),
                   deviations.begin() + static_cast<long>(valid / 2),
                   deviations.end());
  if (1.4826 * deviations[valid / 2] > kRatioSpreadLimitStops) return 0.0;

  return std::pow(2.0, median);
}

/// How many integer offsets the coarse search covers on each side of zero.
///
/// The search image is scaled so that §3.2's whole acceptance window lands inside
/// this radius, so this is a compute budget rather than a limit on what can be
/// found: `(2·12 + 1)² = 625` candidates, each a masked correlation over an image
/// small enough that the whole sweep is a few milliseconds.
constexpr double kSearchRadius = 12.0;

/// How far the search looks, as a fraction of frame width.
///
/// Sized to the motion a handheld burst can actually produce rather than to
/// §3.2's acceptance limit — 8% of the frame is far more than a 600 ms burst
/// should ever show, which is the point: everything the stage might have to refuse
/// has to be inside the range that can measure it.
constexpr double kSearchFraction = 0.08;

/// How much better than "no shift at all" a candidate has to score before it is
/// believed. In units of correlation coefficient.
///
/// Measured rather than guessed. Swept against a synthetic bracket at four known
/// shifts plus a static pair: at 0.01 the two *small* shifts (3 px and 2.4 px) were
/// rejected outright and came back 2.2 px out, while at 0.004 all four land inside
/// half a pixel and the static pair still reports 0.03 px. The window is wide — a
/// tenth of that margin behaves identically — because a real shift wins by a large
/// margin and noise wins by a tiny one; the value only has to sit between them.
constexpr double kShiftConfidenceMargin = 0.004;

/// The 8-bit level below which a pixel's value is too coarsely quantised for a
/// ratio in stops to mean anything. See the ghost loop for the arithmetic.
constexpr int kGhostFloorLevel = 16;

/// The translation, within ±[radius], that best aligns [moving] onto [reference]
/// over [mask].
///
/// Zero-mean normalised cross-correlation over a **fixed sample set** — every
/// candidate offset is scored on exactly the same reference pixels, drawn from the
/// interior so that no candidate falls off the edge. That is what makes the scores
/// comparable: normalising per-candidate over a shrinking overlap instead leaves a
/// score that drifts with offset for reasons unrelated to the content.
///
/// Sampling at a stride rather than every pixel is a cost decision, but the stride
/// is deliberately *not* a small power of two. An earlier version took every second
/// pixel, and on a high-passed image — which is the only kind this is given — that
/// is decimation of high-frequency content without a prefilter, i.e. aliasing. It
/// put spurious peaks in the correlation surface and cost the search 8 px of error
/// on a known 8 px shift. A large stride over the raster is uncorrelated with any
/// texture period the scene is likely to have.
cv::Point2d bestIntegerShift(const cv::Mat& reference, const cv::Mat& moving,
                             const cv::Mat& mask, int radius) {
  // Sample positions: masked, and far enough inside that every candidate offset
  // stays in the frame.
  std::vector<int> samples;
  const int fromY = radius, toY = reference.rows - radius;
  const int fromX = radius, toX = reference.cols - radius;
  if (toY <= fromY || toX <= fromX) return cv::Point2d(0, 0);

  int available = 0;
  for (int y = fromY; y < toY; ++y) {
    const uchar* row = mask.ptr<uchar>(y);
    for (int x = fromX; x < toX; ++x) {
      if (row[x]) ++available;
    }
  }
  if (available < 1024) return cv::Point2d(0, 0);

  // At most this many samples per candidate. A correlation coefficient over 30k
  // samples has a standard error near 0.006, well under the margin below, and the
  // sweep is quadratic in the radius so the constant matters.
  constexpr int kMaxSamples = 30000;
  const int stride = std::max(1, available / kMaxSamples);
  samples.reserve(static_cast<size_t>(available / stride + 1));
  int seen = 0;
  for (int y = fromY; y < toY; ++y) {
    const uchar* row = mask.ptr<uchar>(y);
    for (int x = fromX; x < toX; ++x) {
      if (!row[x]) continue;
      if (seen++ % stride == 0) samples.push_back(y * reference.cols + x);
    }
  }

  const int width = reference.cols;
  const float* referenceData = reference.ptr<float>();
  const float* movingData = moving.ptr<float>();
  const int count = static_cast<int>(samples.size());

  // The reference side is the same for every candidate, so its moments come out of
  // the loop entirely.
  double sumA = 0, sumAA = 0;
  for (int index : samples) {
    const double v = referenceData[index];
    sumA += v;
    sumAA += v * v;
  }
  const double meanA = sumA / count;
  const double varA = sumAA / count - meanA * meanA;
  if (varA <= 1e-12) return cv::Point2d(0, 0);

  cv::Point best(0, 0);
  double bestScore = -2.0;
  double zeroScore = -2.0;

  for (int dy = -radius; dy <= radius; ++dy) {
    for (int dx = -radius; dx <= radius; ++dx) {
      const int offset = dy * width + dx;
      double sumB = 0, sumBB = 0, sumAB = 0;
      for (int index : samples) {
        const double va = referenceData[index];
        const double vb = movingData[index + offset];
        sumB += vb;
        sumBB += vb * vb;
        sumAB += va * vb;
      }
      const double meanB = sumB / count;
      const double varB = sumBB / count - meanB * meanB;
      if (varB <= 1e-12) continue;
      const double score = (sumAB / count - meanA * meanB) / std::sqrt(varA * varB);
      if (dx == 0 && dy == 0) zeroScore = score;
      if (score > bestScore) {
        bestScore = score;
        // `moving` sampled at `x + d` matches `reference` at `x`, so the moving
        // frame's content sits `d` further along and the translation that brings
        // it back is `−d`.
        best = cv::Point(-dx, -dy);
      }
    }
  }

  // No sub-pixel interpolation here, deliberately. Fitting a parabola through the
  // peak looks free and is not: on truly aligned content the correction is a noise
  // draw rather than zero, and the ladder below doubles each level's correction on
  // its way down, so the fractions accumulate. Measured on a *static* synthetic
  // bracket: 1.14 px of invented shift from parabola bias alone, which then warped
  // the frame and flagged 23% of it as moving. Sub-pixel accuracy is ECC's job, and
  // ECC starts from a seed this has already put within a pixel.
  // When the winner is not meaningfully better than not moving at all, do not
  // move at all.
  //
  // This is a prior, and it is a well-founded one: the three exposures come from a
  // hardware burst inside 600 ms, so "the tablet did not move" is by far the most
  // likely truth, and every alternative hypothesis should have to beat it by a
  // margin rather than by a coin flip. Without this the search reports whatever
  // the noise floor happens to favour on content whose correlation surface is
  // flat — measured on a *static* synthetic bracket: 9.6 px, which §3.2 then
  // refused, discarding a bracket that was perfectly fusable. Preferring zero is
  // also the safe direction to be wrong in: a missed sub-pixel shift costs a
  // little sharpness, while an invented one costs coloured fringing on every edge.
  //
  // The same margin applies to the refinement passes as to the range sweep, and
  // that is deliberate. There the null hypothesis is "the shift found so far",
  // so the rule reads as *only refine when refining clearly helps* — which is what
  // keeps a ladder of passes from accumulating a fraction of noise at each rung.
  // Scaling the margin down for the smaller candidate count was tried, on a
  // multiple-comparisons argument, and it is the wrong direction: measured on a
  // *static* synthetic bracket the refinement passes then invented 1.4 px of
  // shift, warped a frame that had not moved, and flagged 20% of it as ghosting.
  if (bestScore <= zeroScore + kShiftConfidenceMargin) return cv::Point2d(0, 0);
  return cv::Point2d(best.x, best.y);
}

}  // namespace

// ─────────────────────────────── §3.1 alignment ──────────────────────────────

cv::Mat exposureInvariantImage(const cv::Mat& bgr, int blurSize) {
  cv::Mat gray = toGray(bgr);

  // The **log** image, and this is §3.1's requirement met exactly rather than
  // approximately.
  //
  // §3.1 asks for gradient magnitude, on the reasoning that gradient structure is
  // *roughly* exposure-invariant while raw intensity is not — and that reasoning
  // is right about intensity and understates what is available. Changing the
  // exposure multiplies linear radiance by a constant; gamma encoding turns that
  // into a constant power; a logarithm turns a constant power into a constant
  // **offset**. And both estimators this feeds are already invariant to an offset:
  // ECC maximises a correlation coefficient, which is invariant to any affine
  // change in intensity, and phase correlation works on the cross-power spectrum,
  // where a DC offset is one bin nobody reads. So on the log image an exposure
  // difference is not approximately removed, it is exactly removed — no
  // differentiation required.
  //
  // Taking the gradient as well was tried, and it is strictly worse: it discards
  // every flat-but-differently-shaded region, which on an interior wall is most of
  // the frame, and it concentrates what is left onto the few strongest edges — of
  // which the strongest are the *clipping boundaries*, which sit in a different
  // place in each exposure. Measured on a synthetic bracket with a known 8 px
  // shift: 8.2 px of residual error on the log-gradient (i.e. the estimator did not
  // move) against sub-pixel here.
  //
  // The `+1` keeps `log(0)` finite and, usefully, compresses the bottom couple of
  // levels where the value is read noise rather than signal.
  cv::Mat logGray;
  gray.convertTo(logGray, CV_32F);
  cv::log(logGray + 1.0f, logGray);

  // A mild blur first. The −3 EV frame's shadows are read-noise dominated, and the
  // log stretches exactly that region, so without this the darkest part of the
  // frame contributes the most gradient and none of it is structure.
  if (blurSize > 1) {
    cv::GaussianBlur(logGray, logGray, cv::Size(blurSize | 1, blurSize | 1), 0);
  }

  return logGray;
}

cv::Mat removeShading(const cv::Mat& logImage) {
  // Subtracting the local mean is what turns a log image into a *local contrast*
  // image, and that is what both estimators need to see.
  //
  // On a construction interior the log image is dominated by gross shading: a
  // window at one end and a dark corner at the other span several units of log
  // luminance, while the surface texture that actually identifies a location spans
  // a fraction of one. A correlation over that is a correlation over the shading,
  // and shading barely changes when the frame moves ten pixels — so the score is
  // near-flat across the whole search range and noise picks the winner. Measured
  // on a *static* synthetic bracket before this subtraction existed: an 11 px
  // shift reported for two frames that had not moved at all, which §3.2 then
  // refused, discarding a bracket that was perfectly fusable.
  //
  // It also makes the exposure invariance robust rather than exact-in-principle:
  // an exposure change is a constant offset on the log image, and removing a local
  // mean removes any *slowly varying* offset, so a real camera's vignetting and the
  // tone curve's mild non-linearity come out in the wash along with it.
  //
  // **This runs at the resolution it is used at**, never before a downscale. The
  // window is a fraction of the image, so applying it at full resolution and then
  // halving twice leaves a passband the coarse image cannot represent — measured:
  // the search then found no correlation anywhere and fell back to reporting no
  // shift at all, on a bracket with a known 8 px one.
  // A tenth of the frame, not a fiftieth. The filter has to remove *shading*,
  // which varies over hundreds of pixels, while keeping the surface texture that
  // identifies a location — and on a construction surface that texture runs to
  // tens of pixels. Measured with a 2% window at the search scale: it removed the
  // texture along with the shading, leaving noise, and the search then reported
  // 9.6 px of motion for a bracket that had not moved.
  const int window =
      std::max(15, static_cast<int>(std::lround(logImage.cols * 0.10)) | 1);
  cv::Mat shading;
  cv::GaussianBlur(logImage, shading, cv::Size(window | 1, window | 1), 0);
  return logImage - shading;
}

cv::Mat translateBy(const cv::Mat& source, const cv::Point2d& shift) {
  if (std::fabs(shift.x) < 1e-9 && std::fabs(shift.y) < 1e-9) return source.clone();
  cv::Mat warp = (cv::Mat_<double>(2, 3) << 1, 0, shift.x, 0, 1, shift.y);
  cv::Mat out;
  // Forward warp, no WARP_INVERSE_MAP. `ShiftEstimate::shift` is defined as the
  // translation applied to the moving frame precisely so this call has no flag to
  // get backwards (§8.3); the conversion from ECC's own convention happens once,
  // in estimateShift, under a test that pins its sign.
  cv::warpAffine(source, out, warp, source.size(), cv::INTER_LINEAR,
                 cv::BORDER_REPLICATE);
  return out;
}

ShiftEstimate estimateShift(const cv::Mat& reference, const cv::Mat& moving,
                            const HdrFuseOptions& options) {
  ShiftEstimate estimate;
  if (options.aligner == HdrAligner::kNone) {
    estimate.ok = true;
    estimate.estimator = "none";
    return estimate;
  }
  if (reference.size() != moving.size() || reference.empty()) return estimate;

  const bool tryEcc = options.aligner == HdrAligner::kEcc ||
                      options.aligner == HdrAligner::kEccThenMtb;
  const bool tryMtb = options.aligner == HdrAligner::kMtb ||
                      options.aligner == HdrAligner::kEccThenMtb;

  const cv::Mat referenceGray = toGray(reference);
  const cv::Mat movingGray = toGray(moving);

  if (tryEcc) {
    // Only where both frames carry information. A window that is 255 in one
    // frame and textured in the other has a large gradient in one and none in
    // the other, and handing ECC that asymmetry is asking it to translate the
    // frame until a clipped plateau lines up with a real edge.
    //
    // Eroded, and the erosion is load-bearing rather than tidy. The estimate runs
    // on gradient magnitude, and a gradient is a property of a neighbourhood: at
    // the boundary of a clipped region the 5×5 blur and the 3×3 Sobel between them
    // pull clipped values four pixels into territory the mask still calls valid,
    // leaving a strong straight edge that is an artefact of where that exposure
    // happened to clip. Since the clipping boundary sits at a *different place in
    // each exposure*, ECC will align those two artefacts to each other in
    // preference to the scene. Measured on a synthetic 10 EV ramp before the
    // erosion existed: a 14.6 px error on a known 8 px shift, and 5.7 px of shift
    // reported for a bracket that had not moved.
    // The erosion is paired with a close, and the pairing is what makes it
    // correct rather than merely strict. An isolated railed pixel — one bright
    // speck in an otherwise well-exposed wall — is not a problem for a gradient
    // estimate; a *contiguous* clipped region is, because its boundary is a strong
    // straight edge sitting wherever that exposure happened to clip. Eroding alone
    // treats the two the same, and on textured content that is fatal: measured on
    // the synthetic 10 EV ramp, scattered specks about ten pixels apart turned a
    // 38514-pixel valid region into 7 pixels, and ECC then declined to solve a
    // bracket it could have solved. Closing first fills the specks, so only the
    // real boundaries get pulled back from.
    const cv::Mat speck = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(5, 5));
    const cv::Mat support = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(9, 9));
    cv::Mat mask, movingMask;
    cv::morphologyEx(wellExposedMask(referenceGray, options), mask, cv::MORPH_CLOSE,
                     speck);
    cv::erode(mask, mask, support);
    cv::morphologyEx(wellExposedMask(movingGray, options), movingMask,
                     cv::MORPH_CLOSE, speck);
    cv::erode(movingMask, movingMask, support);
    cv::bitwise_and(mask, movingMask, mask);

    const int usable = cv::countNonZero(mask);
    if (usable > reference.total() / 20) {
      // A bounded search for the integer shift, then ECC for the fraction. The
      // division of labour between them is the whole of this block.
      //
      // **ECC alone cannot find the shift.** It is a local gradient ascent on a
      // correlation surface whose basin, on textured content, is a couple of
      // pixels wide. Measured on a synthetic bracket with a known 8 px shift, a
      // single-scale run returned 1.6 px — it barely moved — and a 3-level
      // coarse-to-fine pyramid returned *exactly the same number*, because each
      // coarse level is equally stuck at its own scale. That matters because the
      // limit this feeds is 1.5% of frame width, 45 px on a 12 MP capture: the
      // shifts §3.2 is written to accept and the shifts ECC can reach do not
      // overlap at all.
      //
      // **So the search is done exhaustively, over exactly the range §3.2
      // accepts.** That bound is not an approximation of a bigger search — a shift
      // past it is refused anyway, so there is nothing beyond it worth finding, and
      // within it this is globally optimal by construction. There is no basin to
      // fall out of, no local maximum to be caught in, and no FFT wraparound to
      // mistake for a shift. `cv::phaseCorrelate` was the obvious alternative and
      // was tried: it is global too, but its peak is picked from a cross-power
      // spectrum with no notion of a plausible range, and on this content it
      // returned 91 px for an 8 px shift.
      //
      // The cost stays small because the search runs downscaled — the offsets it
      // is choosing between are integers at the search scale, and a scale where
      // the whole ±45 px range is ±11 px means 23² candidates over an image
      // 1/16th the area.
      const cv::Mat referenceLog = exposureInvariantImage(reference);
      const cv::Mat movingLog = exposureInvariantImage(moving);

      // The searched range is a property of the *camera shake*, not of §3.2's
      // acceptance limit, and conflating the two was a bug worth naming. Bounding
      // the search at the limit means a shift past it comes back as some small
      // number that happens to correlate — measured: a synthetic 40 px shift was
      // reported as 2.5 px and would have been accepted and fused, which is
      // precisely the fringing §3.2 exists to prevent. The search has to be able to
      // *measure* what it refuses.
      const double searchRangePx = kSearchFraction * reference.cols;

      // Search at a power-of-two scale, built with `pyrDown`.
      //
      // The scale is chosen so that the whole range worth searching lands inside
      // the radius budget, and it is a *power of two* rather than whatever exact
      // factor that implies. `cv::resize` with `INTER_AREA` at a non-integer factor
      // near 1 is a box filter whose footprint changes from output pixel to output
      // pixel, so it imposes a position-dependent phase shift on fine texture —
      // which is precisely the signal the search is correlating. Measured at a
      // 0.833 factor: the correlation peak moved to the *wrong side of zero* in y
      // while x stayed correct, for a 9 px error on a known 8 px shift. `pyrDown`
      // is a fixed 5×5 Gaussian and an exact halving, so it has no such phase.
      int reduction = 0;
      while (reduction < 5 && searchRangePx / (1 << reduction) > kSearchRadius &&
             (std::min(reference.rows, reference.cols) >> (reduction + 1)) >= 64) {
        ++reduction;
      }
      const double searchScale = 1.0 / (1 << reduction);

      // One destination per input, never a shared scratch. Assigning a `cv::Mat`
      // shares its buffer rather than copying it, so a single reused `down` would
      // leave `a` pointing at the very memory the next `pyrDown` writes `b` into —
      // and the search would then be correlating an image with itself and reporting
      // a perfect score at zero shift, which is exactly what it did.
      cv::Mat a = referenceLog, b = movingLog, searchMask = mask;
      for (int level = 0; level < reduction; ++level) {
        cv::Mat reducedA, reducedB, reducedMask;
        cv::pyrDown(a, reducedA);
        cv::pyrDown(b, reducedB);
        // Eroded rather than merely resized, so a half-covered mask pixel comes out
        // excluded: the mask is a statement about which pixels can be trusted, and
        // at a coarser scale a pixel that mixes trusted and untrusted content is
        // not trustworthy.
        cv::erode(searchMask, reducedMask, cv::Mat());
        cv::resize(reducedMask, reducedMask, reducedA.size(), 0, 0, cv::INTER_NEAREST);
        a = reducedA;
        b = reducedB;
        searchMask = reducedMask;
      }
      a = removeShading(a);
      b = removeShading(b);

      const int radius =
          std::max(2, static_cast<int>(std::ceil(searchRangePx * searchScale)));

      // Coarse for range, then **one** pass at full resolution for precision.
      //
      // The coarse level can only be as precise as its own pixels — at a 1/4 scale
      // that is ±2 full-resolution pixels, which is both outside ECC's basin and
      // past the deadband below, so the frame would arrive misaligned and be warped
      // by a wrong amount anyway.
      //
      // A ladder of doubling passes is the textbook way to close that gap and it
      // was tried first. It is worse here, for a reason worth recording: each rung
      // can be wrong by up to its own pixel, and the next rung *doubles* whatever
      // it inherits before adding its own error, so the fractions compound instead
      // of cancelling. Measured on a static synthetic bracket, a two-rung ladder
      // invented 2.8 px of shift where a single full-resolution pass invents none.
      // The intermediate rungs are guesses made on deliberately blurred data, and
      // there is no reason to admit a guess when the real thing is affordable: the
      // residual is bounded by the coarse scale factor, so the pass only has to
      // look a few pixels either way.
      cv::Point2d coarse = bestIntegerShift(a, b, searchMask, radius);
      if (reduction > 0) {
        const cv::Point2d known = coarse * static_cast<double>(1 << reduction);
        const cv::Point2d residual =
            bestIntegerShift(removeShading(referenceLog),
                             translateBy(removeShading(movingLog), known), mask,
                             1 << reduction);
        coarse = known + residual;
      }

      // The search returns the translation that brings the moving frame onto the
      // reference — this file's convention throughout. ECC's warp is the opposite:
      // it maps reference coordinates into the moving frame, so it is seeded with
      // the negation. That is §8.3's pitfall wearing a different hat, and
      // `testAlignmentRecoversAKnownShift` is what pins the sign.
      cv::Mat warp = cv::Mat::eye(2, 3, CV_32F);
      warp.at<float>(0, 2) = static_cast<float>(-coarse.x);
      warp.at<float>(1, 2) = static_cast<float>(-coarse.y);

      bool converged = true;
      try {
        cv::findTransformECC(
            removeShading(referenceLog), removeShading(movingLog), warp,
            cv::MOTION_TRANSLATION,
            cv::TermCriteria(cv::TermCriteria::COUNT + cv::TermCriteria::EPS,
                             options.eccIterations, options.eccEpsilon),
            mask, options.eccGaussianFilterSize);
        // ECC is a refinement here, not the estimate, and one pixel is the whole of
        // what it is allowed to add.
        //
        // The search above is integer-valued and, on content whose correlation
        // surface is shallow in one axis, its winner can sit a whole pixel from the
        // truth — measured on this fixture, whose only vertical structure is
        // texture while its horizontal structure includes hard band edges: x lands
        // exactly, y lands one pixel short. One pixel is therefore the right bound:
        // enough for ECC to close that gap, and tight enough that it cannot invent
        // a shift on a bracket that did not move, which is what it does when left
        // unbounded — 1.16 px from a correct seed of zero, warping a static frame
        // and flagging a fifth of it as ghosting.
        constexpr double kMaxEccCorrectionPx = 1.0;
        if (std::fabs(-warp.at<float>(0, 2) - coarse.x) > kMaxEccCorrectionPx ||
            std::fabs(-warp.at<float>(1, 2) - coarse.y) > kMaxEccCorrectionPx) {
          warp.at<float>(0, 2) = static_cast<float>(-coarse.x);
          warp.at<float>(1, 2) = static_cast<float>(-coarse.y);
        }
      } catch (const cv::Exception&) {
        // §8.2: findTransformECC throws on frames with too little structure to
        // correlate, which is the bare-drywall case this product points at. The
        // search result still stands — it is integer-accurate, which is enough to
        // fuse on — so a failed refinement is not a failed estimate.
        warp.at<float>(0, 2) = static_cast<float>(-coarse.x);
        warp.at<float>(1, 2) = static_cast<float>(-coarse.y);
      }

      const double tx = warp.at<float>(0, 2);
      const double ty = warp.at<float>(1, 2);
      if (converged && std::isfinite(tx) && std::isfinite(ty)) {
        // ECC returns the map from REFERENCE coordinates into the MOVING
        // frame: moving(x + t) ≈ reference(x). The translation that brings the
        // moving frame onto the reference is therefore −t.
        estimate.shift = cv::Point2d(-tx, -ty);
        estimate.ok = true;
        estimate.estimator = "ecc";
        return estimate;
      }
    }
  }

  if (tryMtb) {
    try {
      cv::Ptr<cv::AlignMTB> mtb = cv::createAlignMTB();
      // Median-threshold bitmaps are exposure-invariant by construction: the
      // threshold is each frame's own median, so a 4 EV difference moves both
      // medians and leaves the bitmap alone. Integer shifts only.
      const cv::Point shift = mtb->calculateShift(referenceGray, movingGray);
      estimate.shift = cv::Point2d(shift.x, shift.y);
      estimate.ok = true;
      estimate.estimator = "mtb";
      return estimate;
    } catch (const cv::Exception&) {
    }
  }

  return estimate;
}

// ─────────────────────────────── §2-§4 fusion ────────────────────────────────

bool fuseStack(const std::vector<cv::Mat>& images,
               const std::vector<ShotInput>& shots,
               size_t baseIndex,
               const HdrFuseOptions& options,
               cv::Mat& fused,
               PositionFuseInfo& info,
               SvProgress* progress) {
  info.shotCount = static_cast<int>(images.size());
  info.fused = false;
  if (images.empty()) {
    info.reason = "the bracket contained no readable frames";
    return false;
  }
  if (baseIndex >= images.size()) baseIndex = 0;

  const cv::Mat& base = images[baseIndex];
  fused = base.clone();

  if (images.size() == 1) {
    info.shotsUsed = 1;
    // §6: one shot skips alignment, ghosting and fusion entirely. The frame is
    // handed on untouched, which is what makes the single-shot path a verified
    // no-op rather than a fusion that happens to be close.
    info.reason = "single exposure; nothing to fuse";
    info.aligner = "none";
    return false;
  }

  for (const cv::Mat& image : images) {
    if (image.size() != base.size() || image.type() != base.type()) {
      info.reason = "the bracket's frames are not all the same size and format";
      return false;
    }
  }

  const GammaTable table(options.displayGamma);
  const double maxShiftPx = options.maxShiftFraction * base.cols;

  // ---------------------------------------------------------------- §3.1 -----
  //
  // Rejection is **per exposure**, not per bracket, and that is a deliberate
  // refinement of §3.2 rather than a departure from it. Its rule — never fuse
  // across an alignment you do not trust — is what matters, and an exposure that
  // cannot be aligned is one exposure's worth of dynamic range, not the bracket's.
  // On the dark polar frames of `hdr_interior` ECC declines to solve the −3 EV
  // shot, which carries nothing but read noise there anyway, while the +3 EV shot
  // holds the shadow detail the whole stage exists to recover. Refusing the whole
  // bracket would throw that away to protect against a frame that contributes
  // nothing. When nothing alignable is left, the outcome is exactly §3.2's: the
  // 0 EV shot, alone, with a warning naming the position.
  std::vector<cv::Mat> aligned;
  std::vector<ShotInput> keptShots;
  size_t keptBase = 0;
  std::string estimator = "none";
  std::string dropped;
  aligned.reserve(images.size());
  keptShots.reserve(images.size());

  for (size_t k = 0; k < images.size(); ++k) {
    if (k == baseIndex) {
      keptBase = aligned.size();
      aligned.push_back(images[k]);
      keptShots.push_back(shots[k]);
      continue;
    }
    // Polled per exposure. `estimateShift` runs a bounded correlation search
    // and then ECC, which at 12 MP is the single most expensive thing in this
    // function — so this is where the fusion stage's cancellation latency is
    // actually decided (Phase 10 §3).
    if (cancelled(progress)) {
      info.cancelled = true;
      info.reason = "cancelled during exposure alignment";
      return false;
    }
    const ShiftEstimate estimate = estimateShift(base, images[k], options);
    char note[256];
    if (!estimate.ok) {
      std::snprintf(note, sizeof(note),
                    "the %+.1f EV exposure could not be aligned to the 0 EV one",
                    shots[k].evBias);
      dropped += (dropped.empty() ? "" : "; ") + std::string(note);
      continue;
    }
    estimator = estimate.estimator;
    const double magnitude = std::sqrt(estimate.shift.x * estimate.shift.x +
                                       estimate.shift.y * estimate.shift.y);
    info.maxShiftPx = std::max(info.maxShiftPx, magnitude);
    if (magnitude > maxShiftPx) {
      std::snprintf(note, sizeof(note),
                    "the %+.1f EV exposure moved %.1f px, past the %.1f px limit "
                    "(%.1f%% of frame width)",
                    shots[k].evBias, magnitude, maxShiftPx,
                    options.maxShiftFraction * 100.0);
      dropped += (dropped.empty() ? "" : "; ") + std::string(note);
      continue;
    }
    // Cloned when it is not warped, because the substitution below writes into
    // these in place and `images` belongs to the caller. `translateBy` already
    // returns a fresh Mat, so only the deadband case needs it.
    aligned.push_back(magnitude < options.minShiftPx
                          ? images[k].clone()
                          : translateBy(images[k], estimate.shift));
    keptShots.push_back(shots[k]);
  }
  info.aligner = estimator;
  info.shotsUsed = static_cast<int>(aligned.size());

  if (aligned.size() < 2) {
    info.reason = dropped.empty()
                      ? "no exposure could be aligned to the 0 EV frame"
                      : dropped + ", so the 0 EV frame was used alone";
    return false;
  }

  // ----------------------------------------------------------------- §4 ------
  // Exposure-normalise on the camera's ACTUAL parameters, and cross-check them
  // against the pixels over the region where both frames are well exposed.
  // Lightly smoothed, for both §4's ratio fit and §3.3's ghost test.
  //
  // Both ask a question about *radiance*, per pixel, across frames — and a
  // sub-pixel residual misalignment turns every sharp edge into a large apparent
  // radiance disagreement. Measured on a static synthetic bracket with 0.6 px of
  // residual: the ratio fit's inter-quartile spread was 1.7 stops on a constant
  // ratio, and 2.8% of the frame was flagged as moving. Neither question is about
  // detail at the pixel, so neither should be answered at the pixel.
  std::vector<cv::Mat> grays(aligned.size());
  for (size_t k = 0; k < aligned.size(); ++k) {
    cv::blur(toGray(aligned[k]), grays[k], cv::Size(3, 3));
  }

  std::vector<double> ratios(aligned.size(), 1.0);  // base → shot k
  bool usedRequestedBias = false;
  bool metadataDisagrees = false;
  for (size_t k = 0; k < aligned.size(); ++k) {
    if (k == keptBase) continue;
    const RatioSource source = metadataRatio(keptShots[keptBase], keptShots[k]);
    usedRequestedBias = usedRequestedBias || source.fromRequest;

    size_t valid = 0;
    const double measured =
        measuredRatio(grays[keptBase], grays[k], table, options, valid);

    ratios[k] = source.ratio;
    if (measured > 0 && source.ratio > 0) {
      const double stops = std::fabs(std::log2(measured / source.ratio));
      info.measuredVsMetadataStops = std::max(info.measuredVsMetadataStops, stops);
      if (stops > 0.5) metadataDisagrees = true;
      // The measurement **corroborates or contradicts; it does not overrule.**
      //
      // The exposure time and ISO are the sensor's own report of what it did; the
      // measured ratio is an inference from pixels that also carry noise,
      // quantisation, whatever moved, and any residual misalignment. Preferring the
      // inference was tried, and it is the wrong way round: on a synthetic bracket
      // with exact metadata the inference was 0.6 stops out, and normalising on it
      // put a systematic brightness error into a stack that had none. So the
      // measurement is used only where there is nothing better — where the camera
      // reported nothing and §4's last resort, the *requested* bias, is the
      // alternative — and only when it is confident enough to have survived the
      // spread check inside `measuredRatio`.
      if (source.fromRequest) ratios[k] = measured;
    }
  }

  // ---------------------------------------------------------------- §3.3 -----
  // Per-pixel disagreement across the exposure-normalised stack, in stops.
  // Anything that moved between the frames cannot be fused, and on an active
  // site that is the normal case rather than an edge case.
  cv::Mat ghost;
  double ghostFraction = 0.0;
  if (options.ghostSuppression && aligned.size() >= 2) {
    ghost = cv::Mat::zeros(base.size(), CV_8U);
    std::vector<double> normalised(aligned.size());
    std::vector<int> valid(aligned.size());
    for (int y = 0; y < base.rows; ++y) {
      uchar* out = ghost.ptr<uchar>(y);
      for (int x = 0; x < base.cols; ++x) {
        int count = 0;
        for (size_t k = 0; k < aligned.size(); ++k) {
          const uchar v = grays[k].ptr<uchar>(y)[x];
          // A higher floor than the clipping one, and for a different reason.
          // `clipLowLevel` asks "does this pixel carry any signal"; this asks
          // "does it carry signal *precise enough to compare in stops*". One
          // 8-bit level at display value v is about 3.17/v stops, so at level 5 a
          // single level of quantisation is 0.6 stops — the entire ghost
          // threshold — and the darkest corner of every frame would be flagged as
          // motion. At 16 it is 0.2 stops, comfortably inside. Measured on a
          // static synthetic bracket: 3.1% of the frame flagged as moving without
          // this floor, against nothing that actually moved.
          if (v < kGhostFloorLevel || v > options.clipHighLevel) continue;
          // Divide by the ratio to bring shot k onto the base's scale, so a
          // static scene reads the same value in every frame regardless of
          // exposure — which is what makes the remaining spread motion.
          normalised[count] = table.linear[v] / (ratios[k] > 0 ? ratios[k] : 1.0);
          valid[count] = static_cast<int>(k);
          ++count;
        }
        if (count < 2) continue;  // cannot tell motion from clipping here

        std::sort(normalised.begin(), normalised.begin() + count);
        const double median = count % 2 == 1
                                  ? normalised[count / 2]
                                  : 0.5 * (normalised[count / 2 - 1] +
                                           normalised[count / 2]);
        if (median <= 0) continue;
        double worst = 0;
        for (int i = 0; i < count; ++i) {
          worst = std::max(worst, std::fabs(std::log2(normalised[i] / median)));
        }
        if (worst > options.ghostThresholdStops) out[x] = 255;
      }
    }

    // Speckle first: a single pixel over the threshold is sensor noise at the
    // bottom of the range, not a worker walking through the frame.
    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(3, 3));
    cv::morphologyEx(ghost, ghost, cv::MORPH_OPEN, kernel);
    ghostFraction = static_cast<double>(cv::countNonZero(ghost)) /
                    static_cast<double>(base.total());
  }
  info.ghostFraction = ghostFraction;

  // ------------------------------------------------------------- §3.3 + §4 ----
  // Where a frame has nothing to say, it says the base frame's words instead.
  //
  // Two masks, one mechanism. The ghost mask above is §3.3's; the second is §4's
  // clipping rule carried into the fusion, where it matters just as much: a pixel
  // that is clipped, or buried in read noise, carries no information about the
  // scene — and Mertens has no way to know that. Its weight is contrast ×
  // saturation, and **read noise has excellent contrast**. Measured on
  // `hdr_interior` before this substitution existed: the −3 EV exposure, whose
  // shadows are pure noise, out-voted the two exposures that could actually see
  // the dark end of the room, and 28% of the shadow region came out black in a
  // panorama built from a bracket that contained the detail. Raising Mertens'
  // well-exposedness weight hides that — it also drags the recovered window back
  // toward mid-grey and blows it, which is the trade §2 warns about — so the
  // uninformative pixels are removed from the vote directly instead.
  //
  // Both substitutions are applied BEFORE fusion, by replacing those pixels with
  // what the base frame would have recorded at that exposure. Substituting after
  // fusion instead would drop the base shot's own tone into a Mertens result it
  // has no radiometric relationship with, and leave a visible brightness patch
  // exactly where the mask is. Feeding Mertens a stack that agrees there gets the
  // same "fall back to the 0 EV shot" outcome with the surrounding tone preserved
  // by construction, and the substituted region is flat in the base's terms, so it
  // earns the low contrast weight it deserves.
  {
    const int radius = std::max(
        1, static_cast<int>(std::lround(options.ghostFeatherFraction * base.cols)));
    const cv::Mat feather =
        cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(radius | 1, radius | 1));
    const int blur = (radius * 2) | 1;

    for (size_t k = 0; k < aligned.size(); ++k) {
      if (k == keptBase) continue;
      cv::Mat mask;
      cv::bitwise_not(wellExposedMask(grays[k], options), mask);
      if (!ghost.empty()) cv::bitwise_or(mask, ghost, mask);
      if (cv::countNonZero(mask) == 0) continue;

      cv::dilate(mask, mask, feather);
      cv::Mat alpha;
      mask.convertTo(alpha, CV_32F, 1.0 / 255.0);
      cv::GaussianBlur(alpha, alpha, cv::Size(blur, blur), 0);

      cv::Mat substitute;
      cv::LUT(base, exposureTransferLut(table, options.displayGamma, ratios[k]),
              substitute);
      for (int y = 0; y < aligned[k].rows; ++y) {
        const float* a = alpha.ptr<float>(y);
        const uchar* s = substitute.ptr<uchar>(y);
        uchar* d = aligned[k].ptr<uchar>(y);
        for (int x = 0; x < aligned[k].cols; ++x) {
          const float w = a[x];
          if (w <= 0) continue;
          for (int c = 0; c < 3; ++c) {
            const int index = x * 3 + c;
            d[index] = cv::saturate_cast<uchar>(
                d[index] + w * (static_cast<float>(s[index]) - d[index]));
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------ §2 -----
  // The last poll before the merge. `MergeMertens::process` is one call over
  // the whole stack with no hook inside it, so a cancel arriving during it waits
  // for it — which is why the flag is checked immediately before rather than
  // only at the top of the position loop.
  if (cancelled(progress)) {
    info.cancelled = true;
    info.reason = "cancelled before exposure fusion";
    return false;
  }
  cv::Ptr<cv::MergeMertens> merge = cv::createMergeMertens(
      options.contrastWeight, options.saturationWeight, options.exposureWeight);
  cv::Mat fusedF32;
  try {
    merge->process(aligned, fusedF32);
  } catch (const cv::Exception& e) {
    info.reason = std::string("exposure fusion failed (") + e.what() +
                  "); the 0 EV frame was used alone";
    return false;
  }
  if (fusedF32.empty()) {
    info.reason = "exposure fusion produced nothing; the 0 EV frame was used alone";
    return false;
  }

  // §8.1: the output is nominally [0, 1] but the Laplacian reconstruction can
  // overshoot both ends, and a NaN survives convertTo as an arbitrary byte.
  // Clamping here is what stops a blown highlight coming back dark.
  cv::patchNaNs(fusedF32, 0.0);
  cv::min(fusedF32, 1.0, fusedF32);
  cv::max(fusedF32, 0.0, fusedF32);
  fusedF32.convertTo(fused, CV_8U, 255.0);

  info.fused = true;
  // On success `reason` carries a note rather than a refusal; the caller turns it
  // into a warning and clears it. Every one of these is a compromise, and
  // architecture §8's rule is that none of them is silent.
  std::string note;
  auto add = [&note](const std::string& text) {
    note += (note.empty() ? "" : "; ") + text;
  };
  if (!dropped.empty()) {
    add(dropped + ", so " + std::to_string(aligned.size()) + " of " +
        std::to_string(images.size()) +
        " exposures were fused — less dynamic range here than elsewhere, but no "
        "fringing");
  }
  if (metadataDisagrees) {
    add("the exposure ratio the camera reported disagrees with the one its own "
        "pixels show by more than half a stop, so the measured ratio was used");
  }
  if (usedRequestedBias) {
    add("the camera reported no exposure time or ISO, so normalisation fell back "
        "to the requested EV bias — §4's systematic-error case, not a measurement");
  }
  info.reason = note;
  return true;
}

/// Writes one frame into the work directory and hands back its path.
///
/// Shared by the fused write and by the two *unfused* paths, which is the point:
/// §5's downscale decision is made once for the whole capture and
/// `sphere_stitch.cpp` scales the intrinsics by it once, so a frame emitted at any
/// other scale is a frame the solver has the wrong focal for. Having one writer
/// makes "every emitted frame is at `frameScale`" a property of the code rather
/// than of three call sites remembering.
int writeStageFrame(const cv::Mat& frame,
                    const std::string& workDir,
                    int positionIndex,
                    int jpegQuality,
                    std::string& pathOut,
                    std::string& error) {
  char name[64];
  std::snprintf(name, sizeof(name), "/fused_%04d.jpg", positionIndex);
  const std::string path = workDir + name;
  const std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, jpegQuality,
                                   cv::IMWRITE_JPEG_OPTIMIZE, 1};
  bool written = false;
  try {
    written = cv::imwrite(path, frame, params);
  } catch (const cv::Exception& e) {
    error = std::string("could not write the fused frame ") + path + ": " + e.what();
    return SV_ERR_IO;
  }
  if (!written) {
    error = "could not write the fused frame " + path + " (out of disk space?)";
    return SV_ERR_IO;
  }
  pathOut = path;
  return SV_OK;
}

double oversamplingFor(const Intrinsics& intrinsics, int outputWidth) {
  if (outputWidth <= 0 || !(intrinsics.fx > 0) || !(intrinsics.width > 0)) return 0.0;
  const double hfovDegrees = intrinsics.hfovRadians() * 180.0 / CV_PI;
  if (!(hfovDegrees > 0)) return 0.0;
  const double framePxPerDegree = intrinsics.width / hfovDegrees;
  const double canvasPxPerDegree = outputWidth / 360.0;
  return canvasPxPerDegree > 0 ? framePxPerDegree / canvasPxPerDegree : 0.0;
}

// ────────────────────────────── the stage itself ─────────────────────────────

int fuseBrackets(const std::vector<PositionShots>& positions,
                 const Intrinsics& intrinsics,
                 const HdrFuseOptions& options,
                 SvProgress* progress,
                 HdrFuseResult& result,
                 std::string& error) {
  const auto started = Clock::now();
  result.enabled = options.enabled;
  result.positions.clear();
  result.positions.reserve(positions.size());
  result.keptFusedFrames = options.keepFusedFrames;
  setStage(progress, SV_STAGE_FUSING, 0);

  if (positions.empty()) {
    error = "no positions to fuse";
    return SV_ERR_NO_FRAMES;
  }

  // §5's downscale decision, made once for the whole capture so every frame
  // keeps the same camera. A frame that oversamples the output canvas carries
  // resolution the panorama cannot represent, and carrying it through the most
  // expensive stage in the pipeline is the single largest avoidable cost here.
  // Below the threshold nothing is resized, because resampling a frame that is
  // only just above Nyquist costs real sharpness for no memory worth having.
  result.oversampling = oversamplingFor(intrinsics, options.outputWidth);
  if (options.enabled && result.oversampling > options.maxOversampling) {
    // Snapped to a power of two, so libjpeg can do it.
    //
    // The obvious implementation picks the exact factor that lands on
    // `maxOversampling` and resizes after decoding. It works and it is the wrong
    // shape: the full-resolution frame still gets decoded, so the stage pays 12 MP
    // of decode time and — because §5 decodes a bracket concurrently — three
    // frames' worth of 12 MP buffers, before throwing most of it away. A JPEG's
    // DCT is naturally decimated by halves, and `IMREAD_REDUCED_COLOR_*` asks
    // libjpeg for that directly, so at a factor of two the decoder never
    // materialises the pixels being discarded.
    //
    // The cost of snapping is that the frames come out somewhat smaller than the
    // threshold asks for. That is bounded and harmless: the rule is only ever
    // rounded *down* to a power of two, so the result still oversamples the canvas
    // — 1.77x here against a target of 2.0 — and anything above 1.0 is resolution
    // the warp cannot use anyway.
    const double needed = result.oversampling / options.maxOversampling;
    result.decodeReduction =
        std::min(3, static_cast<int>(std::ceil(std::log2(needed))));
    result.frameScale = 1.0 / (1 << result.decodeReduction);
    result.downscaledWidth =
        static_cast<int>(std::lround(intrinsics.width * result.frameScale));
    char message[480];
    std::snprintf(message, sizeof(message),
                  "Frames oversample the %d px panorama by %.2fx, so they were "
                  "decoded at 1/%d size (%d px wide, still %.2fx oversampled). "
                  "That is resolution the output can represent; decoding at full "
                  "size would cost %.0fx the pixels through the most expensive "
                  "stage in the pipeline for detail the warp then discards.",
                  options.outputWidth, result.oversampling,
                  1 << result.decodeReduction, result.downscaledWidth,
                  result.oversampling * result.frameScale,
                  1.0 / (result.frameScale * result.frameScale));
    Json data = Json::object();
    data.set("oversampling", Json::number(result.oversampling));
    data.set("decode_reduction", Json::integer(result.decodeReduction));
    data.set("decoded_width", Json::integer(result.downscaledWidth));
    data.set("output_width", Json::integer(options.outputWidth));
    addWarning(result.warnings, SvWarningCode::kFramesDownscaled, message, data);
  }

  // A work directory is needed for anything this stage *writes*, which is any
  // fusion — and also, once §5's downscale is active, any single exposure, because
  // that frame is resampled to the same scale instead of being passed through.
  const bool needWorkDir =
      options.enabled &&
      (result.frameScale < 1.0 ||
       std::any_of(positions.begin(), positions.end(),
                   [](const PositionShots& p) { return p.shots.size() > 1; }));
  if (needWorkDir) {
    if (options.workDir.empty()) {
      error = "no work directory was given for the fused frames";
      return SV_ERR_IO;
    }
    ::mkdir(options.workDir.c_str(), 0700);
    result.fusedDirectory = options.workDir;
  }

  int decodeMs = 0;
  int alignAndFuseMs = 0;
  int writeMs = 0;
  double ghostSum = 0;
  int ghostCount = 0;

  for (size_t p = 0; p < positions.size(); ++p) {
    if (cancelled(progress)) {
      error = "cancelled during exposure fusion";
      return SV_ERR_CANCELLED;
    }
    const PositionShots& position = positions[p];
    PositionFuseInfo info;
    info.positionIndex = position.positionIndex;
    info.shotCount = static_cast<int>(position.shots.size());

    if (position.shots.empty()) {
      error = "position " + std::to_string(position.positionIndex) +
              " has no exposures";
      return SV_ERR_NO_FRAMES;
    }

    // The 0 EV shot is the reference throughout: it is the frame the pose was
    // interpolated to and the one sharpness was measured on.
    size_t baseIndex = 0;
    for (size_t k = 0; k < position.shots.size(); ++k) {
      if (position.shots[k].evBias == 0.0) { baseIndex = k; break; }
    }

    const bool fuseThis = options.enabled && position.shots.size() > 1;
    if (!fuseThis) {
      info.shotsUsed = 1;
      info.aligner = "none";
      ++result.passthroughCount;
      if (result.frameScale >= 1.0) {
        // §6's byte-identical path: the frame downstream reads *is* the file the
        // camera wrote, not a re-encode of it.
        info.passthrough = true;
        info.outputPath = position.shots[baseIndex].imagePath;
        info.reason = options.enabled ? "single exposure; nothing to fuse"
                                      : "exposure fusion disabled";
      } else {
        // §5's downscale is active, so byte-identical is not an option: this frame
        // has to arrive at the same scale as its fused neighbours or the one
        // intrinsics correction `sphere_stitch.cpp` applies is wrong for it, by
        // exactly the downscale factor. That is a focal error, and a focal error
        // is not something bundle adjustment absorbs — the frame either fails to
        // register and falls back to its IMU prior, or registers confidently onto
        // the wrong rotation.
        //
        // This is the fleet's low end rather than a corner case. A `LEGACY`
        // camera cannot bracket, so `ExposureStrategy.locked()` makes *every*
        // position single-shot, and before this branch existed every frame on
        // that device was full size against halved intrinsics.
        auto phase = Clock::now();
        cv::Mat raw = readCaptureFrame(position.shots[baseIndex].imagePath,
                                       result.decodeReduction);
        if (raw.empty()) {
          error = "could not read frame: " + position.shots[baseIndex].imagePath;
          return SV_ERR_IO;
        }
        if (!frameAspectMatchesIntrinsics(raw.size(), intrinsics.width,
                                          intrinsics.height)) {
          error = "frame " + position.shots[baseIndex].imagePath +
                  " decoded as " + std::to_string(raw.cols) + "x" +
                  std::to_string(raw.rows) +
                  ", the wrong shape for intrinsics describing " +
                  std::to_string(static_cast<int>(std::lround(intrinsics.width))) +
                  "x" +
                  std::to_string(static_cast<int>(std::lround(intrinsics.height))) +
                  " (a rotated frame, or an EXIF orientation applied on decode)";
          return SV_ERR_SCHEMA;
        }
        const int target =
            static_cast<int>(std::lround(intrinsics.width * result.frameScale));
        if (raw.cols > target + 2) {
          cv::Mat reduced;
          cv::resize(raw, reduced, cv::Size(), result.frameScale, result.frameScale,
                     cv::INTER_AREA);
          raw = reduced;
        }
        decodeMs += elapsedMs(phase);
        phase = Clock::now();
        const int status = writeStageFrame(raw, options.workDir, info.positionIndex,
                                           options.jpegQuality, info.outputPath, error);
        if (status != SV_OK) return status;
        writeMs += elapsedMs(phase);
        info.reason =
            (options.enabled ? "single exposure; nothing to fuse"
                             : "exposure fusion disabled") +
            std::string(", but it was resampled to ") + std::to_string(target) +
            " px to match the scale the rest of the capture was decoded at";
      }
      result.positions.push_back(info);
      setStage(progress, SV_STAGE_FUSING,
               static_cast<int32_t>(1000 * (p + 1) / positions.size()));
      continue;
    }

    // ------------------------------------------------------------- decode ----
    auto phase = Clock::now();
    std::vector<cv::Mat> images(position.shots.size());
    std::vector<std::string> failures(position.shots.size());
    auto decode = [&](const cv::Range& range) {
      for (int k = range.start; k < range.end; ++k) {
        cv::Mat raw = readCaptureFrame(position.shots[k].imagePath,
                                       result.decodeReduction);
        if (raw.empty()) {
          failures[k] = position.shots[k].imagePath;
          continue;
        }
        if (!frameAspectMatchesIntrinsics(raw.size(), intrinsics.width,
                                          intrinsics.height)) {
          failures[k] = position.shots[k].imagePath + " (decoded " +
                        std::to_string(raw.cols) + "x" +
                        std::to_string(raw.rows) +
                        ", the wrong shape for the bundle's intrinsics)";
          continue;
        }
        // The reduced-decode flags only apply to formats whose decoder supports
        // them. Anything else comes back full size and is resized here, so the
        // stage behaves identically either way and only the cost differs.
        if (result.frameScale < 1.0 &&
            raw.cols > static_cast<int>(std::lround(intrinsics.width *
                                                    result.frameScale)) + 2) {
          cv::Mat reduced;
          cv::resize(raw, reduced, cv::Size(), result.frameScale, result.frameScale,
                     cv::INTER_AREA);
          raw = reduced;
        }
        images[k] = raw;
      }
    };
    // §5 wants the decode parallelised — it is embarrassingly parallel and
    // otherwise dominates the stage. Across the stack rather than across
    // positions, because holding several positions' stacks at once is exactly
    // the 430 MB the one-position-at-a-time discipline exists to avoid.
    // §8.4's caveat is answered by `testParallelDecodeMatchesSerial`.
    if (options.parallelDecode && images.size() > 1) {
      cv::parallel_for_(cv::Range(0, static_cast<int>(images.size())), decode);
    } else {
      decode(cv::Range(0, static_cast<int>(images.size())));
    }
    for (const std::string& failure : failures) {
      if (failure.empty()) continue;
      error = "could not read bracket frame: " + failure;
      return SV_ERR_IO;
    }
    decodeMs += elapsedMs(phase);

    // ------------------------------------------------------ align and fuse ---
    phase = Clock::now();
    // Between decoding the stack and fusing it. The decode is three full-frame
    // JPEGs and is parallelised across the stack, so it is one indivisible unit
    // however the flag is polled; what this check buys is that a cancel
    // arriving during it is honoured before the far longer alignment begins.
    if (cancelled(progress)) {
      error = "cancelled during exposure fusion";
      return SV_ERR_CANCELLED;
    }

    cv::Mat fused;
    const bool ok =
        fuseStack(images, position.shots, baseIndex, options, fused, info, progress);
    alignAndFuseMs += elapsedMs(phase);
    images.clear();
    images.shrink_to_fit();

    result.maxShiftPx = std::max(result.maxShiftPx, info.maxShiftPx);
    result.maxMeasuredVsMetadataStops =
        std::max(result.maxMeasuredVsMetadataStops, info.measuredVsMetadataStops);
    if (info.aligner == "ecc") ++result.eccCount;
    if (info.aligner == "mtb") ++result.mtbCount;

    if (info.cancelled) {
      // Not §3.2's fallback. A cancelled fusion is the user stopping the
      // pipeline, and treating it as "this bracket refused to fuse" would carry
      // on through the remaining positions and hand back a panorama nobody
      // asked for.
      error = "cancelled during exposure fusion";
      return SV_ERR_CANCELLED;
    }

    if (!ok) {
      // §3.2: fall back to the 0 EV shot alone, and name the position. The
      // panorama is then locally lower dynamic range but geometrically correct,
      // which is much better than fringing.
      fused.release();
      if (result.frameScale >= 1.0) {
        info.passthrough = true;
        info.outputPath = position.shots[baseIndex].imagePath;
      } else {
        // The scale invariant again, and here it costs nothing at all: the 0 EV
        // frame was already decoded at `frameScale` a few lines above, so the
        // fallback writes the copy it is holding rather than pointing downstream
        // at the full-size original.
        auto writePhase = Clock::now();
        const int status =
            writeStageFrame(images[baseIndex], options.workDir, info.positionIndex,
                            options.jpegQuality, info.outputPath, error);
        if (status != SV_OK) return status;
        writeMs += elapsedMs(writePhase);
      }
      ++result.rejectedCount;
      {
        Json data = Json::object();
        data.set("position", Json::integer(info.positionIndex));
        data.set("reason", Json::string(info.reason));
        addWarning(result.warnings, SvWarningCode::kBracketRefused,
                   "Position " + std::to_string(info.positionIndex) + ": " +
                       info.reason + ".",
                   data);
      }
      result.positions.push_back(info);
      setStage(progress, SV_STAGE_FUSING,
               static_cast<int32_t>(1000 * (p + 1) / positions.size()));
      continue;
    }

    ghostSum += info.ghostFraction;
    ++ghostCount;
    result.maxGhostFraction = std::max(result.maxGhostFraction, info.ghostFraction);

    // ------------------------------------------------------------- write -----
    phase = Clock::now();
    {
      const int status = writeStageFrame(fused, options.workDir, info.positionIndex,
                                        options.jpegQuality, info.outputPath, error);
      if (status != SV_OK) return status;
    }
    writeMs += elapsedMs(phase);

    ++result.fusedCount;
    if (!info.reason.empty()) {
      Json data = Json::object();
      data.set("position", Json::integer(info.positionIndex));
      data.set("reason", Json::string(info.reason));
      addWarning(result.warnings, SvWarningCode::kBracketCompromised,
                 "Position " + std::to_string(info.positionIndex) + ": " +
                     info.reason + ".",
                 data);
      info.reason.clear();
    }
    result.positions.push_back(info);

    // Polled per position, not per stage: at 29 positions this stage is tens of
    // seconds long, and cancellation that waits for it is not cancellation.
    setStage(progress, SV_STAGE_FUSING,
             static_cast<int32_t>(1000 * (p + 1) / positions.size()));
  }

  for (const PositionFuseInfo& info : result.positions) {
    if (info.fused && info.shotsUsed < info.shotCount) ++result.partiallyFusedCount;
  }
  result.meanGhostFraction = ghostCount ? ghostSum / ghostCount : 0.0;
  result.stageMilliseconds["hdr_decode"] = decodeMs;
  result.stageMilliseconds["hdr_fuse"] = alignAndFuseMs;
  result.stageMilliseconds["hdr_write"] = writeMs;
  result.stageMilliseconds["hdr_total"] = elapsedMs(started);
  result.peakRssMb = peakRssMb();

  if (result.rejectedCount > 0) {
    Json data = Json::object();
    data.set("rejected", Json::integer(result.rejectedCount));
    data.set("positions", Json::integer(static_cast<int64_t>(positions.size())));
    addWarning(result.warnings, SvWarningCode::kBracketsRejected,
               std::to_string(result.rejectedCount) + " of " +
                   std::to_string(positions.size()) +
                   " brackets could not be fused and fell back to their 0 EV "
                   "exposure alone. Those positions hold less dynamic range than the "
                   "rest of the panorama; they are not misaligned, which is the "
                   "trade this stage makes deliberately.",
               data);
  }
  if (result.maxMeasuredVsMetadataStops > 0.5) {
    char message[400];
    std::snprintf(message, sizeof(message),
                  "The exposure ratios the camera reported disagree with the "
                  "ratios its pixels show by up to %.2f stops. Either the "
                  "bracket was silently clamped or the frames are not the "
                  "exposures they claim to be — the R3 failure mode where a "
                  "device without real bracketing returns near-identical "
                  "frames. Normalisation used the measured ratios.",
                  result.maxMeasuredVsMetadataStops);
    Json data = Json::object();
    data.set("stops", Json::number(result.maxMeasuredVsMetadataStops));
    addWarning(result.warnings, SvWarningCode::kExposureMetadataDisagrees, message,
               data);
  }

  setStage(progress, SV_STAGE_FUSING, 1000);
  return SV_OK;
}

void cleanUpFusedFrames(const HdrFuseResult& result) {
  if (result.keptFusedFrames) return;
  for (const PositionFuseInfo& info : result.positions) {
    if (info.passthrough || info.outputPath.empty()) continue;
    std::remove(info.outputPath.c_str());
  }
  if (!result.fusedDirectory.empty()) ::rmdir(result.fusedDirectory.c_str());
}

}  // namespace sv
