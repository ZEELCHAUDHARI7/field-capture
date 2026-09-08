// sv_geometry.h — the C++ side of phases/01_MATH_AND_CONVENTIONS.md.
//
// That document is normative and opens by saying mismatched conventions
// between the planner, tracker, stitcher and viewer are the single most common
// cause of mirrored, upside-down and 90°-rotated panoramas — and that the bugs
// are maddening because each component looks correct on its own. Dart has
// exactly one implementation of these formulas
// (lib/src/utils/spherical_conventions.dart); this is the C++ one. There must
// never be a third.

#ifndef SV_GEOMETRY_H
#define SV_GEOMETRY_H

#include <opencv2/core.hpp>

#include <string>
#include <vector>

namespace sv {

/// Decodes a capture frame, in the capture frame, with no EXIF rotation applied.
///
/// **The only way this pipeline is allowed to read a frame.** Plain
/// `cv::imread(path, IMREAD_COLOR)` *applies* the file's EXIF Orientation tag,
/// which silently rotates the pixels out from under the intrinsics: the bundle's
/// `intrinsics` and its `captureQuarterTurns` both describe the capture frame as
/// the sensor delivered it, so a decoder that helpfully turns the image upright
/// leaves fx/fy swapped, the principal point transposed, and the seed rolled the
/// wrong way. iOS writes exactly such a tag (`fileDataRepresentation()` embeds
/// the connection's orientation while the pixel rows stay landscape), so this was
/// a live 90° error on that platform and a latent one on any Android HAL that
/// decides to write the tag.
///
/// [reduction] is the number of halvings to ask libjpeg for, as
/// `IMREAD_REDUCED_COLOR_*`; 0 means full size.
cv::Mat readCaptureFrame(const std::string& path, int reduction = 0);

/// Whether a decoded frame is the size its intrinsics claim, within [tolerance]
/// pixels.
///
/// Nothing in the pipeline used to compare these, and the consequences are
/// invisible rather than loud: `cv::initUndistortRectifyMap` builds its maps at
/// the *intrinsics'* size, `cv::remap` returns a Mat the size of the **map**, and
/// coordinates falling outside the source are filled with the border constant. So
/// a frame that came back rotated or unexpectedly scaled produces a black-bordered
/// warp, a footprint that does not tile the sphere, holes where neighbours should
/// have overlapped, and — after the push–pull fill — flat grey. One comparison
/// turns all of that into a one-line diagnosis.
bool frameSizeMatchesIntrinsics(const cv::Size& decoded, double width,
                                double height, int tolerance = 2);

/// Whether a decoded frame has the **shape** its intrinsics claim, regardless of
/// scale.
///
/// The scale-agnostic form of [frameSizeMatchesIntrinsics], for the fusion stage,
/// which decodes at a reduced size on purpose and cannot compare pixel counts.
/// Shape is the part that matters there: a rotated frame has its aspect inverted,
/// and the existing `raw.cols > target + 2` guard is one-sided, so a frame that
/// came back *narrower* than expected — which is what a rotated portrait frame is
/// — skipped the resize entirely and went on with intrinsics already scaled for a
/// different size. That is a pure focal error, and bundle adjustment does not
/// absorb focal errors.
bool frameAspectMatchesIntrinsics(const cv::Size& decoded, double width,
                                  double height, double tolerance = 0.02);

/// A device orientation sample, exactly as `DevicePose` records it.
struct Pose {
  double qx = 0, qy = 0, qz = 0, qw = 1;   ///< device→world, unit quaternion
  double gravityX = 0, gravityY = 1, gravityZ = 0;  ///< measured world up
  int64_t timestampUs = 0;
  double angularSpeedRadPerSec = 0;
};

/// Rotation matrix of a device→world quaternion, in the **world** frame `W`.
cv::Matx33d rotationFromQuaternion(const Pose& pose);

/// The camera→panorama rotation OpenCV's `detail::CameraParams::R` expects.
///
/// `R_opencv = M · R_wd · N` with `N = diag(1,−1,−1)` (device→OpenCV camera)
/// and `M = diag(−1,−1,1)` (world→OpenCV pano), both proper rotations (§2).
/// Because both are diagonal this is a pure sign flip, not a matrix multiply:
///
///     R_opencv[i][j] = s_i · R_wd[i][j] · t_j,  s = (−1,−1,+1), t = (+1,−1,−1)
///
/// **Returned as CV_32F on purpose.** Pitfall §8.1: `detail::CameraParams::R`
/// holding a CV_64F matrix produces silent garbage rather than an error, and
/// it is the single easiest way to lose a day in `detail::`-based code.
cv::Mat imuRotationOpenCv(const Pose& pose, int captureQuarterTurns = 0);

/// [imuRotationOpenCv] as a double-precision fixed-size matrix, for the
/// metric maths where 32-bit rounding would show up in a sub-pixel number.
cv::Matx33d imuRotationOpenCvD(const Pose& pose, int captureQuarterTurns = 0);

/// The optical axis in world coordinates. The device frame looks along `−Z_d`
/// (§1.2), so this is `R_wd · (0,0,−1)`.
cv::Vec3d forwardWorld(const Pose& pose);

/// Measured world up, normalised. Falls back to `+Y` when the sample is
/// degenerate, because a zero gravity vector would otherwise poison the Kabsch
/// solve for every frame at once.
cv::Vec3d upWorld(const Pose& pose);

/// Angle between two directions, radians, numerically safe at 0 and π.
double angleBetween(const cv::Vec3d& a, const cv::Vec3d& b);

/// Whether two frames plausibly overlap enough to be worth matching (§4).
///
/// Turning `n(n−1)/2` pairs into `O(n·k)` is the cheap half of the benefit. The
/// expensive half is that pairs pointing in opposite directions can *only*
/// produce false matches on the repetitive structure construction interiors are
/// full of — formwork, ceiling tile, block courses — so excluding them
/// structurally removes a failure mode rather than just saving time.
///
/// [slackRadians] must stay generous enough to survive the `harsh_imu` profile
/// (6° RMS); the gate is on a prior, not on a measurement.
bool shouldMatch(const Pose& a, const Pose& b,
                 double hfovRadians, double vfovRadians,
                 double slackRadians);

/// The single global rotation that levels a bundle-adjusted solution (§7).
///
/// A rotation-only BA has an exact 3-DOF gauge freedom: rotate every camera by
/// the same `R_g` and the reprojection error does not change. Stock OpenCV
/// resolves this with `detail::waveCorrect`, a heuristic that assumes a roughly
/// horizontal sweep — unreliable for a full sphere and the reason many
/// hand-rolled 360 stitchers come out tilted. We have measured gravity at every
/// shutter, so we solve for it instead, and `waveCorrect` is never called.
///
/// [cameraRotations] are the BA `R` matrices (camera→pano). [poses] supply the
/// measured gravity. Returns `R_g` in the pano frame, to be applied as
/// `R_i ← R_g · R_i`.
cv::Matx33d levellingRotation(const std::vector<cv::Matx33d>& cameraRotations,
                              const std::vector<Pose>& poses,
                              const std::vector<bool>& usable);

/// Angle, in degrees, between the mean BA up and the mean measured up after
/// [levellingRotation] has been applied. This is `residualTiltDegrees`, which
/// §5 of the phase doc requires to be < 0.2° on `pristine` and `nominal`.
double residualTiltDegrees(const std::vector<cv::Matx33d>& cameraRotations,
                           const std::vector<Pose>& poses,
                           const std::vector<bool>& usable);

/// Kabsch/Procrustes: the rotation minimising `Σ ‖R·a_i − b_i‖²`.
///
/// Exposed because it is worth unit-testing on its own; the reflection guard
/// (forcing `det = +1`) is the part that is easy to omit and produces a
/// mirrored result when the inputs are near-degenerate.
cv::Matx33d kabsch(const std::vector<cv::Vec3d>& from,
                   const std::vector<cv::Vec3d>& to);

}  // namespace sv

#endif  // SV_GEOMETRY_H
