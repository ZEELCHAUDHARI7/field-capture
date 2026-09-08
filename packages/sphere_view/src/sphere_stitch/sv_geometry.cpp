#include "sv_geometry.h"

#include <opencv2/imgcodecs.hpp>

#include <algorithm>
#include <cmath>

namespace sv {

cv::Mat readCaptureFrame(const std::string& path, int reduction) {
  // IMREAD_IGNORE_ORIENTATION is the whole point of this function existing.
  // Without it OpenCV applies the file's EXIF Orientation tag, and the bundle's
  // intrinsics — fx/fy, cx/cy, width/height — plus its captureQuarterTurns all
  // describe the frame *as the sensor delivered it*. A decoder that rotates the
  // pixels leaves every one of those describing a frame that no longer exists.
  const int base = reduction == 1   ? cv::IMREAD_REDUCED_COLOR_2
                   : reduction == 2 ? cv::IMREAD_REDUCED_COLOR_4
                   : reduction >= 3 ? cv::IMREAD_REDUCED_COLOR_8
                                    : cv::IMREAD_COLOR;
  return cv::imread(path, base | cv::IMREAD_IGNORE_ORIENTATION);
}

bool frameSizeMatchesIntrinsics(const cv::Size& decoded, double width,
                                double height, int tolerance) {
  if (!(width > 0) || !(height > 0)) return false;
  const int expectedWidth = static_cast<int>(std::lround(width));
  const int expectedHeight = static_cast<int>(std::lround(height));
  return std::abs(decoded.width - expectedWidth) <= tolerance &&
         std::abs(decoded.height - expectedHeight) <= tolerance;
}

bool frameAspectMatchesIntrinsics(const cv::Size& decoded, double width,
                                  double height, double tolerance) {
  if (!(width > 0) || !(height > 0) || decoded.width <= 0 || decoded.height <= 0) {
    return false;
  }
  const double expected = width / height;
  const double actual = static_cast<double>(decoded.width) / decoded.height;
  return std::abs(actual - expected) <= tolerance * expected;
}

namespace {

// §2: C = N·D with N = diag(1,−1,−1); P = M·W with M = diag(−1,−1,1).
// Both have det = +1, so both are proper rotations.
constexpr double kPanoFromWorld[3] = {-1.0, -1.0, 1.0};   // s
constexpr double kCameraFromDevice[3] = {1.0, -1.0, -1.0};  // t

cv::Vec3d normalizeOr(const cv::Vec3d& v, const cv::Vec3d& fallback) {
  const double n = std::sqrt(v.dot(v));
  if (!(n > 1e-12) || !std::isfinite(n)) return fallback;
  return v / n;
}

}  // namespace

cv::Matx33d rotationFromQuaternion(const Pose& pose) {
  // Normalise defensively: the bundle stores whatever the AHRS produced, and a
  // quaternion that is 1e-6 off unit turns into a matrix that is not quite a
  // rotation, which BA will happily consume and quietly mis-converge on.
  double x = pose.qx, y = pose.qy, z = pose.qz, w = pose.qw;
  const double n = std::sqrt(x * x + y * y + z * z + w * w);
  if (n > 1e-12) { x /= n; y /= n; z /= n; w /= n; } else { x = y = z = 0; w = 1; }

  return cv::Matx33d(
      1 - 2 * (y * y + z * z), 2 * (x * y - z * w),     2 * (x * z + y * w),
      2 * (x * y + z * w),     1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
      2 * (x * z - y * w),     2 * (y * z + x * w),     1 - 2 * (x * x + y * y));
}

cv::Matx33d imuRotationOpenCvD(const Pose& pose, int captureQuarterTurns) {
  const cv::Matx33d r = rotationFromQuaternion(pose);
  cv::Matx33d out;
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j)
      out(i, j) = kPanoFromWorld[i] * r(i, j) * kCameraFromDevice[j];

