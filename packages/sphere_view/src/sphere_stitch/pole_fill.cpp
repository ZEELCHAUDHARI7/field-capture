#include "pole_fill.h"

#include <algorithm>
#include <cmath>

#include <opencv2/imgproc.hpp>

namespace sv {
namespace {

/// Solid angle of equirect row [y] out of [height], relative to the equator's.
///
/// `pitch = (π/2)(1 − 2y/H)` (Math §3), so this is `cos(pitch)` at the row
/// centre. It is the whole of §6's second refinement: a row next to the pole
/// stands for a sliver of the sphere, and a pyramid that averages it as though
/// it stood for as much as the equator pulls polar colour down over the whole
/// cap and produces radial streaks.
double rowAreaWeight(int y, int height) {
  const double pitch = (CV_PI * 0.5) * (1.0 - 2.0 * (y + 0.5) / height);
  return std::max(std::cos(pitch), 1e-6);
}

/// Wrapping column index. Column 0 and column `width-1` are adjacent on the
/// sphere; §6's first refinement is that the pyramid has to know that, or the
/// fill develops a discontinuity at the meridian.
inline int wrapX(int x, int width) {
  int v = x % width;
  return v < 0 ? v + width : v;
}

inline int clampY(int y, int height) {
  return y < 0 ? 0 : (y >= height ? height - 1 : y);
}

/// One level of the push pyramid.
struct Level {
  int width = 0;
  int height = 0;
  cv::Mat sum;   ///< CV_32FC3, colour premultiplied by area weight
  cv::Mat w;     ///< CV_32F, area weight of the samples that carried data
  cv::Mat cap;   ///< CV_32F, area weight of every sample, data or not
  cv::Mat norm;  ///< CV_32FC3, the pulled colour
  cv::Mat conf;  ///< CV_32F, 0..1
};

/// Push: halve, accumulating area-weighted sums, so coverage propagates
/// outward until the coarsest level is a single pixel that knows the average
/// colour of the whole sphere.
Level downsample(const Level& fine) {
  Level coarse;
  coarse.width = std::max(1, fine.width / 2);
  coarse.height = std::max(1, fine.height / 2);
  coarse.sum = cv::Mat::zeros(coarse.height, coarse.width, CV_32FC3);
  coarse.w = cv::Mat::zeros(coarse.height, coarse.width, CV_32F);
  coarse.cap = cv::Mat::zeros(coarse.height, coarse.width, CV_32F);

  const int xStep = fine.width > coarse.width ? 2 : 1;
  const int yStep = fine.height > coarse.height ? 2 : 1;

  for (int y = 0; y < coarse.height; ++y) {
    cv::Vec3f* sumRow = coarse.sum.ptr<cv::Vec3f>(y);
    float* wRow = coarse.w.ptr<float>(y);
    float* capRow = coarse.cap.ptr<float>(y);
    for (int dy = 0; dy < yStep; ++dy) {
      const int sy = clampY(y * yStep + dy, fine.height);
      const cv::Vec3f* fineSum = fine.sum.ptr<cv::Vec3f>(sy);
      const float* fineW = fine.w.ptr<float>(sy);
      const float* fineCap = fine.cap.ptr<float>(sy);
      for (int x = 0; x < coarse.width; ++x) {
        for (int dx = 0; dx < xStep; ++dx) {
          const int sx = wrapX(x * xStep + dx, fine.width);
          sumRow[x] += fineSum[sx];
          wRow[x] += fineW[sx];
          capRow[x] += fineCap[sx];
        }
      }
    }
  }
  return coarse;
}

/// Bilinear sample of a coarser level at the position fine pixel (x, y) sits
/// over, wrapping in x and clamping in y.
void sampleCoarse(const Level& coarse, int x, int y, int fineWidth, int fineHeight,
                  cv::Vec3f& colour, float& confidence) {
  const double sx = coarse.width == fineWidth
                        ? x
                        : (x + 0.5) * coarse.width / static_cast<double>(fineWidth) - 0.5;
  const double sy = coarse.height == fineHeight
                        ? y
                        : (y + 0.5) * coarse.height / static_cast<double>(fineHeight) - 0.5;

  const int x0 = static_cast<int>(std::floor(sx));
  const int y0 = static_cast<int>(std::floor(sy));
  const double fx = sx - x0;
  const double fy = sy - y0;

  colour = cv::Vec3f(0, 0, 0);
  confidence = 0.f;
  for (int j = 0; j < 2; ++j) {
    const int yy = clampY(y0 + j, coarse.height);
    const cv::Vec3f* colourRow = coarse.norm.ptr<cv::Vec3f>(yy);
    const float* confRow = coarse.conf.ptr<float>(yy);
    for (int i = 0; i < 2; ++i) {
      const int xx = wrapX(x0 + i, coarse.width);
      const auto weight =
          static_cast<float>((i ? fx : 1 - fx) * (j ? fy : 1 - fy));
      colour += colourRow[xx] * weight;
      confidence += confRow[xx] * weight;
    }
  }
}

}  // namespace

void pushPullFill(cv::Mat& colour, cv::Mat& weight, double adoptWeight) {
  CV_Assert(colour.type() == CV_32FC3 && weight.type() == CV_32F);
  CV_Assert(colour.size() == weight.size());

  // ---- push ---------------------------------------------------------------
  std::vector<Level> levels;
  Level base;
  base.width = colour.cols;
  base.height = colour.rows;
  base.sum = colour;
  base.w = weight;
  base.cap = cv::Mat(base.height, base.width, CV_32F);
  for (int y = 0; y < base.height; ++y) {
    base.cap.row(y).setTo(static_cast<float>(rowAreaWeight(y, base.height)));
  }
  // The caller hands us colour premultiplied by a 0/1 coverage weight; the
  // pyramid works in *area* weight, so scale both by the row's solid angle
  // once, here, rather than teaching every level about latitude.
  for (int y = 0; y < base.height; ++y) {
    const auto area = static_cast<float>(rowAreaWeight(y, base.height));
    cv::Vec3f* sumRow = base.sum.ptr<cv::Vec3f>(y);
    float* wRow = base.w.ptr<float>(y);
    for (int x = 0; x < base.width; ++x) {
      sumRow[x] *= area;
      wRow[x] *= area;
    }
  }
  levels.push_back(base);

  while (levels.back().width > 1 || levels.back().height > 1) {
    levels.push_back(downsample(levels.back()));
  }

  // ---- pull ---------------------------------------------------------------
  const auto adopt = static_cast<float>(adoptWeight);
  for (int k = static_cast<int>(levels.size()) - 1; k >= 0; --k) {
    Level& level = levels[k];
    level.norm = cv::Mat::zeros(level.height, level.width, CV_32FC3);
    level.conf = cv::Mat::zeros(level.height, level.width, CV_32F);

    for (int y = 0; y < level.height; ++y) {
      const cv::Vec3f* sumRow = level.sum.ptr<cv::Vec3f>(y);
      const float* wRow = level.w.ptr<float>(y);
      const float* capRow = level.cap.ptr<float>(y);
      cv::Vec3f* normRow = level.norm.ptr<cv::Vec3f>(y);
      float* confRow = level.conf.ptr<float>(y);

      for (int x = 0; x < level.width; ++x) {
        const float own = capRow[x] > 0 ? wRow[x] / capRow[x] : 0.f;
        const cv::Vec3f ownColour = wRow[x] > 0 ? sumRow[x] / wRow[x] : cv::Vec3f(0, 0, 0);

        if (own >= 1.f - 1e-6f || k + 1 >= static_cast<int>(levels.size())) {
          // Fully covered, or nothing coarser to borrow from. Real data passes
          // through untouched — bit for bit, which is what makes it safe to
          // run this over the whole canvas rather than only over the holes.
          normRow[x] = ownColour;
          confRow[x] = own;
          continue;
        }

        cv::Vec3f coarseColour;
        float coarseConf = 0.f;
        sampleCoarse(levels[k + 1], x, y, level.width, level.height, coarseColour,
                     coarseConf);

        const float wa = own;
        const float wb = (1.f - own) * coarseConf;
        normRow[x] = (wa + wb) > 1e-12f ? (ownColour * wa + coarseColour * wb) / (wa + wb)
                                        : cv::Vec3f(0, 0, 0);

        // §6 step 3: adopt the borrowed value with a tiny weight, so a filled
        // pixel can seed a finer fill but can never out-argue a photographed one.
        //
        // The weight is a FLOOR, not a factor. Writing this as
        // `max(own, adopt * coarseConf)` — which is the obvious reading of
        // "adopt with a weight of 1e-3" — makes the 1e-3 compound once per
        // pyramid level, so a pixel seven levels deep into a hole arrives with a
        // confidence of 1e-21, `wb` falls under the guard above, and the pixel
        // comes out BLACK. That is not a subtle degradation: on `pristine` it
        // blackened both polar caps, 2.1% of the sphere, in the one stage whose
        // entire purpose is that uncovered regions must not be black.
        //
        // What the tiny weight is actually for is the *comparison* on the line
        // above — `wa = own` against `wb = (1-own)·conf` — where it keeps
        // invented colour a thousand times weaker than photographed colour at
        // any pixel that has both. That job needs the weight to be small and
        // constant, and depth has nothing to do with it.
        confRow[x] = own > adopt ? own : (coarseConf > 0 ? adopt : 0.f);
      }
    }

    // The coarser level's sums are spent once its norm/conf have been read.
    if (k + 1 < static_cast<int>(levels.size())) {
      levels[k + 1].sum.release();
      levels[k + 1].w.release();
      levels[k + 1].cap.release();
      if (k + 2 < static_cast<int>(levels.size())) {
        levels[k + 2].norm.release();
        levels[k + 2].conf.release();
      }
    }
  }

  colour = levels[0].norm;
  weight = levels[0].conf;
}

double fillUncovered(cv::Mat& canvas, const cv::Mat& covered, int baseWidthLimit,
                     std::vector<SvWarning>& warnings) {
  CV_Assert(canvas.type() == CV_8UC3 && covered.type() == CV_8U);
  CV_Assert(canvas.size() == covered.size());

  const int width = canvas.cols;
  const int height = canvas.rows;

  double uncoveredArea = 0;
  double totalArea = 0;
  for (int y = 0; y < height; ++y) {
    const double area = rowAreaWeight(y, height);
    const uchar* coveredRow = covered.ptr<uchar>(y);
    for (int x = 0; x < width; ++x) {
      totalArea += area;
      if (!coveredRow[x]) uncoveredArea += area;
    }
  }
  const double filledFraction = totalArea > 0 ? uncoveredArea / totalArea : 0.0;
  if (uncoveredArea <= 0) return 0.0;

  // Everything is covered except a hole, and the hole is about to be filled
  // with a deliberately smooth extrapolation. Building the float pyramid at
  // 8192×4096 would spend 400 MB of the 700 MB budget to produce a result
  // indistinguishable from one built at 2048 wide, so the pyramid runs on a
  // reduced base and the covered pixels are copied through untouched.
  int reduction = 1;
  while (width / reduction > baseWidthLimit && (width / reduction) % 2 == 0 &&
         (height / reduction) % 2 == 0) {
    reduction *= 2;
  }
  const int baseWidth = width / reduction;
  const int baseHeight = height / reduction;

  cv::Mat colour = cv::Mat::zeros(baseHeight, baseWidth, CV_32FC3);
  cv::Mat weight = cv::Mat::zeros(baseHeight, baseWidth, CV_32F);
  for (int y = 0; y < height; ++y) {
    const cv::Vec3b* canvasRow = canvas.ptr<cv::Vec3b>(y);
    const uchar* coveredRow = covered.ptr<uchar>(y);
    cv::Vec3f* colourRow = colour.ptr<cv::Vec3f>(y / reduction);
    float* weightRow = weight.ptr<float>(y / reduction);
    for (int x = 0; x < width; ++x) {
      if (!coveredRow[x]) continue;
      const cv::Vec3b& pixel = canvasRow[x];
      colourRow[x / reduction] += cv::Vec3f(pixel[0], pixel[1], pixel[2]);
      weightRow[x / reduction] += 1.f;
    }
  }
  for (int y = 0; y < baseHeight; ++y) {
    cv::Vec3f* colourRow = colour.ptr<cv::Vec3f>(y);
    const float* weightRow = weight.ptr<float>(y);
    for (int x = 0; x < baseWidth; ++x) {
      // pushPullFill wants colour premultiplied by a 0/1 coverage weight, and a
      // reduced base cell is partly covered. Normalise to the mean colour of
      // the samples that were there and call the cell covered.
      if (weightRow[x] > 0) colourRow[x] /= weightRow[x];
    }
  }
  cv::threshold(weight, weight, 0.0, 1.0, cv::THRESH_BINARY);
  for (int y = 0; y < baseHeight; ++y) {
    cv::Vec3f* colourRow = colour.ptr<cv::Vec3f>(y);
    const float* weightRow = weight.ptr<float>(y);
    for (int x = 0; x < baseWidth; ++x) colourRow[x] *= weightRow[x];
  }

  double coveredCells = 0;
  for (int y = 0; y < baseHeight; ++y) {
    coveredCells += cv::countNonZero(weight.row(y));
  }
  if (coveredCells <= 0) {
    addWarning(warnings, SvWarningCode::kNothingCovered,
               "Nothing at all was covered, so there is no colour to extrapolate "
               "from and the panorama is left black. This is a capture failure, not "
               "a fill failure.");
    return 1.0;
  }

  pushPullFill(colour, weight);

  Level filled;  // reuse the sampler by wrapping the result in a Level
  filled.width = baseWidth;
  filled.height = baseHeight;
  filled.norm = colour;
  filled.conf = weight;

  for (int y = 0; y < height; ++y) {
    cv::Vec3b* canvasRow = canvas.ptr<cv::Vec3b>(y);
    const uchar* coveredRow = covered.ptr<uchar>(y);
    for (int x = 0; x < width; ++x) {
      if (coveredRow[x]) continue;  // real photography is never overwritten
      cv::Vec3f value;
      float confidence = 0;
      sampleCoarse(filled, x, y, width, height, value, confidence);
      for (int c = 0; c < 3; ++c) {
        canvasRow[x][c] = cv::saturate_cast<uchar>(value[c]);
      }
    }
  }

  return filledFraction;
}

}  // namespace sv
