# Research questions

Open questions where a wrong assumption costs days. Each has a **ready-to-paste
deep-research prompt**. Run them, drop the findings into
`phases/findings/<id>_*.md`, and tell me what came back — I will fold the answers
into the affected phase docs.

## Status

| ID | Question | Blocks | Status |
|---|---|---|---|
| R1 | How do we ship OpenCV `stitching` to iOS + Android at acceptable size? | 03, 04, 05 | ✅ **done** — build from source, minimal module list, own FFI shim |
| R2 | Camera intrinsics + distortion availability and semantics | 06, accuracy of 03/04 | ✅ **done** — both original risks closed; iOS calibration likely unavailable fleet-wide |
| R3 | Bracketed burst support and latency on the real fleet | 05, 06 | ✅ **done** — approach confirmed; **burst timing unmeasured anywhere**, now Spike C's job |
| R4 | Better registration than SIFT + BA for low-texture interiors? | 03 | ⬜ **optional — skip for now**, see below |
| ~~R5~~ | ~~ARCore fleet coverage and camera sharing~~ | ~~14~~ | ❌ **dropped** — Phase 14 removed from scope |

### What R1–R3 changed in the plan

- **R1 closed the biggest risk in the project.** `GraphCutSeamFinder` needs **no
  external max-flow library** — OpenCV ships its own in-house `GCGraph` — so the
  "two extra weeks reimplementing BA/warping/blending" fallback is gone entirely.
  Licensing is clean Apache 2.0 across the whole required module set. What remains
  is a binding layer, not an algorithm rewrite. It also killed every off-the-shelf
  option: `dartcv4` exposes zero `cv::detail::` and cannot force a full 360×180
  canvas, which is an **API gap, not a size gap** — so custom bindings were always
  required.
- **R2 resolved both items in §6 of the math doc**: `videoFieldOfView` is
  horizontal, and Android's `LENS_DISTORTION` is genuinely Brown–Conrady needing
  only a coefficient reorder. It also revealed that calibrated intrinsics are
  likely **unavailable on every iPad in the fleet**, which turned intrinsics quality
  into a *gradient* that registration must tolerate rather than a constant
  (Phase 03 §2).
- **R3 confirmed** Camera2 is still correct (CameraX 1.5 has no bracketing) and that
  native HDR extensions are unusable for us. But **no source anywhere publishes a
  measured burst time**, so the 600 ms budget the entire HDR strategy rests on is
  unverified — making it the highest-priority Phase 00 measurement. It also caught
  that neither iOS bracket type auto-locks AF/AWB, and that
  `maxBracketedCapturePhotoCount` must be queried at runtime.

### On R4 — skip it for now

SIFT + IMU-seeded bundle adjustment is a known-good approach, and Phase 03 already
specifies the correct fallback for featureless frames (use the IMU prior for that
frame alone, keep it in the composite, flag it as `imu_only`). Running R4 now would
be optimising before measuring.

**Trigger to run it:** the `low_texture` profile misses its Phase 03 targets. The
one thing worth knowing then is whether **XFeat** is genuinely fast enough on mobile
— it is claimed to be, and it is much stronger on low texture. The prompt below stays
ready.

---

## R1 — OpenCV distribution (CRITICAL)

```
I am building a Flutter package that needs OpenCV's `stitching` module
(specifically the cv::detail:: namespace) callable from C++ via dart:ffi on both
iOS and Android. Target devices are iPads and mid-range/rugged Android tablets.

Research and report on:

1. Every practical way to obtain OpenCV 4.x binaries that INCLUDE the `stitching`
   module for iOS (arm64 device + simulator) and Android (arm64-v8a, armeabi-v7a):
   - official OpenCV releases (opencv2.xcframework, opencv-android-sdk)
   - the `opencv-mobile` project by nihui — does it include `stitching`,
     `features2d`, `calib3d`, `photo`? If not, can it be rebuilt with them?
   - any maintained CocoaPods / Swift Package / Gradle artifact
   - building from source with -DBUILD_LIST
   For each: exact acquisition steps, whether `stitching` is present, and the
   binary size.

2. Realistic INSTALLED app size delta for each option. For iOS static frameworks
   I need the post-link, post-strip IPA delta, not the framework's on-disk size —
   explain how to measure it correctly. For Android, per-ABI .so size.

3. The minimal -DBUILD_LIST module set that satisfies:
   cv::SIFT, cv::detail::BestOf2NearestMatcher, cv::detail::BundleAdjusterRay,
   cv::detail::SphericalWarper, cv::detail::BlocksGainCompensator,
   cv::detail::GraphCutSeamFinder, cv::detail::MultiBandBlender,
   cv::createMergeMertens, cv::findTransformECC, cv::createAlignMTB.
   Which modules are transitively required? Can `videoio`, `objdetect`, `dnn`,
   `gapi`, `highgui`, `ml` all be excluded?

4. A known-good CMake configuration for a Flutter FFI plugin linking OpenCV on
   both platforms, including: iOS bitcode/arch flags, Android STL and 16 KB page
   size alignment requirements (required for Google Play as of 2025), and
   size-reduction flags (-Os, -ffunction-sections, --gc-sections, LTO).

5. Whether the Dart packages `opencv_dart` / `dartcv4` expose the cv::detail::
   namespace, or only the high-level cv::Stitcher. Be specific — if only the
   high-level Stitcher, say so explicitly, and note whether it can emit a full
   360x180 equirectangular output.

6. Any licensing considerations for redistributing OpenCV binaries in a
   closed-source commercial mobile app (Apache 2.0 since 4.5.0 — confirm, and
   note any non-Apache-2.0 third-party components that could be pulled in, e.g.
   via the `stitching` module's dependencies).

Prefer primary sources: OpenCV release notes, GitHub repos, official docs.
Include version numbers and dates.
```