  // The pose is in the DEVICE frame; the JPEG is in the CAPTURE frame.
  //
  // §2 derives `C = N·D`, which quietly assumes the image's own axes are the
  // device's — true only when the sensor is mounted square to the display. Most
  // phones and tablets mount it a quarter turn off, and iOS delivers landscape
  // photos while reporting a 0° sensor orientation, so the two frames differ by
  // a roll about the optical axis that nothing here was applying.
  //
  //   C = Rz(θ)·N·D   ⟹   D = N·Rz(−θ)·C   ⟹   R_pc = M·R_wd·N·Rz(−θ)
  //
  // A right multiplication by a constant, which is exactly why it could not be
  // ignored: BA's gauge freedom is a *left* multiplication (rotate the world and
  // nothing changes), so this does not cancel. Rz preserves the optical axis, so
  // every seed still points the right way — it is rolled 90°, which leaves
  // `shouldMatch` correct, hands BA a seed a quarter turn outside its basin, and
  // makes the Kabsch levelling in §7 compare a rolled camera-up against measured
  // gravity and tilt the whole panorama.
  //
  // It cannot show up in the synthetic harness, because the rig renders from the
  // same `aimingDeviceToWorld` it records — one frame throughout, so the roll is
  // identically zero. It would have appeared on the first real capture as a
  // stitcher bug.
  if (captureQuarterTurns % 4 != 0) {
    // Rz(−θ) for θ = 90° · turns, applied on the right. Exact, no trig.
    const int turns = ((captureQuarterTurns % 4) + 4) % 4;
    const double c = (turns == 0) ? 1 : (turns == 2) ? -1 : 0;
    const double s = (turns == 1) ? -1 : (turns == 3) ? 1 : 0;  // sin(−θ)
    cv::Matx33d rolled;
    for (int i = 0; i < 3; ++i) {
      rolled(i, 0) = out(i, 0) * c + out(i, 1) * s;
      rolled(i, 1) = -out(i, 0) * s + out(i, 1) * c;
      rolled(i, 2) = out(i, 2);
    }
    out = rolled;
  }
  return out;
}

cv::Mat imuRotationOpenCv(const Pose& pose, int captureQuarterTurns) {
  const cv::Matx33d d = imuRotationOpenCvD(pose, captureQuarterTurns);
  cv::Mat out(3, 3, CV_32F);
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j)
      out.at<float>(i, j) = static_cast<float>(d(i, j));
  return out;
}

cv::Vec3d forwardWorld(const Pose& pose) {
  const cv::Matx33d r = rotationFromQuaternion(pose);
  // R_wd · (0,0,−1): the third column, negated.
  return cv::Vec3d(-r(0, 2), -r(1, 2), -r(2, 2));
}

cv::Vec3d upWorld(const Pose& pose) {
  return normalizeOr(cv::Vec3d(pose.gravityX, pose.gravityY, pose.gravityZ),
                     cv::Vec3d(0, 1, 0));
}

double angleBetween(const cv::Vec3d& a, const cv::Vec3d& b) {
  const cv::Vec3d ua = normalizeOr(a, cv::Vec3d(0, 0, 1));
  const cv::Vec3d ub = normalizeOr(b, cv::Vec3d(0, 0, 1));
  // atan2 of the cross/dot pair rather than acos(dot): acos loses all its
  // precision exactly where these angles cluster, near 0.
  const double c = std::sqrt(ua.cross(ub).dot(ua.cross(ub)));
  return std::atan2(c, ua.dot(ub));
}

bool shouldMatch(const Pose& a, const Pose& b,
                 double hfovRadians, double vfovRadians,
                 double slackRadians) {
  const double angle = angleBetween(forwardWorld(a), forwardWorld(b));
  return angle < 0.85 * std::hypot(hfovRadians, vfovRadians) + slackRadians;
}

cv::Matx33d kabsch(const std::vector<cv::Vec3d>& from,
                   const std::vector<cv::Vec3d>& to) {
  if (from.size() != to.size() || from.empty()) return cv::Matx33d::eye();

  // H = Σ a_i b_iᵀ, then maximise tr(R·H) over rotations.
  cv::Matx33d h = cv::Matx33d::zeros();
  for (size_t i = 0; i < from.size(); ++i)
    for (int r = 0; r < 3; ++r)
      for (int c = 0; c < 3; ++c)
        h(r, c) += from[i][r] * to[i][c];

  cv::Mat w, u, vt;
  cv::SVD::compute(cv::Mat(h), w, u, vt, cv::SVD::FULL_UV);
  cv::Mat v = vt.t();
  cv::Mat ut = u.t();

  // Reflection guard. Without it a near-degenerate input — every up vector
  // almost parallel, which is exactly our case since they are all gravity —
  // can yield det = −1, i.e. a mirror rather than a rotation.
  cv::Mat rot = v * ut;
  if (cv::determinant(rot) < 0) {
    cv::Mat d = cv::Mat::eye(3, 3, CV_64F);
    d.at<double>(2, 2) = -1.0;
    rot = v * d * ut;
  }

  cv::Matx33d out;
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j)
      out(i, j) = rot.at<double>(i, j);
  return out;
}

