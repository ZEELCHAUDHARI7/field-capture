#include "registration.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <limits>
#include <map>
#include <iomanip>
#include <numeric>
#include <sstream>

#include <opencv2/calib3d.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/stitching/detail/matchers.hpp>
#include <opencv2/stitching/detail/motion_estimators.hpp>

namespace sv {
namespace {

using Clock = std::chrono::steady_clock;

int elapsedMs(Clock::time_point since) {
  return static_cast<int>(
      std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - since).count());
}

void setStage(SvProgress* progress, int32_t stage, int32_t permille) {
  if (!progress) return;
  progress->stage = stage;
  progress->permille = permille;
}

bool cancelled(const SvProgress* progress) {
  return progress && progress->cancel != 0;
}

/// Union-find over the match graph. Components matter because §4 requires BA
/// to run independently per component rather than calling
/// `leaveBiggestComponent`, which silently throws frames away.
struct DisjointSet {
  std::vector<int> parent;
  explicit DisjointSet(size_t n) : parent(n) {
    std::iota(parent.begin(), parent.end(), 0);
  }
  int find(int a) {
    while (parent[a] != a) { parent[a] = parent[parent[a]]; a = parent[a]; }
    return a;
  }
  void unite(int a, int b) {
    a = find(a); b = find(b);
    if (a != b) parent[b] = a;
  }
};

/// Rotation angle of a matrix, radians — how far it is from the identity.
double rotationAngle(const cv::Matx33d& r) {
  const double trace = r(0, 0) + r(1, 1) + r(2, 2);
  return std::acos(std::max(-1.0, std::min(1.0, (trace - 1.0) * 0.5)));
}

cv::Matx33d toMatx33d(const cv::Mat& m) {
  cv::Mat d;
  m.convertTo(d, CV_64F);
  cv::Matx33d out;
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j)
      out(i, j) = d.at<double>(i, j);
  return out;
}

/// Second-pass gate, radians. Loose enough that honest scatter and a little
/// residual distortion survive, tight enough that an alias cannot: 2° is ~18 px
/// at a 515 px focal, roughly 30x the sub-pixel error a converged solution
/// shows.
constexpr double kSolutionGateRadians = 2.0 * CV_PI / 180.0;

cv::Mat toCv32F(const cv::Matx33d& m) {
  cv::Mat out(3, 3, CV_32F);
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j)
      out.at<float>(i, j) = static_cast<float>(m(i, j));
  return out;
}

}  // namespace

double Intrinsics::hfovRadians() const {
  return fx > 0 ? 2.0 * std::atan(width / (2.0 * fx)) : 0.0;
}

double Intrinsics::vfovRadians() const {
  return fy > 0 ? 2.0 * std::atan(height / (2.0 * fy)) : 0.0;
}

bool fitRadialFromLut(const std::vector<double>& magnifications,
                      double maxRadiusNormalized,
                      double& k1, double& k2, double& k3) {
  k1 = k2 = k3 = 0.0;
  if (magnifications.size() < 4 || !(maxRadiusNormalized > 0)) return false;

  // Apple's table is magnification factors evenly distributed along the radius
  // from lensDistortionCenter to the corner, so sample index maps linearly to
  // radius. We fit r'/r − 1 against [r², r⁴, r⁶] — three unknowns, no
  // tangential terms, per Math §4.2.
  cv::Matx33d ata = cv::Matx33d::zeros();
  cv::Vec3d atb(0, 0, 0);
  const size_t n = magnifications.size();
  size_t used = 0;

  for (size_t i = 0; i < n; ++i) {
    const double t = static_cast<double>(i) / static_cast<double>(n - 1);
    const double r = t * maxRadiusNormalized;
    if (r <= 1e-9) continue;  // r = 0 carries no information about k1..k3
    const double r2 = r * r;
    const cv::Vec3d basis(r2, r2 * r2, r2 * r2 * r2);
    const double target = magnifications[i] - 1.0;
    for (int a = 0; a < 3; ++a) {
      for (int b = 0; b < 3; ++b) ata(a, b) += basis[a] * basis[b];
      atb[a] += basis[a] * target;
    }
    ++used;
  }
  if (used < 3) return false;

  cv::Vec3d solution;
  if (!cv::solve(cv::Mat(ata), cv::Mat(atb), solution, cv::DECOMP_SVD)) return false;
  k1 = solution[0];
  k2 = solution[1];
  k3 = solution[2];
  return std::isfinite(k1) && std::isfinite(k2) && std::isfinite(k3);
}

/// Stage 6. Returns the intrinsics that are true *after* undistortion.
///
/// `getOptimalNewCameraMatrix` with alpha = 0 gives the matrix the rectified
/// image actually obeys (§2); the declaration in registration.h explains why
/// this is public rather than local to this file.
UndistortPlan buildUndistortPlan(const Intrinsics& intrinsics,
                                 std::vector<SvWarning>& warnings) {
  UndistortPlan plan;
  plan.fx = intrinsics.fx;
  plan.fy = intrinsics.fy;
  plan.cx = intrinsics.cx;
  plan.cy = intrinsics.cy;

  if (!intrinsics.hasDistortion) {
    // The expected iOS case, not a failure. Skipping the stage entirely
    // matters: a no-op remap costs a full pass over every frame and buys
    // nothing (§2).
    Json data = Json::object();
    data.set("intrinsics_source", Json::string(intrinsics.source));
    addWarning(warnings, SvWarningCode::kNoDistortionModel,
               "No lens distortion model available (intrinsics source '" +
                   intrinsics.source +
                   "'); skipping undistortion. Expected on single-lens iPads, where "
                   "R2 found calibrated intrinsics are simply unavailable. Bundle "
                   "adjustment will absorb what it can.",
               data);
    return plan;
  }

  double k1 = intrinsics.k1, k2 = intrinsics.k2;
  double p1 = intrinsics.p1, p2 = intrinsics.p2, k3 = intrinsics.k3;

  if (intrinsics.isLookupTable) {
    // iOS radial magnification table. p1/p2 stay zero by construction.
    const double cornerX = std::max(intrinsics.lutCenterX,
                                    intrinsics.width - intrinsics.lutCenterX);
    const double cornerY = std::max(intrinsics.lutCenterY,
                                    intrinsics.height - intrinsics.lutCenterY);
    const double maxRadiusNorm =
        std::sqrt((cornerX / intrinsics.fx) * (cornerX / intrinsics.fx) +
                  (cornerY / intrinsics.fy) * (cornerY / intrinsics.fy));
    if (!fitRadialFromLut(intrinsics.magnifications, maxRadiusNorm, k1, k2, k3)) {
      addWarning(warnings, SvWarningCode::kDistortionLutUnfittable,
                 "iOS lens distortion lookup table could not be fitted to a radial "
                 "model; proceeding without undistortion.");
      return plan;
    }
    p1 = 0.0;
    p2 = 0.0;
  }

  const cv::Size size(static_cast<int>(std::lround(intrinsics.width)),
                      static_cast<int>(std::lround(intrinsics.height)));
  const cv::Matx33d k(intrinsics.fx, 0, intrinsics.cx,
                      0, intrinsics.fy, intrinsics.cy,
                      0, 0, 1);
  const std::vector<double> dist{k1, k2, p1, p2, k3};

  const cv::Mat suggested =
      cv::getOptimalNewCameraMatrix(cv::Mat(k), dist, size, /*alpha=*/0.0, size);

  // Rectify to the camera model the SOLVER uses, not the one
  // `getOptimalNewCameraMatrix` happens to suggest.
  //
  // §2 is right that undistortion changes the effective intrinsics and the new
  // K must be carried forward — but carrying it forward verbatim is not enough,
  // because `detail::BundleAdjusterRay` does not consume a general K. It builds
  // its own as `K(0,0) = K(1,1) = focal` with the principal point pinned to the
  // image centre: one focal, no aspect, no offset. `CameraParams::aspect` and
  // `ppx/ppy` are simply not read by that adjuster.
  //
  // On a 480x640 frame `getOptimalNewCameraMatrix` returned fx 505.38 against
  // fy 498.38 — 1.4% anisotropy. Feeding that to a solver that assumes square
  // pixels leaves a systematic vertical scale error of ~4 px at the frame edge,
  // and it presents as a worse S1 *after* correctly undistorting, which reads
  // like the undistortion is broken. Measured on `nominal`: median residual
  // 1.46 px with no correction, 3.45 px with an anisotropic one.
  //
  // Since `newCameraMatrix` is a free choice of output camera, the fix is to
  // choose the one the rest of the pipeline can actually represent. The larger
  // focal is taken so the result stays inside the all-valid rectangle alpha = 0
  // computed — a smaller one would zoom out and reintroduce invalid border.
  const double squareFocal = std::max(suggested.at<double>(0, 0),
                                      suggested.at<double>(1, 1));
  cv::Mat rectified = cv::Mat::eye(3, 3, CV_64F);
  rectified.at<double>(0, 0) = squareFocal;
  rectified.at<double>(1, 1) = squareFocal;
  rectified.at<double>(0, 2) = intrinsics.width * 0.5;
  rectified.at<double>(1, 2) = intrinsics.height * 0.5;

  cv::initUndistortRectifyMap(cv::Mat(k), dist, cv::Mat(), rectified, size,
                              CV_16SC2, plan.map1, plan.map2);

  plan.active = true;
  plan.newCameraMatrix = rectified;
  plan.fx = squareFocal;
  plan.fy = squareFocal;
  plan.cx = rectified.at<double>(0, 2);
  plan.cy = rectified.at<double>(1, 2);
  return plan;
}

UndistortPlan buildEstimatedUndistortPlan(const Intrinsics& intrinsics,
                                          double k1, double k2) {
  UndistortPlan plan;
  plan.fx = intrinsics.fx;
  plan.fy = intrinsics.fy;
  plan.cx = intrinsics.cx;
  plan.cy = intrinsics.cy;
  if ((k1 == 0.0 && k2 == 0.0) || !(intrinsics.fx > 0) || !(intrinsics.fy > 0)) {
    return plan;
  }

  const cv::Size size(static_cast<int>(std::lround(intrinsics.width)),
                      static_cast<int>(std::lround(intrinsics.height)));
  const cv::Matx33d k(intrinsics.fx, 0, intrinsics.cx,
                      0, intrinsics.fy, intrinsics.cy,
                      0, 0, 1);
  const std::vector<double> dist{k1, k2, 0.0, 0.0, 0.0};
  // Same K in and out. See the header: the solve normalised its features by this
  // `fx`/`cx` and never changed them, so the pixels have to be corrected in that
  // same camera or the two stages are describing different lenses.
  cv::initUndistortRectifyMap(cv::Mat(k), dist, cv::Mat(), cv::Mat(k), size,
                              CV_16SC2, plan.map1, plan.map2);
  plan.active = true;
  plan.newCameraMatrix = cv::Mat(k);
  return plan;
}