**Why it matters:** if `stitching` cannot be shipped at acceptable size, Phases
03–05 change substantially — we would implement matching / BA / warping / blending
directly over `features2d` + `calib3d`, and need a separate max-flow library for
graph-cut. That is roughly two extra weeks. Better to know now.

---

## R2 — Camera intrinsics and distortion

```
I need accurate camera intrinsics (fx, fy, cx, cy) and lens distortion
coefficients from Flutter on iOS and Android, for photogrammetric panorama
stitching. Target devices are iPads and Android tablets.

Research and report:

ANDROID (Camera2):
1. CameraCharacteristics.LENS_INTRINSIC_CALIBRATION — what exactly gates its
   availability? Which REQUEST_AVAILABLE_CAPABILITIES or hardware level is
   required? How often is it null on real mid-range devices in practice?
2. CameraCharacteristics.LENS_DISTORTION (API 28+) — I need the EXACT coefficient
   order and the exact distortion equation from AOSP documentation/source. Then
   show precisely how to map those values onto OpenCV's
   (k1, k2, p1, p2, k3) ordering for cv::undistort. Cite the AOSP source or docs
   verbatim — I have seen conflicting claims and getting the order wrong makes
   distortion worse than ignoring it.
3. The correct way to derive fx in OUTPUT-IMAGE pixels from
   LENS_INFO_AVAILABLE_FOCAL_LENGTHS + SENSOR_INFO_PHYSICAL_SIZE +
   SENSOR_INFO_ACTIVE_ARRAY_SIZE, correctly accounting for SCALER_CROP_REGION and
   for the case where the output stream aspect ratio differs from the active
   array. Give the formula and a worked numeric example.
4. Whether LENS_DISTORTION coefficients apply to the PRE_CORRECTION active array
   or the regular active array, and what that means for how they must be scaled
   to output-image coordinates.

iOS (AVFoundation):
5. AVCaptureDevice.Format.videoFieldOfView — is it HORIZONTAL, VERTICAL, or
   DIAGONAL field of view? Cite Apple documentation or a definitive empirical
   source. Does it refer to the video or the photo output dimensions?
6. AVCameraCalibrationData — on which devices/configurations is
   isCameraCalibrationDataDeliverySupported true? Does it work on iPads and on
   single-lens devices, or does it require dual-camera / depth delivery?
7. lensDistortionLookupTable — exact semantics (what is the domain, what is the
   range, is it radial magnification?) and how to either apply it directly or fit
   Brown-Conrady coefficients to it. Include Apple's own documented
   rectification algorithm if one exists.
8. AVCaptureDevice / AVCapturePhotoSettings automatic geometric distortion
   correction (isAutoContentAwareDistortionCorrectionEnabled and related) — is it
   applied variably per frame? Does enabling it invalidate a fixed intrinsics
   model? How do I fully disable all automatic geometric correction?

Prefer official platform documentation and AOSP/Apple source. Flag anything that
is community folklore rather than documented.
```

**Why it matters:** a 15% focal error stops the panorama closing at 360°. A wrong
distortion coefficient order actively degrades frames. Both are silent failures
that look like stitcher bugs.

---

## R3 — Bracketed burst capture

