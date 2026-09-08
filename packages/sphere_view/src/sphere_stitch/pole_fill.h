// pole_fill.h — stage 14: push–pull pyramid fill for whatever the capture did
// not reach.
//
// Nadir is optional by default (`captureNadir = false`) because it contains the
// user's feet, and even when it is captured the outermost ring may not quite
// reach the pole. An abandoned session leaves a much larger hole. None of it
// may come out black.
//
// This is a port of the push–pull fill from the pre-Phase-02 Dart stitcher —
// the one genuinely good piece of it — with the two refinements Phase 04 §6
// asks for: the pyramid is **wrap-aware**, and the downsample is weighted by
// `cos(pitch)` so the poles do not streak.

#ifndef SV_POLE_FILL_H
#define SV_POLE_FILL_H

#include <string>
#include <vector>

#include <opencv2/core.hpp>

#include "sv_warnings.h"

namespace sv {

/// Fills every zero-weight pixel of [colour] by push–pull extrapolation.
///
/// [colour] is CV_32FC3 **premultiplied** by [weight], and [weight] is CV_32F,
/// non-zero where real photography exists. Both are equirectangular: column 0
/// and column `width-1` are adjacent on the sphere, and row `y` subtends
/// `cos(pitch(y))` of the area a row at the equator does.
///
/// On return [colour] is un-premultiplied — plain colour — everywhere, and
/// [weight] is 1 where real data was and [adoptWeight] where the fill invented
/// a value. That tiny adopted weight is the Dart original's idea and it is what
/// makes the algorithm safe: real photo data always dominates, so a fill can
/// only ever leak *into* a hole, never out of one.
void pushPullFill(cv::Mat& colour, cv::Mat& weight, double adoptWeight = 1e-3);

/// Stage 14 proper. [canvas] is the cropped CV_8UC3 equirect and [covered] is
/// CV_8U, non-zero where at least one frame contributed.
///
/// Returns the area-weighted fraction of the sphere the fill invented, which is
/// the complement of the `coverageFraction` the report must state.
///
/// [baseWidthLimit] caps the resolution the pyramid is built at. The fill is a
/// deliberately smooth extrapolation — §6 wants it to read as out-of-focus
/// floor — so running the float pyramid at full 8192×4096 would spend 400 MB
/// of the 700 MB budget to produce a result indistinguishable from one built at
/// 2048 wide. Pixels that are already covered are copied through untouched, bit
/// for bit, whatever this is set to.
double fillUncovered(cv::Mat& canvas, const cv::Mat& covered,
                     int baseWidthLimit,
                     std::vector<SvWarning>& warnings);

}  // namespace sv

#endif  // SV_POLE_FILL_H