namespace {

/// Clears inlier flags for correspondences that disagree with a rotation
/// estimate by more than [thresholdRadians], and returns how many it dropped.
///
/// This exists because of a gap between two true statements. §4 sets
/// `match_conf` to 0.3 — deliberately permissive — on the reasoning that "we
/// already trust geometry from the IMU gate; RANSAC plus BA rejects the rest".
/// RANSAC does reject a lot, but only **pairwise**: `findHomography` asks
/// whether a match is consistent with one image pair, and two aliased points on
/// repetitive structure — formwork, ceiling tile, block courses, and the
/// synthetic scenes that stand in for them — are perfectly consistent with each
/// other. And BA does *not* reject the rest, because
/// `detail::BundleAdjusterRay` is unweighted least squares with no robust loss,
/// so a few hundred matches carrying 90° of error out of fourteen thousand
/// dominate the normal equations completely.
///
/// Measured on `pristine`, whose seed is exact by construction: 3% globally
/// inconsistent matches pulled the recovered focal 5.9% off and the RMS from
/// 0.26 px to 7.2 px. Gating on the prior is the same idea as gating the pair
/// list, applied one level down.
int gateMatchesByRotation(const std::vector<cv::detail::ImageFeatures>& features,
                          std::vector<cv::detail::MatchesInfo>& pairwise,
                          const std::vector<cv::Matx33d>& rotations,
                          const std::vector<cv::detail::CameraParams>& cameras,
                          size_t n, double thresholdRadians) {
  std::vector<cv::Matx33d> kinv(n);
  for (size_t i = 0; i < n; ++i) {
    cv::Mat k;
    cameras[i].K().convertTo(k, CV_64F);
    kinv[i] = toMatx33d(k.inv());
  }

  int dropped = 0;
  for (size_t i = 0; i < n; ++i) {
    for (size_t j = i + 1; j < n; ++j) {
      cv::detail::MatchesInfo& info = pairwise[i * n + j];
      if (info.matches.empty() || info.inliers_mask.size() != info.matches.size()) continue;

      int inliers = 0;
      for (size_t m = 0; m < info.matches.size(); ++m) {
        if (!info.inliers_mask[m]) continue;
        const cv::DMatch& match = info.matches[m];
        const cv::Point2f& p1 = features[i].keypoints[match.queryIdx].pt;
        const cv::Point2f& p2 = features[j].keypoints[match.trainIdx].pt;
        const cv::Vec3d a = rotations[i] * (kinv[i] * cv::Vec3d(p1.x, p1.y, 1.0));
        const cv::Vec3d b = rotations[j] * (kinv[j] * cv::Vec3d(p2.x, p2.y, 1.0));
        if (angleBetween(a, b) > thresholdRadians) {
          info.inliers_mask[m] = 0;
          ++dropped;
        } else {
          ++inliers;
        }
      }

      info.num_inliers = inliers;
      // Keep confidence consistent with the surviving inliers, using OpenCV's
      // own formula — BundleAdjusterBase selects its edges on this value, so
      // leaving it stale would let a pair that just lost all its matches carry
      // on contributing an edge with no residuals behind it.
      info.confidence =
          inliers / (8.0 + 0.3 * static_cast<double>(info.matches.size()));

      cv::detail::MatchesInfo& dual = pairwise[j * n + i];
      dual.inliers_mask = info.inliers_mask;
      dual.num_inliers = info.num_inliers;
      dual.confidence = info.confidence;
    }
  }
  return dropped;
}

/// Runs BundleAdjusterRay over one connected component, re-indexed to a dense
/// sub-problem. Returns false if BA declined to converge.
/// How far bundle adjustment may move the focal from its seed before the result
/// is treated as the rotation/focal degeneracy rather than a refinement.
constexpr double kMaxFocalRefinementRatio = 1.20;

/// A solved lens: the two radial coefficients, or zeros when nothing was solved.
struct RadialEstimate {
  double k1 = 0.0;
  double k2 = 0.0;
  bool operator!() const { return k1 == 0.0 && k2 == 0.0; }
};

/// Moves every feature point to where a pinhole lens would have put it, for
/// shared radial coefficients [k1] and [k2].
///
/// The keypoints are moved rather than the pixels. Undistorting the *images* would
/// mean a second full-resolution remap of every frame — seconds of work and a
/// copy of the whole capture in memory — to improve numbers that are computed
/// entirely from these few thousand coordinates. The correspondences are
/// unaffected: which point matches which is a fact about image content, and
/// moving both ends of a match by the same lens model keeps it true.
void applyRadialUndistortToFeatures(
    std::vector<cv::detail::ImageFeatures>& features,
    double fx, double fy, double cx, double cy, double k1, double k2) {
  if (!(fx > 0) || !(fy > 0) || (k1 == 0.0 && k2 == 0.0)) return;
  for (cv::detail::ImageFeatures& frame : features) {
    for (cv::KeyPoint& point : frame.keypoints) {
      const double xn = (point.pt.x - cx) / fx;
      const double yn = (point.pt.y - cy) / fy;
      // Fixed-point inverse of `x_d = x·(1 + k1·r²)`, the same iteration
      // `cv::undistortPoints` uses. Converges in a handful of passes for the mild
      // coefficients a phone lens has; the cap is for ones that would not
      // converge at all.
      double ux = xn, uy = yn;
      for (int iteration = 0; iteration < 8; ++iteration) {
        const double r2 = ux * ux + uy * uy;
        const double radial = 1.0 + r2 * (k1 + r2 * k2);
        if (std::abs(radial) < 1e-6) break;
        const double nx = xn / radial;
        const double ny = yn / radial;
        const double step = std::abs(nx - ux) + std::abs(ny - uy);
        ux = nx;
        uy = ny;
        if (step < 1e-9) break;
      }
      point.pt.x = static_cast<float>(fx * ux + cx);
      point.pt.y = static_cast<float>(fy * uy + cy);
    }
  }
}

/// The shared radial coefficient that best explains the correspondences, or 0
/// when the search finds nothing better than a pinhole.
///
/// A coarse sweep then a refinement around the winner, over a smooth 1-D
/// objective — the post-solve ray-angle residual. Only `k1` is searched: it
/// dominates a phone lens by an order of magnitude, and a second free coefficient
/// doubles the cost while giving the search room to fit noise. What is left after
/// `k1` is small enough that bundle adjustment does absorb it.
///
/// Each candidate is scored with a **deliberately short** solve. The objective is
/// smooth and single-minimum, so ranking candidates does not need convergence —
/// only the winner is solved properly, by the ordinary path afterwards. Without
/// that this would add fourteen full solves to a stitch with a 60 s budget.
RadialEstimate estimateSharedRadialDistortion(
    const std::vector<cv::detail::ImageFeatures>& features,
    const std::vector<cv::detail::MatchesInfo>& pairwise,
    const std::vector<cv::detail::CameraParams>& seedCameras,
    const std::map<int, std::vector<int>>& grouped,
    const std::vector<bool>& imuOnly,
    const std::vector<FrameInput>& frames,
    size_t n, double fx, double fy, double cx, double cy,
    SvProgress* progress);

bool adjustComponent(const std::vector<int>& members,
                     const std::vector<cv::detail::ImageFeatures>& features,
                     const std::vector<cv::detail::MatchesInfo>& pairwise,
                     size_t n,
                     std::vector<cv::detail::CameraParams>& cameras,
                     bool& focalClamped) {
  const size_t m = members.size();
  if (m < 2) return false;

  std::vector<cv::detail::ImageFeatures> subFeatures(m);
  std::vector<cv::detail::CameraParams> subCameras(m);
  for (size_t a = 0; a < m; ++a) {
    subFeatures[a] = features[members[a]];
    // Pitfall §8.2: several detail:: functions rely on img_idx, and it must
    // describe position within the vector handed to them, not the original
    // frame number.
    subFeatures[a].img_idx = static_cast<int>(a);
    subCameras[a] = cameras[members[a]];
  }

  // Pitfall §8.4: pairwise is a flat n·n vector indexed i*n+j, and the adjuster
  // requires unmatched entries to be present and default-constructed with
  // confidence 0 — not absent.
  std::vector<cv::detail::MatchesInfo> subPairwise(m * m);
  for (size_t a = 0; a < m; ++a) {
    for (size_t b = 0; b < m; ++b) {
      if (a == b) continue;
      cv::detail::MatchesInfo info = pairwise[members[a] * n + members[b]];
      info.src_img_idx = static_cast<int>(a);
      info.dst_img_idx = static_cast<int>(b);
      subPairwise[a * m + b] = info;
    }
  }

  // Refuse to call the adjuster with nothing to adjust.
  //
  // `BundleAdjusterBase` builds its edge list from pairs whose confidence
  // exceeds conf_thresh_, then sizes a CvLevMarq problem from the inliers on
  // those edges. With no qualifying edge the residual vector is empty and
  // OpenCV aborts the process from inside `CvLevMarq::update`
  // (compat_ptsetreg.cpp: "!err.empty()") — an abort, not an exception we could
  // catch, so it has to be prevented rather than handled. The global match
  // gates above can legitimately produce this: dropping correspondences lowers
  // the confidence that admitted the edge in the first place.
  int usableEdges = 0;
  int usableInliers = 0;
  for (size_t a = 0; a < m; ++a) {
    for (size_t b = a + 1; b < m; ++b) {
      const cv::detail::MatchesInfo& info = subPairwise[a * m + b];
      if (info.confidence > 1.0 && info.num_inliers > 0) {
        ++usableEdges;
        usableInliers += info.num_inliers;
      }
    }
  }
  if (usableEdges == 0 || usableInliers == 0) return false;

  cv::detail::BundleAdjusterRay adjuster;
  // Pitfall §8.5: setConfThresh interacts with which frames BA considers
  // connected, and a high value silently excludes them. Keep it at 1.0 and do
  // the exclusion ourselves, visibly.
  adjuster.setConfThresh(1.0);

  // Bound the solve. OpenCV's default is `TermCriteria(EPS | COUNT, 1000,
  // DBL_EPSILON)` — a thousand Levenberg–Marquardt iterations against machine
  // precision, which is "run until it cannot improve at all". A well-conditioned
  // component reaches its answer in a few dozen and this never binds. A
  // degenerate one — thin overlap, mostly IMU-positioned, correspondences that
  // do not agree on any rotation — cannot converge at all, so it grinds through
  // every one of the thousand and then reports failure anyway. On `sparse_plan`
  // that was **211 s of a 215 s stitch**, spent to arrive at "did not converge".
  //
  // This did not matter while such a capture was refused before BA ever ran.
  // Now that the pipeline stitches whatever it is handed, the degenerate case is
  // one a site manager can actually reach, so the cost of failing has to be
  // bounded rather than open-ended. 1e-6 is far below the precision any of these
  // parameters are observable to, so a solve that would have converged still
  // does, to the same answer.
  adjuster.setTermCriteria(
      cv::TermCriteria(cv::TermCriteria::EPS | cv::TermCriteria::COUNT, 200, 1e-6));

  // Focal only. The principal point is weakly observable from a rotational
  // panorama and, if freed, absorbs distortion and pose error into a
  // plausible-looking but wrong K, which then poisons the warp (§5).
  cv::Mat_<uchar> refineMask = cv::Mat::zeros(3, 3, CV_8U);
  refineMask(0, 0) = 1;
  adjuster.setRefinementMask(refineMask);

  // The seed focal, kept before the solve so the result can be judged against
  // it. Every camera in a component starts from the same device-derived focal,
  // so member 0 is representative.
  const double seedFocal = subCameras.empty() ? 0.0 : subCameras[0].focal;

  if (!adjuster(subFeatures, subPairwise, subCameras)) return false;

  // Reject a runaway focal, keep the rotations.
  //
  // `BundleAdjusterRay` minimises a ray-angle residual over rotations *and*
  // focal, and that parameterisation is degenerate: lengthening the focal while
  // shrinking every rotation leaves the residual almost unchanged, because the
  // solution stays internally consistent. It is simply not the geometry that
  // took the photos. Unguarded, a real capture came back with a focal of
  // 9804 px — a 23.5 degree horizontal field of view on a camera that has about
  // 67 — reporting a beautiful S1 of 0.54 px while coverage collapsed to 46.6%
  // and the panorama was mostly pole fill. Low reprojection error is what this
  // failure looks like, not a defence against it.
  //
  // A genuine refinement is small: R2 measured ~3% between a device's declared
  // focal and the solved one. 20% is generous enough never to bind on a real
  // solve and tight enough to catch the 220% seen here. The rotations are kept
  // because they are separately observable from the correspondences and are not
  // what went wrong; only the focal is replaced.
  if (seedFocal > 0) {
    for (size_t a = 0; a < m; ++a) {
      const double ratio = subCameras[a].focal / seedFocal;
      if (ratio < 1.0 / kMaxFocalRefinementRatio || ratio > kMaxFocalRefinementRatio) {
        for (size_t b = 0; b < m; ++b) subCameras[b].focal = seedFocal;
        focalClamped = true;
        break;
      }
    }
  }

  // A shared focal was tried here and removed.
  //
  // `BundleAdjusterRay`'s refinement mask is per camera, so refining the focal
  // gives every frame its own — over-parameterised for a geometry where one lens
  // took every frame, and in principle a way for a frame to absorb its pose error
  // into a private focal rather than correcting the pose. OpenCV cannot express a
  // shared parameter, so the fix was alternation: collapse to the median focal,
  // re-solve rotations with it held, twice.
  //
  // It moved S1 on `nominal` by **0.07 px**, from 8.76 to 8.69, and cost two extra
  // bundle-adjustment solves per component — enough to push the cancellation
  // suite's 50- and 100-cycle stitches past their timeouts. The
  // over-parameterisation is real and it is not the bottleneck: the focal is being
  // pulled off by undeclared lens distortion, which no amount of tying corrects
  // (see `RegistrationOptions::estimateDistortion`). Recorded rather than kept, so
  // it is not tried a third time.
  for (size_t a = 0; a < m; ++a) cameras[members[a]] = subCameras[a];
  return true;
}

/// How much sphere a set of camera rotations points into, in degrees.
///
/// The widest angle between any optical axis and the mean of them all, doubled —
/// so a set that spans a hemisphere reads ~180 and a set aimed one way reads ~0.
/// IMU-only frames are excluded: they carry their prior rather than a solved
/// rotation, so including them would measure the prior and hide exactly the
/// divergence this is looking for.
///
/// `cameras[i].R` maps the panorama frame to the camera, so the optical axis in
/// panorama coordinates is `Rᵀ·(0,0,1)` — the third *row* of R.
double angularSpreadDegrees(const std::vector<cv::Matx33d>& rotations,
                            const std::vector<bool>& imuOnly) {
  std::vector<cv::Vec3d> axes;
  for (size_t i = 0; i < rotations.size(); ++i) {
    if (i < imuOnly.size() && imuOnly[i]) continue;
    axes.emplace_back(rotations[i](2, 0), rotations[i](2, 1), rotations[i](2, 2));
  }
  if (axes.size() < 2) return 0.0;

  cv::Vec3d mean(0, 0, 0);
  for (const cv::Vec3d& a : axes) mean += a;
  const double norm = cv::norm(mean);
  // Directions cancelling to nothing means they are spread over the whole
  // sphere, which is the opposite of collapsed.
  if (norm < 1e-9) return 180.0;
  mean *= 1.0 / norm;

  double widest = 0;
  for (const cv::Vec3d& a : axes) {
    const double cosine = std::max(-1.0, std::min(1.0, mean.dot(a)));
    widest = std::max(widest, std::acos(cosine));
  }
  return std::min(180.0, 2.0 * widest * 180.0 / CV_PI);
}

/// Two decimals, for warning text. `std::to_string` on a double gives six.
std::string twoDecimals(double v) {
  std::ostringstream out;
  out << std::fixed << std::setprecision(2) << v;
  return out.str();
}

/// S1. RMS ray-angle residual over every inlier, expressed in pixels at the
/// registration scale.
///
/// Ray angle rather than image-plane reprojection because that is the error
/// `BundleAdjusterRay` actually minimises, and because image-plane error blows
/// up near the poles — where a spherical panorama spends a lot of its frames.
struct ResidualStats {
  double rms = 0;
  double median = 0;
  double p95 = 0;
  double rejectedFraction = 0;
  size_t count = 0;
  size_t kept = 0;

