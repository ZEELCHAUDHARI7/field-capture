# iOS plugin requirements

AVFoundation and CoreMotion, plus the podspec that builds
[`src/sphere_stitch`](../src/sphere_stitch). Scaffolding lands in **Phase 06**,
alongside the `flutter: plugin:` block in `pubspec.yaml`.

Non-negotiables for this side, from `phases/01_MATH_AND_CONVENTIONS.md` §4.2:

- **Disable every distortion correction on every capture**:
  `isGeometricDistortionCorrectionEnabled`,
  `isContentAwareDistortionCorrectionEnabled`, and
  `isAutoContentAwareDistortionCorrectionEnabled` all false. Apple's docs say
  content-aware correction is applied "at its discretion" — per-frame and
  content-dependent, which invalidates any fixed intrinsics model.
- Intrinsics fallback chain, in order: `AVCameraCalibrationData.intrinsicMatrix`
  → `AVCaptureConnection.cameraIntrinsicMatrix` (on
  `AVCaptureVideoDataOutput`, **not** photo output) → `videoFieldOfView` →
  EXIF. R2 found path 1 needs a multi-camera virtual device, which excludes the
  base iPad, Air and mini outright — so path 3 is the realistic primary on most
  of the fleet, and should be designed for rather than treated as degraded.
- `videoFieldOfView` is **horizontal**, confirmed. Use it with GDC disabled, not
  `geometricDistortionCorrectedVideoFieldOfView`.
- iOS distortion is radial-only: fit `r'/r = 1 + k1·r² + k2·r⁴ + k3·r⁶` to the
  lookup table and force `p1 = p2 = 0`. Apple's model gives no basis for
  tangential terms.
- `CMDeviceMotion` without a magnetic reference frame, matching Android's
  `GAME_ROTATION_VECTOR`.

**Phase 00 Spike B blocks this file**: whether
`AVCaptureConnection.cameraIntrinsicMatrix` arrives at all on our iPads is
unresolved, forum evidence directly conflicts, and it is the only measured
path single-lens iPads have.