```
I need to capture a 3-exposure bracket (-2 EV, 0, +2 EV) as a single fast
hardware burst on iOS and Android, with white balance and focus held constant,
for HDR exposure fusion. Target: iPads and Android tablets. Total burst must
complete in under ~600 ms.

Research and report:

iOS:
1. AVCapturePhotoBracketSettings — current recommended usage on iOS 17/18/26.
   Any deprecations? Any changes with newer capture APIs?
2. The difference in practice between
   AVCaptureAutoExposureBracketedStillImageSettings (exposureTargetBias) and
   AVCaptureManualExposureBracketedStillImageSettings (duration + ISO). Which one
   holds white balance and focus genuinely fixed across the bracket?
3. Can a bracket be captured while the device is in setExposureModeCustom
   (locked) mode? Do the two conflict?
4. Typical maxBracketedCapturePhotoCount on iPad models. Is 3 always available?
5. isLensStabilizationDuringBracketedCaptureSupported — availability and measured
   benefit for reducing inter-frame shift.
6. Realistic measured wall-clock time for a 3-frame JPEG bracket at full
   resolution on recent iPads.

ANDROID (Camera2):
7. Best practice for a 3-request captureBurst with different SENSOR_EXPOSURE_TIME
   at fixed SENSOR_SENSITIVITY, with CONTROL_AE_MODE_OFF, CONTROL_AWB_MODE_OFF,
   CONTROL_AF_MODE_OFF. Any known pitfalls where the HAL silently re-enables auto
   modes or drops requests?
8. What INFO_SUPPORTED_HARDWARE_LEVEL is actually required for reliable manual
   exposure? How common is LEGACY / LIMITED on mid-range and rugged Android
   tablets (Samsung Galaxy Tab A series, and rugged brands like Zebra, Honeywell,
   Panasonic Toughbook tablets)?
9. Realistic measured wall-clock time for a 3-frame full-resolution JPEG burst.
10. Whether CameraX has since gained an equivalent bracketing capability, and
    whether it exposes per-frame SENSOR_TIMESTAMP and manual exposure. (I have
    assumed it does not and chosen Camera2 — please confirm or correct.)
11. Also: does Camera2 or CameraX now expose any built-in HDR / multi-frame
    capture (e.g. HDR extension, ExtensionMode.HDR) that would make manual
    bracketing unnecessary? If so, what control do I retain over the output, and
    would it break photometric consistency between panorama frames?

Include device-specific caveats and prefer measured numbers over specs.
```

**Why it matters:** the entire HDR decision rests on the burst being fast. If it is
1.8 s rather than 0.3 s, the capture becomes intolerable on site and we fall back
to `ExposureStrategy.locked()`. Question 11 could also simplify Phase 05
considerably — or reveal a trap.

---

## R4 — Registration approach for low-texture interiors

```
I am stitching 25-35 photos into a 360x180 spherical panorama, captured by
rotating a tablet in place. I have IMU orientation priors accurate to ~1-3
degrees. Scenes are construction site interiors: large areas of bare drywall,
poured concrete, uniform ceiling tile, and repetitive formwork - i.e. very low
and/or repetitive texture.

Research and report on:

1. Feature detector/descriptor choice for LOW-TEXTURE indoor surfaces. Compare
   SIFT, AKAZE, ORB, and any learned detectors that are practical in C++ on
   mobile (SuperPoint, DISK, ALIKED, XFeat). For each: robustness on low texture,
   mobile CPU cost for ~30 x 0.6MP images, and licensing for commercial use.
   XFeat in particular is claimed to be fast enough for mobile - is that real?

2. Whether direct/photometric alignment (e.g. ECC, Lucas-Kanade, or
   phase correlation on a spherical parameterisation) outperforms feature
   matching for pure-rotation panoramas on low-texture input, given that I
   already have good rotation priors. Any published comparisons?

3. Best practice for INJECTING known rotation priors into a bundle adjustment for
   rotation-only panoramas. Specifically: is there a standard way to add a soft
   prior/regularisation term on each camera rotation in OpenCV's
   detail::BundleAdjusterRay, or would I need Ceres/g2o? How much does a prior
   term help versus just using the priors as initialisation?

4. Handling frames with ZERO reliable feature matches (a photo of nothing but
   blank drywall). What do production stitchers (Hugin, PTGui, Google Street View,
   Microsoft ICE) do? Is falling back to the IMU prior for that frame alone, while
   keeping it in the composite, the accepted approach?

5. Any recent (2023-2026) work on IMU-assisted or learning-based panorama
   stitching for handheld mobile capture that is practical to implement in C++.

6. Whether estimating a small radial distortion coefficient jointly in the bundle
   adjustment is worthwhile versus relying on a platform-supplied distortion
   model, for a phone main camera whose ISP may already apply correction.

Prefer papers with available implementations, and note licences.
```

**Why it matters:** low-texture interiors are the realistic failure case. The plan
already handles it (fall back to the IMU prior per frame, Phase 03 §4), but if
XFeat or a direct method is meaningfully better it is worth knowing before writing
the registration stage.


## How to hand findings back

Write each into `phases/findings/<ID>_<slug>.md` with:

```markdown
# R1 — OpenCV distribution

**Researched:** 2026-08-XX     **Sources:** (list, with dates)

## Answer
(the decision, stated in one paragraph)

## Evidence
(what the sources actually said — quote where the exact wording matters)

## Consequences for the plan
(which phase docs change, and how)

## Still unknown
(what only the Phase 00 spike can settle)
```

The "still unknown" section is the important one — it tells the Phase 00 spike
exactly what to measure instead of measuring everything.