  /// Pearson correlation between a kept residual and the log detection scale of
  /// the keypoint it came from — architecture §3.3's translation signature.
  ///
  /// A pure-rotation model fitted to frames that were taken from *one* point
  /// leaves residuals that are noise: uncorrelated with anything about the
  /// feature. Fitted to frames taken from a lens that travelled, it leaves
  /// residuals proportional to the parallax disparity, which is `r/d` — larger
  /// for near content. SIFT's detection scale is a usable proxy for `1/d`,
  /// because a surface twice as close images its texture twice as large, so a
  /// positive correlation here is the fingerprint of a camera that moved rather
  /// than pivoted.
  ///
  /// It is a **proxy and it is scene-dependent** — a wall of small tiles next to
  /// a wall of large panels breaks the depth-to-scale assumption — so the
  /// threshold that turns this into a warning is set well clear of the
  /// no-translation case rather than at the first sign of correlation, and the
  /// number itself is reported so it can be re-calibrated against real captures.
  double scaleCorrelation = 0;
};

ResidualStats reprojectionResiduals(
    const std::vector<cv::detail::ImageFeatures>& features,
    const std::vector<cv::detail::MatchesInfo>& pairwise,
    const std::vector<cv::detail::CameraParams>& cameras,
    const std::vector<bool>& imuOnly,
    size_t n, double focalPx) {
  std::vector<double> residuals;
  // Paired with `residuals` by index, and not sorted with it: the correlation
  // below needs each residual still attached to the keypoint that produced it.
  std::vector<double> logScales;

  std::vector<cv::Matx33d> rays(n);
  std::vector<cv::Matx33d> kinv(n);
  for (size_t i = 0; i < n; ++i) {
    rays[i] = toMatx33d(cameras[i].R);
    cv::Mat kf;
    cameras[i].K().convertTo(kf, CV_64F);
    kinv[i] = toMatx33d(kf.inv());
  }

  for (size_t i = 0; i < n; ++i) {
    if (imuOnly[i]) continue;
    for (size_t j = i + 1; j < n; ++j) {
      if (imuOnly[j]) continue;
      const cv::detail::MatchesInfo& info = pairwise[i * n + j];
      if (info.matches.empty() || info.inliers_mask.size() != info.matches.size()) continue;

      for (size_t m = 0; m < info.matches.size(); ++m) {
        if (!info.inliers_mask[m]) continue;
        const cv::DMatch& match = info.matches[m];
        const cv::Point2f& p1 = features[i].keypoints[match.queryIdx].pt;
        const cv::Point2f& p2 = features[j].keypoints[match.trainIdx].pt;

        const cv::Vec3d a = rays[i] * (kinv[i] * cv::Vec3d(p1.x, p1.y, 1.0));
        const cv::Vec3d b = rays[j] * (kinv[j] * cv::Vec3d(p2.x, p2.y, 1.0));

        const double angle = angleBetween(a, b);
        residuals.push_back(angle * focalPx);  // small angle: arc length on the sensor

        // The geometric mean of the two detection scales, in log2. Geometric
        // rather than either one alone because the pair is symmetric — the same
        // physical patch seen from two positions — and log because scale space is
        // multiplicative: SIFT octaves are factors of two, so a linear
        // correlation on the raw size would be dominated by the handful of
        // coarsest keypoints.
        const double s1 = std::max(1e-3, static_cast<double>(
                                             features[i].keypoints[match.queryIdx].size));
        const double s2 = std::max(1e-3, static_cast<double>(
                                             features[j].keypoints[match.trainIdx].size));
        logScales.push_back(0.5 * (std::log2(s1) + std::log2(s2)));
      }
    }
  }

  ResidualStats stats;
  if (residuals.empty()) return stats;

  std::vector<double> sorted = residuals;
  std::sort(sorted.begin(), sorted.end());
  stats.median = sorted[sorted.size() / 2];
  stats.p95 = sorted[static_cast<size_t>(0.95 * (sorted.size() - 1))];

  // Reject the false-correspondence tail before taking the RMS.
  //
  // `inliers_mask` is a **pairwise** consensus: `findHomography` decided the
  // match was consistent with that one image pair. A match can pass that and
  // still be globally wrong — repeated structure (formwork, ceiling tile, block
  // courses) is exactly what produces a self-consistent pair of aliases — and
  // because RMS is dominated by its tail, a few hundred such matches out of
  // 14000 move it from 0.2 px to 90 px while every other statistic stays
  // perfect. Reporting that as S1 would mean a *correct* solution failed its
  // own criterion.
  //
  // The gate is the median absolute deviation, which needs no magic pixel
  // constant and adapts to the profile: MAD·1.4826 is a robust sigma, and
  // anything past 5 of those is not a correspondence, it is a mismatch. The
  // rejected fraction is reported rather than swallowed — architecture §8.
  std::vector<double> deviations;
  deviations.reserve(sorted.size());
  for (double r : sorted) deviations.push_back(std::fabs(r - stats.median));
  std::nth_element(deviations.begin(),
                   deviations.begin() + static_cast<long>(deviations.size() / 2),
                   deviations.end());
  const double mad = deviations[deviations.size() / 2];
  const double robustSigma = 1.4826 * mad;

  // A floor keeps a pathologically tight distribution from rejecting honest
  // sub-pixel scatter, which would flatter the number rather than measure it.
  const double threshold = std::max(stats.median + 5.0 * robustSigma, 1.0);

  double sumSquares = 0;
  size_t kept = 0;
  // Sums for the §3.3 correlation, over the same kept set as the RMS. The
  // rejected tail is excluded on purpose: a globally-aliased match on repetitive
  // structure has a huge residual and an arbitrary scale, so including it would
  // let the mismatch rate drive a number that is supposed to be about geometry.
  double sumR = 0, sumS = 0, sumRR = 0, sumSS = 0, sumRS = 0;
  for (size_t m = 0; m < residuals.size(); ++m) {
    const double r = residuals[m];
    if (r > threshold) continue;
    sumSquares += r * r;
    ++kept;
    const double s = logScales[m];
    sumR += r;
    sumS += s;
    sumRR += r * r;
    sumSS += s * s;
    sumRS += r * s;
  }
  if (kept > 8) {
    const double count = static_cast<double>(kept);
    const double covariance = sumRS / count - (sumR / count) * (sumS / count);
    const double varianceR = sumRR / count - (sumR / count) * (sumR / count);
    const double varianceS = sumSS / count - (sumS / count) * (sumS / count);
    if (varianceR > 1e-12 && varianceS > 1e-12) {
      stats.scaleCorrelation = covariance / std::sqrt(varianceR * varianceS);
    }
  }

  stats.count = residuals.size();
  stats.kept = kept;
  stats.rejectedFraction =
      1.0 - static_cast<double>(kept) / static_cast<double>(residuals.size());
  stats.rms = kept ? std::sqrt(sumSquares / static_cast<double>(kept)) : stats.median;
  return stats;
}

double loopClosureDegrees(const std::vector<cv::Matx33d>& rotations,
                          const std::vector<FrameInput>& frames,
                          const std::vector<bool>& imuOnly,
                          const std::vector<cv::detail::ImageFeatures>& features,
                          const std::vector<cv::detail::MatchesInfo>& pairwise,
                          const std::vector<cv::detail::CameraParams>& cameras,
                          size_t n,
                          int& ringFrames);

RadialEstimate estimateSharedRadialDistortion(
    const std::vector<cv::detail::ImageFeatures>& features,
    const std::vector<cv::detail::MatchesInfo>& pairwise,
    const std::vector<cv::detail::CameraParams>& seedCameras,
    const std::map<int, std::vector<int>>& grouped,
    const std::vector<bool>& imuOnly,
    const std::vector<FrameInput>& frames,
    size_t n, double fx, double fy, double cx, double cy,
    SvProgress* progress) {
  if (!(fx > 0) || !(fy > 0) || n < 3) return {};

  struct Trial {
    double rms = std::numeric_limits<double>::infinity();
    std::vector<cv::detail::CameraParams> cameras;
    std::vector<cv::detail::ImageFeatures> features;
  };

  /// One candidate: undistort a copy of the features, solve each component
  /// briefly, and take the RMS ray-angle residual.
  const auto evaluate = [&](double k1, double k2) -> Trial {
    Trial out;
    std::vector<cv::detail::ImageFeatures> trial = features;
    applyRadialUndistortToFeatures(trial, fx, fy, cx, cy, k1, k2);
    std::vector<cv::detail::CameraParams> cameras = seedCameras;
    for (const auto& entry : grouped) {
      if (entry.second.size() < 2) continue;
      // Every frame of the component, and a cap was tried and removed.
      //
      // One lens took them all, so a dozen frames ought to identify it as well as
      // thirty-four — and this loop runs once per candidate, so a cap is the whole
      // cost of the search: 20.6 s uncapped against 9.2 s at twelve frames, on a
      // stitch whose device budget is 60 s. It does not work. Capping to the first
      // twelve took SSIM from 0.763 back to 0.580, worse on S1 than not searching
      // at all, because the members of a component are contiguous on the sphere:
      // the first twelve are one part of one ring, and a radial coefficient needs
      // features spread over the *radius* of many frames to be observable. A
      // cheaper search would have to sample across the component rather than
      // truncate it.
      const size_t m = entry.second.size();
      std::vector<cv::detail::ImageFeatures> subFeatures(m);
      std::vector<cv::detail::CameraParams> subCameras(m);
      for (size_t a = 0; a < m; ++a) {
        subFeatures[a] = trial[entry.second[a]];
        subFeatures[a].img_idx = static_cast<int>(a);
        subCameras[a] = cameras[entry.second[a]];
      }
      std::vector<cv::detail::MatchesInfo> subPairwise(m * m);
      for (size_t a = 0; a < m; ++a) {
        for (size_t b = 0; b < m; ++b) {
          if (a == b) continue;
          cv::detail::MatchesInfo info =
              pairwise[static_cast<size_t>(entry.second[a]) * n + entry.second[b]];
          info.src_img_idx = static_cast<int>(a);
          info.dst_img_idx = static_cast<int>(b);
          subPairwise[a * m + b] = info;
        }
      }
      // The same refusal `adjustComponent` makes, and for the same reason: with
      // no qualifying edge `BundleAdjusterBase` sizes an empty residual vector
      // and OpenCV **aborts the process** from inside `CvLevMarq::update`
      // ("!err.empty()"). An abort, not an exception, so it has to be prevented
      // rather than caught. Leaving it out took `low_texture` — the profile that
      // exists precisely because a bare slab gives almost nothing to match —
      // from a graceful IMU-only panorama to a dead stitcher.
      int usableEdges = 0;
      int usableInliers = 0;
      for (size_t a = 0; a < m; ++a) {
        for (size_t b = a + 1; b < m; ++b) {
          const cv::detail::MatchesInfo& info = subPairwise[a * m + b];
          if (info.confidence > 1.0 && info.num_inliers > 0) {
            ++usableEdges;
            usableInliers += info.num_inliers;
          }
        }
      }
      if (usableEdges == 0 || usableInliers == 0) continue;

      cv::detail::BundleAdjusterRay adjuster;
      adjuster.setConfThresh(1.0);
      // Thirty iterations, not two hundred. Ranking candidates on a smooth
      // single-minimum objective does not need convergence, and fourteen
      // converged solves would not fit the stitch budget.
      adjuster.setTermCriteria(
          cv::TermCriteria(cv::TermCriteria::EPS | cv::TermCriteria::COUNT, 30, 1e-4));
      cv::Mat_<uchar> refineMask = cv::Mat::zeros(3, 3, CV_8U);
      refineMask(0, 0) = 1;
      adjuster.setRefinementMask(refineMask);
      if (!adjuster(subFeatures, subPairwise, subCameras)) continue;
      for (size_t a = 0; a < m; ++a) cameras[entry.second[a]] = subCameras[a];
    }
    const double focalPx = cameras.empty() ? fx : cameras[0].focal;
    const ResidualStats stats =
        reprojectionResiduals(trial, pairwise, cameras, imuOnly, n, focalPx);
    // A candidate that keeps almost nothing has not found a better lens, it has
    // found a way to throw the evidence away.
    if (stats.kept < 16) return out;
    out.rms = stats.rms;
    out.cameras = std::move(cameras);
    out.features = std::move(trial);
    return out;
  };

  // A phone lens is barrel — k1 negative — and the fleet R2 measured sits around
  // −0.05 to −0.15. The sweep runs past both ends so the minimum is bracketed
  // rather than found at an edge, and includes 0 so a lens that really is
  // rectilinear wins outright and nothing is applied.
  double bestK1 = 0.0;
  double bestK2 = 0.0;
  Trial pinhole = evaluate(0.0, 0.0);
  Trial best = pinhole;
  static const double kCoarse[] = {-0.30, -0.24, -0.18, -0.13, -0.09,
                                   -0.06, -0.03, 0.03,  0.06};
  for (const double candidate : kCoarse) {
    if (cancelled(progress)) return {};
    Trial trial = evaluate(candidate, 0.0);
    if (trial.rms < best.rms) {
      best = std::move(trial);
      bestK1 = candidate;
    }
  }
  // Refine around the winner, at a third of the coarse spacing. One pass: the
  // objective is shallow near its minimum, so a second pass buys less than the
  // solve it costs.
  if (bestK1 != 0.0) {
    // `k2` matters more than its size suggests. Fitting `k1` alone to a lens that
    // has both forces a compromise that is right in the mid-radius and wrong at
    // the edge — a *systematic* radial bias rather than a random one, and a
    // systematic bias is exactly what accumulates around a full turn. The
    // measured symptom was a solve whose pairwise residual improved while its
    // loop closure went from 1.42° to 5.83°, which is what "locally better,
    // globally worse" looks like in one number.
    const double k1Step = 0.02;
    for (const double k2Candidate : {0.0, 0.01, 0.02, 0.04, -0.02}) {
      for (const double k1Delta : {0.0, -k1Step, k1Step}) {
        if (cancelled(progress)) break;
        if (k2Candidate == 0.0 && k1Delta == 0.0) continue;  // already the winner
        Trial trial = evaluate(bestK1 + k1Delta, k2Candidate);
        if (trial.rms < best.rms) {
          best = std::move(trial);
          bestK1 = bestK1 + k1Delta;
          bestK2 = k2Candidate;
        }
      }
    }
  }

  // Only accept a real improvement. A 2% gain is inside the noise of a
  // thirty-iteration solve, and applying a lens model on that evidence would be
  // fitting the search rather than the camera.
  if (bestK1 == 0.0 || !(best.rms < 0.98 * pinhole.rms)) return {};

  // And check it against a metric the search never saw.
  //
  // The search minimises a residual summed over pairs, which is dominated by the
  // many high-overlap neighbours and says nothing about whether the ring still
  // closes. Those can disagree: measured on `nominal`, a `k1` that took S1 from
  // 8.69 px to 6.74 px and the focal from −1.6% to −0.3% took loop closure the
  // wrong way, from 1.42° to 5.83° — locally more consistent, globally worse,
  // which is what a systematic radial bias looks like when it accumulates around
  // a full turn.
  //
  // So loop closure is the acceptance test rather than another term in the
  // objective. It is independent of what was optimised, it is the thing a viewer
  // actually sees as a step at the ±180° meridian, and it costs one evaluation
  // rather than one per candidate.
  int ringFrames = 0;
  const auto closure = [&](const Trial& trial) {
    if (trial.cameras.empty()) return std::numeric_limits<double>::infinity();
    std::vector<cv::Matx33d> rotations(n);
    for (size_t i = 0; i < n; ++i) rotations[i] = toMatx33d(trial.cameras[i].R);
    return loopClosureDegrees(rotations, frames, imuOnly, trial.features, pairwise,
                              trial.cameras, n, ringFrames);
  };
  const double closureWith = closure(best);
  const double closureWithout = closure(pinhole);
  // A little worse is acceptable when the residual has improved materially —
  // both are noisy — but a doubling is the bias, not noise.
  if (std::isfinite(closureWithout) && closureWith > 1.5 * closureWithout + 0.1) {
    return {};
  }
  return RadialEstimate{bestK1, bestK2};
}

/// S2. Compose the relative rotations around the equatorial ring; the
/// deviation of the product from the identity is the accumulated yaw error a
/// full turn leaves behind.
double loopClosureDegrees(const std::vector<cv::Matx33d>& rotations,
                          const std::vector<FrameInput>& frames,
                          const std::vector<bool>& imuOnly,
                          const std::vector<cv::detail::ImageFeatures>& features,
                          const std::vector<cv::detail::MatchesInfo>& pairwise,
                          const std::vector<cv::detail::CameraParams>& cameras,
                          size_t n,
                          int& ringFrames) {
  std::vector<cv::Matx33d> kinv(n);
  for (size_t idx = 0; idx < n; ++idx) {
    cv::Mat k;
    cameras[idx].K().convertTo(k, CV_64F);
    kinv[idx] = toMatx33d(k.inv());
  }

  struct Entry { double yaw; size_t index; };
  std::vector<Entry> ring;

  for (size_t i = 0; i < frames.size() && i < rotations.size(); ++i) {
    if (i < imuOnly.size() && imuOnly[i]) continue;
    const cv::Vec3d forward = forwardWorld(frames[i].pose);
    const double pitch = std::asin(std::max(-1.0, std::min(1.0, forward[1])));
    if (std::fabs(pitch) > 15.0 * CV_PI / 180.0) continue;  // equatorial ring only
    ring.push_back({std::atan2(forward[0], forward[2]), i});
  }
  ringFrames = static_cast<int>(ring.size());
  if (ring.size() < 3) return -1.0;  // sentinel: no ring, not "perfect"


  std::sort(ring.begin(), ring.end(),
            [](const Entry& a, const Entry& b) { return a.yaw < b.yaw; });

  // Walk the ring in yaw order, composing relative rotations measured from the
  // IMAGERY, and see how far the round trip lands from the identity.
  //
  // The relative rotations must come from the correspondences, not from the
  // global solution. Composing `R_{k+1}·R_kᵀ` over the solution's own rotations
  // telescopes to exactly the identity for any input whatsoever — the R_k terms
  // cancel pairwise — so it reports 0.000° on a perfect stitch and on a garbage
  // one alike. That is a tautology, not a criterion, and it is an easy one to
  // ship because the number it prints looks like a pass.
  //
  // Estimating each hop independently from its own inliers keeps the
  // measurement independent of what bundle adjustment decided, which is the
  // whole point of S2: BA distributes loop error around the ring, so the only
  // way to see it is to re-derive the hops and close the loop by hand.
  cv::Matx33d product = cv::Matx33d::eye();
  for (size_t k = 0; k < ring.size(); ++k) {
    const size_t i = ring[k].index;
    const size_t j = ring[(k + 1) % ring.size()].index;

    const cv::detail::MatchesInfo& info =
        i < j ? pairwise[i * n + j] : pairwise[j * n + i];
    if (info.matches.empty() || info.inliers_mask.size() != info.matches.size()) {
      return -1.0;  // a hop with no correspondences: the ring is not closed
    }

    std::vector<cv::Vec3d> from, to;
    for (size_t m = 0; m < info.matches.size(); ++m) {
      if (!info.inliers_mask[m]) continue;
      const cv::DMatch& match = info.matches[m];
      const size_t low = std::min(i, j), high = std::max(i, j);
      const cv::Point2f& pLow = features[low].keypoints[match.queryIdx].pt;
      const cv::Point2f& pHigh = features[high].keypoints[match.trainIdx].pt;
      const cv::Point2f& pi = (i == low) ? pLow : pHigh;
      const cv::Point2f& pj = (j == low) ? pLow : pHigh;

      cv::Vec3d a = kinv[i] * cv::Vec3d(pi.x, pi.y, 1.0);
      cv::Vec3d b = kinv[j] * cv::Vec3d(pj.x, pj.y, 1.0);
      a /= std::sqrt(a.dot(a));
      b /= std::sqrt(b.dot(b));
      from.push_back(a);
      to.push_back(b);
    }
    if (from.size() < 8) return -1.0;

    // Kabsch on the two ray sets is the relative rotation the overlap implies.
    product = kabsch(from, to) * product;
  }
  return rotationAngle(product) * 180.0 / CV_PI;
}

}  // namespace