namespace {

/// Builds the two vector sets §7 aligns: where BA thinks up is, and where the
/// accelerometer measured it, both expressed in the pano frame P.
void collectUpVectors(const std::vector<cv::Matx33d>& cameraRotations,
                      const std::vector<Pose>& poses,
                      const std::vector<bool>& usable,
                      std::vector<cv::Vec3d>& fromBa,
                      std::vector<cv::Vec3d>& toImu) {
  const size_t n = std::min(cameraRotations.size(), poses.size());
  for (size_t i = 0; i < n; ++i) {
    if (i < usable.size() && !usable[i]) continue;

    // §7's "camera-frame up" is **gravity expressed in the camera frame**, not
    // the screen-up axis (0,−1,0)_c. The distinction is invisible on a level
    // frame and wrong on every other one: a camera pitched 45° up has a screen
    // up 45° away from world up, so using the screen axis makes a correctly
    // solved capture look tilted, and the levelling step then rotates the whole
    // panorama to "correct" an error that was never there.
    //
    // Gravity: W → device (R_wdᵀ) → OpenCV camera (N = diag(1,−1,−1)).
    const cv::Vec3d gravityInWorld = upWorld(poses[i]);
    const cv::Matx33d deviceToWorld = rotationFromQuaternion(poses[i]);
    const cv::Vec3d inDevice = deviceToWorld.t() * gravityInWorld;
    const cv::Vec3d inCamera(inDevice[0], -inDevice[1], -inDevice[2]);

    // Where BA believes world up points, expressed in P.
    fromBa.push_back(cameraRotations[i] * inCamera);

    // Where the accelerometer measured it, in P. P = M·W, M = diag(−1,−1,1).
    toImu.emplace_back(-gravityInWorld[0], -gravityInWorld[1], gravityInWorld[2]);

    // The property `pristine` checks: when BA agrees with the IMU exactly,
    // R_i = M·R_wd·N, so fromBa = M·R_wd·N·N·R_wdᵀ·g = M·g = toImu, and the
    // levelling rotation comes out as the identity.
  }
}

}  // namespace

cv::Matx33d levellingRotation(const std::vector<cv::Matx33d>& cameraRotations,
                              const std::vector<Pose>& poses,
                              const std::vector<bool>& usable) {
  std::vector<cv::Vec3d> fromBa, toImu;
  collectUpVectors(cameraRotations, poses, usable, fromBa, toImu);
  if (fromBa.empty()) return cv::Matx33d::eye();

  // The **minimal** rotation carrying BA's mean up onto measured up — not a
  // general Kabsch over the two sets.
  //
  // This is the subtle part of §7 and getting it wrong is silent. `gravityWorld`
  // is already expressed in the world frame, so it is the *same vector on every
  // frame*. Feeding N copies of one direction to Kabsch makes `H = Σ aᵢbᵀ`
  // rank 1, and a rank-deficient SVD returns an arbitrary rotation about that
  // axis — which shows up as the whole panorama being spun by some large angle
  // about the vertical while every tilt check still reports ~0°, because the
  // spurious rotation is precisely about the axis the check measures.
  //
  // Gravity can only ever pin two degrees of freedom. Heading is pinned
  // separately, by aligning the BA solution to the IMU rotations, whose forward
  // axes genuinely differ frame to frame. So this step is deliberately
  // restricted to the tilt it is entitled to correct.
  cv::Vec3d meanBa(0, 0, 0), meanImu(0, 0, 0);
  for (size_t i = 0; i < fromBa.size(); ++i) { meanBa += fromBa[i]; meanImu += toImu[i]; }

  const cv::Vec3d a = normalizeOr(meanBa, cv::Vec3d(0, -1, 0));
  const cv::Vec3d b = normalizeOr(meanImu, cv::Vec3d(0, -1, 0));

  const cv::Vec3d axis = a.cross(b);
  const double sine = std::sqrt(axis.dot(axis));
  const double cosine = a.dot(b);

  // Already level. Note this also covers the exactly-antiparallel case, where
  // the rotation is a half turn about an axis no data selects; leaving it alone
  // is better than inventing one.
  if (sine < 1e-12) return cv::Matx33d::eye();

  const cv::Matx33d cross(     0, -axis[2],  axis[1],
                          axis[2],       0, -axis[0],
                         -axis[1],  axis[0],       0);
  return cv::Matx33d::eye() + cross + cross * cross * ((1.0 - cosine) / (sine * sine));
}

double residualTiltDegrees(const std::vector<cv::Matx33d>& cameraRotations,
                           const std::vector<Pose>& poses,
                           const std::vector<bool>& usable) {
  std::vector<cv::Vec3d> fromBa, toImu;
  collectUpVectors(cameraRotations, poses, usable, fromBa, toImu);
  if (fromBa.empty()) return 0.0;

  // The mean of each set, then the angle between them. Means rather than a
  // per-frame RMS because the quantity §5 asks for is the *systematic* tilt
  // left in the solution; per-frame scatter is pose noise, which is S1's job.
  cv::Vec3d meanBa(0, 0, 0), meanImu(0, 0, 0);
  for (size_t i = 0; i < fromBa.size(); ++i) { meanBa += fromBa[i]; meanImu += toImu[i]; }
  meanBa *= 1.0 / static_cast<double>(fromBa.size());
  meanImu *= 1.0 / static_cast<double>(toImu.size());

  return angleBetween(meanBa, meanImu) * 180.0 / CV_PI;
}

}  // namespace sv