int registerFrames(const std::vector<FrameInput>& frames,
                   const Intrinsics& intrinsics,
                   const RegistrationOptions& options,
                   SvProgress* progress,
                   RegistrationResult& result,
                   std::string& error) {
  const size_t n = frames.size();
  if (n == 0) {
    error = "bundle contains no captured positions";
    return SV_ERR_NO_FRAMES;
  }
  if (!(intrinsics.fx > 0) || !(intrinsics.width > 0)) {
    error = "intrinsics are missing or degenerate (fx and image size are required)";
    return SV_ERR_SCHEMA;
  }

  result.rotations.assign(n, cv::Matx33d::eye());
  result.imuOnly.assign(n, false);

  if (intrinsics.source == "exifFallback" || (!intrinsics.hasDistortion &&
                                              intrinsics.source == "derivedFromPhysics")) {
    Json data = Json::object();
    data.set("intrinsics_source", Json::string(intrinsics.source));
    addWarning(result.warnings, SvWarningCode::kWeakIntrinsics,
               "Intrinsics are on the weakest tier R2 describes (source '" +
                   intrinsics.source +
                   "', no distortion model). Registration tolerates this, but "
                   "geometric accuracy is bounded by the focal estimate rather than "
                   "by the stitcher.",
               data);
  }

  // ------------------------------------------------------- stage 6 + 7 ------
  auto stageStart = Clock::now();
  setStage(progress, SV_STAGE_UNDISTORTING, 0);

  UndistortPlan undistort = buildUndistortPlan(intrinsics, result.warnings);

  // §3: work at ~0.6 MP. Recorded, because every pixel-unit metric below is at
  // this scale and is meaningless without it.
  const double fullArea = intrinsics.width * intrinsics.height;
  const double scale = std::min(1.0, std::sqrt(options.targetRegistrationPixels / fullArea));
  result.registrationScale = scale;

  // Phase 12 §3's second win: this loop is a JPEG decode, an optional remap and
  // a resize, per frame, and it is embarrassingly parallel. It is also the
  // pipeline's serial start — nothing downstream can begin until the last frame
  // is decoded — which is why the phase doc ranks parallelising it second by
  // value after the fusion downscale.
  //
  // **Bounded, not unbounded**, and that bound is the whole reason this is not a
  // one-line change. Each worker holds a decoded frame plus its rectified copy:
  // at the 12 MP capture resolution that is ~72 MB per thread, so on a 10-core
  // machine an unbounded `parallel_for_` would add 700 MB to the peak — S9's
  // entire budget — to save a few seconds. `kMaxDecodeThreads` caps it at 4, which
  // on the measured stage distribution captures most of the win: the stage is
  // decode-bound rather than compute-bound, so it saturates well before the core
  // count does.
  //
  // Thread safety of `cv::imread` across distinct files is not assumed: it is
  // verified against the shipping build by `testParallelDecodeMatchesSerial`,
  // byte for byte, because §8.4 of the Phase 05 doc says to verify before
  // parallelising and "JPEG decode is not thread-safe in all builds" is the sort
  // of claim that is true of exactly the build you did not test.
  std::vector<cv::Mat> images(n);
  std::vector<std::string> readFailures(n);
  std::atomic<int> decoded{0};
  std::atomic<bool> aborted{false};
  const auto decodeRange = [&](const cv::Range& range) {
    for (int i = range.start; i < range.end; ++i) {
      if (aborted.load(std::memory_order_relaxed)) return;
      if (cancelled(progress)) {
        aborted.store(true, std::memory_order_relaxed);
        return;
      }
      cv::Mat raw = readCaptureFrame(frames[static_cast<size_t>(i)].imagePath);
      if (raw.empty()) {
        readFailures[static_cast<size_t>(i)] =
            "could not read frame: " + frames[static_cast<size_t>(i)].imagePath;
        aborted.store(true, std::memory_order_relaxed);
        return;
      }
      // The frame has to be the shape the intrinsics claim, or every stage below
      // is solving for a camera that did not take it.
      //
      // `initUndistortRectifyMap` builds its maps at the *intrinsics'* size and
      // `cv::remap` returns a Mat the size of the **map**, filling anything that
      // falls outside the source with the border constant. So a frame that came
      // back rotated or unexpectedly scaled produces a black-bordered warp, a
      // footprint that does not tile the sphere, holes where neighbours should
      // have overlapped, and — after the push-pull fill — flat grey, with nothing
      // anywhere in the log. Nothing used to compare these two numbers.
      if (!frameSizeMatchesIntrinsics(raw.size(), intrinsics.width,
                                      intrinsics.height)) {
        readFailures[static_cast<size_t>(i)] =
            frames[static_cast<size_t>(i)].imagePath + " decoded as " +
            std::to_string(raw.cols) + "x" + std::to_string(raw.rows) +
            " but the bundle's intrinsics describe " +
            std::to_string(static_cast<int>(std::lround(intrinsics.width))) + "x" +
            std::to_string(static_cast<int>(std::lround(intrinsics.height))) +
            " (a rotated frame, an EXIF orientation applied on decode, or a "
            "capture size that changed under the intrinsics)";
        aborted.store(true, std::memory_order_relaxed);
        return;
      }
      if (undistort.active) {
        cv::Mat rectified;
        // `map1`/`map2` are read-only here and `remap` writes only its own
        // output, so sharing them across workers is safe and is what keeps the
        // maps from being built per thread — they are 12 MP of float each.
        cv::remap(raw, rectified, undistort.map1, undistort.map2, cv::INTER_LINEAR);
        raw = rectified;
      }
      cv::resize(raw, images[static_cast<size_t>(i)], cv::Size(), scale, scale,
                 cv::INTER_AREA);
      // Polled per frame rather than per stage: on a 29-frame bundle this stage
      // is seconds long, and cancellation that waits for it is not cancellation.
      const int done = decoded.fetch_add(1, std::memory_order_relaxed) + 1;
      setStage(progress, SV_STAGE_UNDISTORTING,
               static_cast<int32_t>(1000 * done / static_cast<int>(n)));
    }
  };
  if (options.decodeThreads > 1 && n > 1) {
    cv::parallel_for_(cv::Range(0, static_cast<int>(n)), decodeRange,
                      std::min<double>(options.decodeThreads,
                                       static_cast<double>(n)));
  } else {
    decodeRange(cv::Range(0, static_cast<int>(n)));
  }
  for (const std::string& failure : readFailures) {
    if (failure.empty()) continue;
    error = failure;
    return SV_ERR_IO;
  }
  if (cancelled(progress) || aborted.load()) {
    error = "cancelled during undistortion";
    return SV_ERR_CANCELLED;
  }
  result.stageMilliseconds["undistort"] = elapsedMs(stageStart);

  result.undistortFx = undistort.fx;
  result.undistortFy = undistort.fy;
  result.undistortCx = undistort.cx;
  result.undistortCy = undistort.cy;
  result.undistortActive = undistort.active;

  // Intrinsics at registration scale, after undistortion.
  const double fxReg = undistort.fx * scale;
  const double fyReg = undistort.fy * scale;
  const double cxReg = undistort.cx * scale;
  const double cyReg = undistort.cy * scale;

  stageStart = Clock::now();
  setStage(progress, SV_STAGE_FINDING_FEATURES, 0);

  // Phase 12 §3's fourth win: feature detection is independent per frame, so it
  // parallelises across frames.
  //
  // A detector **per worker**, not one shared. `cv::SIFT::detectAndCompute` is
  // not documented as thread-safe on a shared instance, and the failure mode of
  // getting that wrong is not a crash — it is subtly wrong descriptors on some
  // frames, which presents as a stitcher that occasionally misregisters and is
  // essentially undebuggable. A detector is cheap to construct next to a SIFT
  // pass over 0.6 MP.
  //
  // SIFT itself uses `parallel_for_` internally over octaves. OpenCV runs a
  // nested `parallel_for_` serially, which is what we want here: parallelism
  // across whole frames beats parallelism within one small image, because the
  // per-frame work is large and independent while the octave split has to
  // synchronise.
  //
  // Output is identical to the serial loop by construction — each frame's
  // features depend on that frame alone — and `features[i].img_idx` is written
  // from the index rather than from a counter, so the ordering cannot drift.
  std::vector<cv::detail::ImageFeatures> features(n);
  std::atomic<int> detectedCount{0};
  const auto detectRange = [&](const cv::Range& range) {
    if (aborted.load(std::memory_order_relaxed)) return;
    cv::Ptr<cv::SIFT> detector = cv::SIFT::create(
        /*nfeatures=*/0, /*nOctaveLayers=*/3,
        options.siftContrastThreshold, /*edgeThreshold=*/10, /*sigma=*/1.6);
    for (int i = range.start; i < range.end; ++i) {
      if (aborted.load(std::memory_order_relaxed)) return;
      if (cancelled(progress)) {
        aborted.store(true, std::memory_order_relaxed);
        return;
      }
      const size_t index = static_cast<size_t>(i);
      cv::detail::computeImageFeatures(detector, images[index], features[index]);
      features[index].img_idx = i;
      const int done = detectedCount.fetch_add(1, std::memory_order_relaxed) + 1;
      setStage(progress, SV_STAGE_FINDING_FEATURES,
               static_cast<int32_t>(1000 * done / static_cast<int>(n)));
    }
  };
  if (options.featureThreads > 1 && n > 1) {
    cv::parallel_for_(cv::Range(0, static_cast<int>(n)), detectRange,
                      std::min<double>(options.featureThreads,
                                       static_cast<double>(n)));
  } else {
    detectRange(cv::Range(0, static_cast<int>(n)));
  }
  if (cancelled(progress) || aborted.load()) {
    error = "cancelled during feature detection";
    return SV_ERR_CANCELLED;
  }
  result.stageMilliseconds["features"] = elapsedMs(stageStart);

  // ----------------------------------------------------------- stage 8 ------
  stageStart = Clock::now();
  setStage(progress, SV_STAGE_MATCHING, 0);

  const double hfov = intrinsics.hfovRadians();
  const double vfov = intrinsics.vfovRadians();

  // The IMU gate, as a matcher mask. Using the mask form rather than calling
  // the matcher pair by pair keeps OpenCV's own bookkeeping (both directions,
  // img_idx, H, confidence) instead of reimplementing it.
  cv::Mat mask = cv::Mat::zeros(static_cast<int>(n), static_cast<int>(n), CV_8U);
  result.totalPairs = static_cast<int>(n * (n - 1) / 2);
  for (size_t i = 0; i < n; ++i) {
    for (size_t j = i + 1; j < n; ++j) {
      if (shouldMatch(frames[i].pose, frames[j].pose, hfov, vfov, options.imuSlackRadians)) {
        mask.at<uchar>(static_cast<int>(i), static_cast<int>(j)) = 1;
        ++result.candidatePairs;
      }
    }
  }

  std::vector<cv::detail::MatchesInfo> pairwise;
  {
    cv::detail::BestOf2NearestMatcher matcher(/*try_use_gpu=*/false, options.matchConf);
    cv::UMat maskU = mask.getUMat(cv::ACCESS_READ);
    matcher(features, pairwise, maskU);
    matcher.collectGarbage();
  }
  if (cancelled(progress)) { error = "cancelled during matching"; return SV_ERR_CANCELLED; }

  std::vector<int> inlierTotals(n, 0);
  for (size_t i = 0; i < n; ++i) {
    for (size_t j = 0; j < n; ++j) {
      if (i == j) continue;
      const cv::detail::MatchesInfo& info = pairwise[i * n + j];
      if (info.num_inliers > 0) inlierTotals[i] += info.num_inliers;
      if (i < j && info.num_inliers > 0) ++result.matchedPairs;
    }
  }
  result.stageMilliseconds["match"] = elapsedMs(stageStart);

  // ------------------------------------------------ connectivity (§4) -------
  // A frame with too few inliers cannot be registered photometrically. It is
  // NOT dropped: dropping leaves a hole in the sphere, which is worse than a
  // slightly less accurate frame. It falls back to its IMU prior instead and
  // says so in the report.
  for (size_t i = 0; i < n; ++i) {
    if (inlierTotals[i] < options.minInliers) {
      result.imuOnly[i] = true;
      ++result.imuOnlyCount;
    }
  }

  DisjointSet components(n);
  for (size_t i = 0; i < n; ++i) {
    if (result.imuOnly[i]) continue;
    for (size_t j = i + 1; j < n; ++j) {
      if (result.imuOnly[j]) continue;
      const cv::detail::MatchesInfo& info = pairwise[i * n + j];
      if (info.confidence > 1.0 && info.num_inliers >= options.minInliers) {
        components.unite(static_cast<int>(i), static_cast<int>(j));
      }
    }
  }

  std::map<int, std::vector<int>> grouped;
  for (size_t i = 0; i < n; ++i) {
    if (result.imuOnly[i]) continue;
    grouped[components.find(static_cast<int>(i))].push_back(static_cast<int>(i));
  }

  // Any group that ended up alone could not be tied to anything else; treat it
  // the same way as a low-inlier frame rather than bundle-adjusting a
  // single camera against nothing.
  for (auto it = grouped.begin(); it != grouped.end();) {
    if (it->second.size() < 2) {
      for (int index : it->second) {
        if (!result.imuOnly[index]) {
          result.imuOnly[index] = true;
          ++result.imuOnlyCount;
        }
      }
      it = grouped.erase(it);
    } else {
      ++it;
    }
  }
  result.componentCount = static_cast<int>(grouped.size());

  if (result.imuOnlyCount > 0) {
    Json data = Json::object();
    data.set("frames", Json::integer(result.imuOnlyCount));
    data.set("total", Json::integer(static_cast<int64_t>(n)));
    data.set("min_inliers", Json::integer(options.minInliers));
    addWarning(result.warnings, SvWarningCode::kImuOnlyFrames,
               std::to_string(result.imuOnlyCount) + " of " + std::to_string(n) +
                   " frames had fewer than " + std::to_string(options.minInliers) +
                   " inliers and fell back to their IMU prior. They still contribute "
                   "pixels; they are just less accurate. Frames are never dropped, "
                   "because a hole in the sphere is worse than a soft frame.",
               data);
  }

  // Only a capture where *nothing at all* registered is fatal here. A high
  // imu_only count is not, by itself, a failure: on a bare-drywall interior it
  // is the expected outcome, and §7 requires `low_texture` to complete with the
  // count reported rather than to be refused. An unregisterable *plan* was
  // already rejected before any of this ran, which is where that judgement
  // belongs.
  const double imuOnlyFraction =
      static_cast<double>(result.imuOnlyCount) / static_cast<double>(n);
  if (grouped.empty()) {
    // Not one frame matched a neighbour, so the panorama is built entirely from
    // IMU orientation. That used to return SV_ERR_INSUFFICIENT on the grounds
    // that an all-IMU sphere is "not accurate enough to be worth presenting as
    // a stitch" — which is the same argument the block at the end of this stage
    // already rejects for the all-components-failed case, and it is no more
    // true here. Every frame is marked imu_only above and keeps its prior, the
    // seeds below are written for all n frames whether or not any component
    // survived, and the loop over `grouped` simply does nothing. The result is
    // a real, complete sphere positioned to a few degrees.
    //
    // A featureless white corridor is the *expected* way to reach this, not a
    // pathological one, and the manager standing in it gets a panorama they can
    // read a defect off instead of an error and a second walk. The report says
    // plainly that nothing registered; that is what makes emitting it honest
    // rather than silent degradation.
    addWarning(result.warnings, SvWarningCode::kNothingRegistered,
               "Not one frame could be matched to a neighbour, so the whole "
               "panorama is positioned from the tablet's motion sensors rather "
               "than from the photos. Either the scene has no usable texture — "
               "bare drywall, plain ceiling — or the frames do not overlap "
               "enough. It is complete and readable, but expect visible "
               "misalignment at the joins.");
  }
  if (imuOnlyFraction > options.maxImuOnlyFraction) {
    Json data = Json::object();
    data.set("fraction", Json::number(imuOnlyFraction));
    addWarning(result.warnings, SvWarningCode::kMostlyImuOnly,
               "Most of this capture (" +
                   std::to_string(static_cast<int>(imuOnlyFraction * 100 + 0.5)) +
                   "%) could not be registered photometrically and is positioned "
                   "from the IMU alone. Expect visible misalignment. This is the "
                   "documented low-texture outcome, not a crash — the result is "
                   "emitted with an honest number rather than withheld.",
               data);
  }

  if (result.componentCount > 1) {
    Json data = Json::object();
    data.set("components", Json::integer(result.componentCount));
    addWarning(result.warnings, SvWarningCode::kMatchGraphSplit,
               "The match graph split into " +
                   std::to_string(result.componentCount) +
                   " disconnected components. Each was bundle-adjusted "
                   "independently and then aligned rigidly using its IMU poses, so "
                   "the panorama is consistent within each component but only "
                   "IMU-accurate between them.",
               data);
  }

  // ----------------------------------------------------------- stage 9 ------
  stageStart = Clock::now();
  setStage(progress, SV_STAGE_ADJUSTING, 0);

  // Seeding. HomographyBasedEstimator is deliberately not used: it chains
  // pairwise homographies, so one bad pair corrupts everything downstream, and
  // it needs a connected chain in capture order. The IMU already gives a
  // globally consistent estimate good to a few degrees (§5).
  std::vector<cv::detail::CameraParams> cameras(n);
  for (size_t i = 0; i < n; ++i) {
    cameras[i].focal = fxReg;
    cameras[i].aspect = fxReg > 0 ? fyReg / fxReg : 1.0;
    cameras[i].ppx = cxReg;
    cameras[i].ppy = cyReg;
    cameras[i].R = imuRotationOpenCv(frames[i].pose, options.captureQuarterTurns);  // CV_32F — pitfall §8.1
    cameras[i].t = cv::Mat::zeros(3, 1, CV_32F);
  }

  // Pass 1: throw out correspondences the IMU prior says are impossible.
  //
  // The threshold is deliberately loose — it only has to catch gross aliases,
  // which land tens of degrees out, while leaving room for the prior itself to
  // be wrong. `harsh_imu` is 6° RMS, so anything near the slack would start
  // cutting true matches on exactly the profile that proves the IMU is a prior
  // and not a measurement.
  {
    std::vector<cv::Matx33d> seed(n);
    for (size_t i = 0; i < n; ++i)
      seed[i] = imuRotationOpenCvD(frames[i].pose, options.captureQuarterTurns);
    result.matchesDroppedByPrior =
        gateMatchesByRotation(features, pairwise, seed, cameras, n,
                              3.0 * options.imuSlackRadians);
  }

  // Estimate the lens when the device would not tell us about it.
  //
  // This is the largest single error in the whole pipeline and it is not a solver
  // problem, which is worth stating because it looks like one. Measured by
  // ablation on `nominal` (the `nominal_no_distortion` profile exists to make it
  // a number rather than an argument):
  //
  //     nominal                  S1 8.69 px   S2 1.42°     focal −1.6% off
  //     nominal, perfect lens    S1 3.80 px   S2 0.018°    focal exact
  //     nominal, true focal seed S1 9.11 px   S2 1.66°     focal −1.5% off
  //
  // So distortion accounts for more than half of S1 and *all* of the loop-closure
  // failure — and it also steals the focal: with distortion present the solve
  // lands 1.5–1.6% off whatever it starts from, because a radial error and a
  // focal error look alike to a ray-angle residual, so the free parameter absorbs
  // the one that is not in the model. Seeding the true focal therefore changes
  // nothing, which is why tuning the seed was the wrong instinct.
  //
  // R2 found the fleet mostly does not publish a distortion model, so "no model"
  // is the common case rather than the exception. But a rotational panorama at
  // ~33% overlap is a calibration rig: the same scene point is seen by several
  // frames at different radii, and a shared radial term is strongly observable
  // from that. So it is estimated instead of endured.
  if (options.estimateDistortion && !options.skipBundleAdjustment &&
      !intrinsics.hasDistortion) {
    const RadialEstimate lens = estimateSharedRadialDistortion(
        features, pairwise, cameras, grouped, result.imuOnly, frames, n, fxReg,
        fyReg, cxReg, cyReg, progress);
    result.estimatedK1 = lens.k1;
    result.estimatedK2 = lens.k2;
    if (!!lens) {
      applyRadialUndistortToFeatures(features, fxReg, fyReg, cxReg, cyReg,
                                     lens.k1, lens.k2);
      Json data = Json::object();
      data.set("k1", Json::number(lens.k1));
      data.set("k2", Json::number(lens.k2));
      addWarning(result.warnings, SvWarningCode::kDistortionEstimated,
                 "This tablet publishes no lens calibration, so the lens was "
                 "measured from the photographs themselves — the same point seen "
                 "by several frames at different distances from the centre is "
                 "enough to solve for the barrel distortion. The joins are "
                 "materially more exact than they would be without it.",
                 data);
    }
  }

  int adjustedComponents = 0;
  bool focalClamped = false;
  for (const auto& entry : grouped) {
    if (cancelled(progress)) { error = "cancelled during bundle adjustment"; return SV_ERR_CANCELLED; }
    if (options.skipBundleAdjustment) {
      ++adjustedComponents;  // the seed stands in for the solution
    } else if (adjustComponent(entry.second, features, pairwise, n, cameras,
                               focalClamped)) {
      ++adjustedComponents;
    } else {
      Json data = Json::object();
      data.set("frames", Json::integer(static_cast<int64_t>(entry.second.size())));
      addWarning(result.warnings, SvWarningCode::kBundleAdjustmentPartialFailure,
                 "Bundle adjustment did not converge for a component of " +
                     std::to_string(entry.second.size()) +
                     " frames; those frames kept their IMU prior.",
                 data);
      for (int index : entry.second) {
        cameras[index].R =
            imuRotationOpenCv(frames[index].pose, options.captureQuarterTurns);
        if (!result.imuOnly[index]) {
          result.imuOnly[index] = true;
          ++result.imuOnlyCount;
        }
      }
    }
    setStage(progress, SV_STAGE_ADJUSTING,
             static_cast<int32_t>(1000 * adjustedComponents /
                                  std::max<size_t>(1, grouped.size())));
  }

  // Every component failed to converge, so nothing is photometrically
  // registered. Carry on with the IMU priors — do NOT refuse.
  //
  // This used to return SV_ERR_REGISTRATION, which contradicted the warning
  // emitted three lines earlier ("the result is emitted with an honest number
  // rather than withheld") and, more importantly, the architecture: §8 answers
  // "low-texture wall, no features" with "fall back to the IMU prior, flag in
  // report", and §4 is explicit that a frame is never dropped because a hole in
  // the sphere is worse than a soft frame. Scaled to the whole capture the
  // argument only gets stronger.
  //
  // The line worth drawing is *when* refusing costs the user nothing. Refusing a
  // plan before the camera opens — `sparse_plan` — is free: it prevents a wasted
  // 90-second capture. Refusing after the shutter has fired 34 times destroys
  // work already paid for: the manager stood in a bare drywall corridor, and a
  // soft IMU-positioned panorama they can still read a defect off beats walking
  // back to the station with nothing. The metrics say plainly how bad it is, and
  // `imuOnlyCount` is already in the report.
  if (adjustedComponents == 0) {
    addWarning(result.warnings, SvWarningCode::kBundleAdjustmentFailed,
               "Bundle adjustment converged for no part of this capture, so every "
               "frame is positioned from its IMU prior alone. Expect misalignment "
               "of degrees, not pixels. The panorama is emitted anyway, with honest "
               "metrics, because frames already captured are worth more than a "
               "refusal — but treat it as a record of the scene, not a measurement "
               "of it.");
  }

  // Pass 2: re-gate against the solution BA just produced, then re-solve.
  //
  // The first pass could only be as tight as the prior it trusted. Now there is
  // a photometric solution to gate against, so the threshold can come down by
  // an order of magnitude and catch the aliases that survived because they
  // happened to sit within the prior's slack. Re-solving on the cleaned set is
  // what actually recovers the focal — one pass leaves it several percent off.
  if (!options.skipBundleAdjustment) {
    std::vector<cv::Matx33d> current(n);
    for (size_t i = 0; i < n; ++i) current[i] = toMatx33d(cameras[i].R);

    result.matchesDroppedBySolution = gateMatchesByRotation(
        features, pairwise, current, cameras, n, kSolutionGateRadians);

    if (result.matchesDroppedBySolution > 0) {
      for (const auto& entry : grouped) {
        if (cancelled(progress)) {
          error = "cancelled during bundle adjustment";
          return SV_ERR_CANCELLED;
        }
        adjustComponent(entry.second, features, pairwise, n, cameras, focalClamped);
      }
    }
  }

  // BA has a 3-DOF gauge freedom, so each component's solution floats. Pin each
  // one back onto the IMU gauge before levelling, using the frames' own optical
  // axes — otherwise a multi-component result would have its components rotated
  // arbitrarily relative to one another.
  for (const auto& entry : grouped) {
    // Align on all three basis vectors of every camera, not just the optical
    // axis. Forward directions alone leave roll about that axis unconstrained,
    // and a set of forwards that happens to be near-coplanar — a single ring,
    // which is most of a capture — makes the fit degenerate in exactly the way
    // the levelling step is careful to avoid. Feeding all three columns makes
    // this `argmin Σ‖R_g·R_i^BA − R_i^IMU‖_F`, which is well conditioned.
    std::vector<cv::Vec3d> fromBa, toImu;
    for (int index : entry.second) {
      const cv::Matx33d ba = toMatx33d(cameras[index].R);
      const cv::Matx33d imu =
          imuRotationOpenCvD(frames[index].pose, options.captureQuarterTurns);
      for (int column = 0; column < 3; ++column) {
        fromBa.emplace_back(ba(0, column), ba(1, column), ba(2, column));
        toImu.emplace_back(imu(0, column), imu(1, column), imu(2, column));
      }
    }
    const cv::Matx33d align = kabsch(fromBa, toImu);
    for (int index : entry.second) {
      cameras[index].R = toCv32F(align * toMatx33d(cameras[index].R));
    }
  }

  // Frames that never entered BA keep their IMU rotation, which is already in
  // the pano frame and now in the same gauge as everything else.
  for (size_t i = 0; i < n; ++i) {
    if (result.imuOnly[i]) cameras[i].R = imuRotationOpenCv(frames[i].pose, options.captureQuarterTurns);
  }

  std::vector<cv::Matx33d> rotations(n);
  for (size_t i = 0; i < n; ++i) rotations[i] = toMatx33d(cameras[i].R);

  std::vector<Pose> poses;
  poses.reserve(n);
  for (const auto& frame : frames) poses.push_back(frame.pose);

  // Did the solution keep pointing where the capture pointed?
  //
  // The focal clamp above catches the degeneracy by its most obvious symptom.
  // This catches it by its *effect*, which is the thing that actually ruins the
  // panorama: a solution whose cameras all aim into a small part of the sphere
  // while the operator demonstrably swept the whole of it. Bundle adjustment can
  // reach that state and report an excellent residual, because the residual only
  // asks whether the frames agree with each other — never whether they still
  // agree with where the tablet was pointed.
  //
  // The IMU is the reference here, and it is the right one: it is accurate to a
  // few degrees, it is independent of the imagery, and it cannot collapse,
  // because it never solved anything. If the solved directions span materially
  // less sphere than the measured ones, the solve is discarded for the priors —
  // a few degrees of honest error beats a self-consistent fiction.
  {
    const double solved = angularSpreadDegrees(rotations, result.imuOnly);
    std::vector<cv::Matx33d> imuRotations(n);
    for (size_t i = 0; i < n; ++i)
      imuRotations[i] = imuRotationOpenCvD(poses[i], options.captureQuarterTurns);
    const double measured = angularSpreadDegrees(imuRotations, result.imuOnly);

    // Only when the measured sweep is big enough for "collapsed" to mean
    // anything. Below ~30 degrees the two spreads are within pose noise of each
    // other and the ratio is not evidence.
    if (measured > 30.0 && solved < 0.6 * measured) {
      for (size_t i = 0; i < n; ++i) {
        rotations[i] = imuRotations[i];
        cameras[i].R = toCv32F(rotations[i]);
        cameras[i].focal = fxReg;
      }
      Json data = Json::object();
      data.set("solved_spread_degrees", Json::number(solved));
      data.set("measured_spread_degrees", Json::number(measured));
      addWarning(result.warnings, SvWarningCode::kSolutionCollapsed,
                 "The precise alignment step produced a result that points into "
                 "only " + std::to_string(static_cast<int>(solved + 0.5)) +
                     " degrees of the scene when the tablet swept " +
                     std::to_string(static_cast<int>(measured + 0.5)) +
                     " — the photos were made to agree with each other by moving "
                     "them somewhere they were never taken. That solution was "
                     "discarded and the tablet's motion sensors were used instead, "
                     "so the panorama covers the right directions but joins less "
                     "precisely. Usually too little overlap or too little detail "
                     "for the photos to pin each other down.",
                 data);
    }
  }

  // §7 levelling. Kabsch against measured gravity, applied to every camera.
  // waveCorrect is never called: it assumes a roughly horizontal sweep, which
  // is exactly what a full sphere is not, and we have better information.

  // Level against the frames BA actually solved. If every frame fell back to
  // its prior there is nothing to correct — the rotations already *are* the
  // IMU's — so levelling over all of them is a no-op rather than a special
  // case worth branching on.
  std::vector<bool> usable(n);
  for (size_t i = 0; i < n; ++i) usable[i] = !result.imuOnly[i];
  if (std::none_of(usable.begin(), usable.end(), [](bool b) { return b; })) {
    usable.assign(n, true);
  }

  // Measured BEFORE levelling, which is the only point at which it means
  // anything.
  //
  // This used to be measured after, and was therefore tautological: levelling is
  // *defined* as the rotation carrying the solution's mean up onto measured up,
  // so applying it and then asking how far the two differ returns zero by
  // construction. The metric read 0.000 degrees on a capture whose horizon was
  // visibly wrong, and it could not have read anything else — for any input,
  // correct or not. Same family as the S2 loop-closure bug that composed the
  // solution's own rotations around a closed loop.
  //
  // Before levelling the number answers a real question: how far had bundle
  // adjustment drifted from gravity? Small means the solve agreed with the
  // sensors. Large means levelling is carrying the panorama a long way, and if
  // the levelling itself is wrong that is where a rolled horizon comes from.
  result.residualTiltDegrees = residualTiltDegrees(rotations, poses, usable);

  const cv::Matx33d level = levellingRotation(rotations, poses, usable);
  for (size_t i = 0; i < n; ++i) {
    rotations[i] = level * rotations[i];
    cameras[i].R = toCv32F(rotations[i]);
  }
  result.rotations = rotations;
  result.stageMilliseconds["adjust"] = elapsedMs(stageStart);

  // ------------------------------------------------------------ metrics -----
  // How far levelling actually rotated the panorama, from the trace of the
  // rotation it applied. Reported beside the tilt so the pair is readable: a
  // large correction to a small residual means the levelling disagreed with a
  // solve that was already upright, which is worth seeing.
  {
    const double trace = level(0, 0) + level(1, 1) + level(2, 2);
    const double cosine = std::max(-1.0, std::min(1.0, (trace - 1.0) / 2.0));
    result.levellingRotationDegrees = std::acos(cosine) * 180.0 / CV_PI;
  }

  // Pitfall §8.3: cameras[i].focal is in registration-scale pixels. Reporting
  // it without dividing by the scale is the most common bug in detail::-based
  // code, and it is invisible until the warp is 40% too small.
  double focalSum = 0;
  int focalCount = 0;
  for (size_t i = 0; i < n; ++i) {
    if (result.imuOnly[i]) continue;
    focalSum += cameras[i].focal;
    ++focalCount;
  }
  result.refinedFocalRegPx = focalCount ? focalSum / focalCount : fxReg;
  result.refinedFocalPx = result.refinedFocalRegPx / (scale > 0 ? scale : 1.0);
  result.seedFocalRegPx = fxReg;
  result.focalRefinementClamped = focalClamped;

  if (focalClamped) {
    Json data = Json::object();
    data.set("seed_focal_px", Json::number(fxReg / (scale > 0 ? scale : 1.0)));
    data.set("max_ratio", Json::number(kMaxFocalRefinementRatio));
    addWarning(result.warnings, SvWarningCode::kFocalRefinementRejected,
               "The precise alignment step tried to change the lens's field of view "
               "by more than " +
                   std::to_string(static_cast<int>(
                       (kMaxFocalRefinementRatio - 1.0) * 100 + 0.5)) +
                   "%, which is not a refinement — it is the solver trading focal "
                   "length against rotation, a pair it cannot separate on its own. "
                   "The device's own figure was kept instead, so the panorama is "
                   "built at the right scale. Photos still line up to each other; "
                   "only the field-of-view estimate was overruled.",
               data);
  }

  // Phase 04 warps through each camera's own K. A frame that never entered BA
  // still holds its seed focal, which is the *unrefined* one — handing that to
  // the warper would place it at a slightly different angular scale from its
  // neighbours and put a step in the seam. The shared refined focal is the
  // better estimate for those, so they get it.
  result.frameFocalRegPx.assign(n, result.refinedFocalRegPx);
  for (size_t i = 0; i < n; ++i) {
    if (!result.imuOnly[i]) result.frameFocalRegPx[i] = cameras[i].focal;
  }

  // S1 is measured over EVERY frame, IMU-only ones included.
  //
  // It used to skip them, which made the headline number a statement about the
  // frames that registered well rather than about the panorama. On `nominal`
  // that read 0.295 px while the harness's ground-truth-referenced figure was
  // 4.65 px, and nothing in the report explained the gap — the same failure
  // shape as the S2 loop-closure tautology: a metric blind to its own failures.
  // A caller reading "RMS 0.3 px" is entitled to conclude the panorama is
  // registered to a third of a pixel, and with two frames sitting at IMU
  // accuracy that is not true. Architecture §8: never silently degrade.
  //
  // The registered-only figure is still worth having — it separates "the
  // solver did badly" from "the solver did well on what it could reach" — so it
  // is reported alongside, named for what it is.
  const std::vector<bool> includeEveryFrame(n, false);
  const ResidualStats residuals = reprojectionResiduals(
      features, pairwise, cameras, includeEveryFrame, n, result.refinedFocalRegPx);
  const ResidualStats registeredOnly = reprojectionResiduals(
      features, pairwise, cameras, result.imuOnly, n, result.refinedFocalRegPx);
  result.rmsReprojectionErrorPx = residuals.rms;
  result.medianReprojectionErrorPx = residuals.median;
  result.p95ReprojectionErrorPx = residuals.p95;
  result.inlierCount = static_cast<int>(residuals.count);
  result.outlierRejectedFraction = residuals.rejectedFraction;
  result.residualScaleCorrelation = residuals.scaleCorrelation;

  // Architecture §3.3's translation signature was implemented here and then
  // REMOVED, because it was measured and it does not work. The number is still
  // reported — it is free, and a future attempt should start from the evidence
  // rather than from the hypothesis — but nothing is claimed from it and no
  // warning is raised on it.
  //
  // §3.3 argues that a rotation-only model fitted to data containing translation
  // leaves residuals proportional to parallax disparity `r/d`, and that SIFT's
  // detection scale is a proxy for `1/d`, so the correlation between the two is a
  // translation fingerprint "for free, on every device". The correlation is real
  // and cheap to compute. It is also, on the only fixtures whose translation is
  // known exactly, uninformative:
  //
  //   profile        lens offset   S1        correlation
  //   pristine       0 cm          0.17 px   +0.377
  //   nominal        0 cm          9.03 px   +0.004
  //   harsh_imu      0 cm         15.20 px   +0.002
  //   parallax_1m    10 cm @ 1 m  36.35 px   -0.094
  //
  // The profile built to contain parallax has the *lowest* correlation of the
  // four, and the control with no translation at all has the highest. So the
  // detector has no true-positive power here and its largest false positive is
  // the pipeline's own control group.
  //
  // The likely reason is the fixture rather than the physics: the synthetic room
  // is textured with fractal noise, which is scale-invariant by construction, so a
  // surface at 1 m and a surface at 4 m present the same distribution of detection
  // scales and the depth proxy has nothing to stand on. Real formwork, block
  // courses and services are not scale-invariant, so the signature may well exist
  // in the field — which makes this a question for the Phase 12 §4 corpus, where a
  // deliberately-walked capture next to a deliberately-pivoted one of the same
  // scene would settle it in one afternoon.
  //
  // What must not happen in the meantime is shipping the warning anyway. A
  // fabricated cause ("you moved about 40 cm") is worse than no warning at all:
  // the first time a manager who pivoted correctly is told they walked, every
  // other warning in the report loses its authority too.
  result.rmsReprojectionRegisteredPx = registeredOnly.rms;
  result.inlierCountRegistered = static_cast<int>(registeredOnly.count);
  if (result.imuOnlyCount > 0 && residuals.rms > registeredOnly.rms * 1.5) {
    Json data = Json::object();
    data.set("rms_all_px", Json::number(residuals.rms));
    data.set("rms_registered_px", Json::number(registeredOnly.rms));
    data.set("imu_only_frames", Json::integer(result.imuOnlyCount));
    data.set("registered_frames",
             Json::integer(static_cast<int64_t>(n) - result.imuOnlyCount));
    addWarning(result.warnings, SvWarningCode::kImuOnlyDominatesResidual,
               "S1 is " + twoDecimals(residuals.rms) + " px over all frames but " +
                   twoDecimals(registeredOnly.rms) + " px over the " +
                   std::to_string(n - static_cast<size_t>(result.imuOnlyCount)) +
                   " that registered photometrically. The difference is the " +
                   std::to_string(result.imuOnlyCount) +
                   " frame(s) carrying only their IMU prior — the panorama is "
                   "accurate where it registered and degrees-accurate where it did "
                   "not.",
               data);
  }
  if (residuals.rejectedFraction > 0.05) {
    Json data = Json::object();
    data.set("fraction", Json::number(residuals.rejectedFraction));
    addWarning(result.warnings, SvWarningCode::kInconsistentInliersDiscarded,
               "Discarded " +
                   std::to_string(
                       static_cast<int>(residuals.rejectedFraction * 100 + 0.5)) +
                   "% of pairwise inliers as globally inconsistent before computing "
                   "S1. A few is normal on repetitive structure; a large share means "
                   "the matcher is aliasing and the reported error is optimistic.",
               data);
  }
  result.loopClosureErrorDegrees =
      loopClosureDegrees(rotations, frames, result.imuOnly, features, pairwise,
                         cameras, n, result.loopRingFrames);

  for (size_t i = 0; i < n; ++i) {
    if (result.imuOnly[i]) result.droppedPositionIndices.push_back(frames[i].positionIndex);
  }

  return SV_OK;
}

}  // namespace sv
