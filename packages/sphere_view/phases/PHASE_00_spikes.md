# Phase 00 — De-risking spikes

**Goal:** measure the things desk research could not, before writing a line of
production code.

**Duration:** 2–4 days. **Blocks:** Phases 03–07. **Does not block:** 01, 02.

Nothing in this phase ships. Every deliverable is a throwaway proof plus a
written finding. If a spike fails, the architecture changes — that is the point
of doing it first.

---

## Status: research is done, so these spikes are narrower than originally scoped

`R1`, `R2` and `R3` are complete (`phases/findings/`). They settled the *approach*
for all three areas and handed this phase a specific, shorter list of things that
can only be learned from hardware.

**Do not re-litigate the decisions.** Read the findings first, then measure only
what is listed as open.

| Spike | Research verdict | What is left to measure |
|---|---|---|
| A — OpenCV | Build from source, minimal module list, own FFI shim. Approach settled | 6 items: real size, flag defaults, 16 KB alignment, iOS `BUILD_LIST` mechanics |
| B — intrinsics | `videoFieldOfView` = horizontal ✅. Android distortion order ✅. But calibrated intrinsics likely **unavailable on every iPad** | Does `cameraIntrinsicMatrix` work on our iPads? Android null-rates |
| C — bracketing | Camera2 confirmed correct; native HDR unsuitable; AF/WB not auto-locked | **Burst wall-clock time — no published number exists anywhere.** The highest-priority measurement in the project |

**Priority order if time is short: C, then B, then A.** C gates a product decision
(does HDR survive?). B gates an accuracy assumption. A's approach is already known
to work; only its size is unmeasured.

---

## Spike A — Can we ship OpenCV with `stitching` to both platforms?

This is the highest-risk item in the project. See research item **R1**.

### What to prove

A Flutter app on a **real iPad** and a **real Android tablet** that calls, over
FFI, a C++ function which links OpenCV's `stitching` module and returns a
version string plus the result of instantiating each class we depend on:

```cpp
extern "C" const char* sv_spike_opencv_probe() {
    static std::string out;
    out  = cv::getVersionString();
    out += "|SIFT=";        out += cv::SIFT::create() ? "y" : "n";
    out += "|BA=";          { cv::detail::BundleAdjusterRay b; out += "y"; }
    out += "|GraphCut=";    { cv::detail::GraphCutSeamFinder g(
                                cv::detail::GraphCutSeamFinderBase::COST_COLOR_GRAD);
                              out += "y"; }
    out += "|MultiBand=";   { cv::detail::MultiBandBlender m(false, 5); out += "y"; }
    out += "|Spherical=";   { cv::detail::SphericalWarper w(1000.f); out += "y"; }
    out += "|Mertens=";     out += cv::createMergeMertens() ? "y" : "n";
    return out.c_str();
}
```

If any of these is missing from the build, that build option is dead.

### The approach is already decided — R1 settled it

`phases/findings/R1_opencv_distribution.md` closed the "which channel" question.
**Do not re-evaluate the options.** The answer:

> Build OpenCV from source with a minimal module list, and write our own thin
> `extern "C"` shim over the `cv::detail::` classes we need.

Because: official prebuilts are all-module "world" builds with no real
`.xcframework`; CocoaPods died at 4.3.0 in 2020; there is no official SPM package;
and `dartcv4`/`opencv_dart` binds only the high-level `cv::Stitcher` with **zero**
`cv::detail::` exposure and no way to force a full 360×180 canvas. That last point
is decisive — it is an **API gap, not a size or licensing gap**, so custom bindings
are required no matter which binaries we use.

Two good news items from R1 that remove risk from Phases 03–04:

- **`GraphCutSeamFinder` needs no external max-flow library** — OpenCV has its own
  in-house `GCGraph`. The "two extra weeks" fallback risk flagged in the original
  plan is **closed**.
- **Licensing is clean**: Apache 2.0 across the whole required module set. SIFT is
  patent-clear and in main-repo `features2d`; the graph-cut seam finder is an
  in-house Apache-2.0 reimplementation, *not* the GPL Kolmogorov–Zabih reference.

### The build recipe

Preferred path — **fork `nihui/opencv-mobile`** and flip three flags in its
per-version `cmake_options.txt`, reusing its size-optimised flags and iOS/Android
toolchain plumbing:

```
-DBUILD_opencv_stitching=ON      # currently OFF
-DBUILD_opencv_calib3d=ON        # currently OFF
-DBUILD_opencv_flann=ON          # default state unconfirmed — check first
```

Target module list either way:

```
core, imgproc, imgcodecs, flann, features2d, calib3d, photo, video, stitching
```

`videoio`, `objdetect`, `dnn`, `gapi`, `highgui`, `ml` are all confirmed
excludable.

**Build-mechanics asymmetry to plan around:** Android's `build_sdk.py` supports
`--modules_list` natively, mapping straight to `BUILD_LIST`. **iOS's
`build_framework.py` does not support `BUILD_LIST` at all** — it only exposes
`--without <module>`, one at a time. Three options: pass `--without` for every
excluded module, patch `getCMakeArgs()` with a one-line `BUILD_LIST` passthrough,
or bypass the script and invoke `cmake` + `ios.toolchain.cmake` directly. Try them
in that order of increasing effort and record which worked.

Also compare against `~/Documents/flutter-plugin-camera360/src/` — its
`src/android/CMakeLists.txt`, `src/ios/CMakeLists.txt` and
`src/*/opencv-build/build.sh` already produce a working OpenCV + FFI plugin on both
platforms, so its toolchain plumbing is worth lifting even if its module set is
wrong.

### The six open items R1 handed to this spike

1. **Real measured size** after adding `stitching` + `calib3d` + `flann` back to
   `opencv-mobile` — the whole size question is unanswered until this is measured.
2. `opencv-mobile`'s **default state for `flann` and `video`** — read the actual
   options file, do not assume.
3. **16 KB page alignment** on the real build output — mandatory for Google Play
   as of 2025. Verify with `readelf`/`objdump` on the produced `.so`, do not trust
   the NDK version alone.
4. Whether patching `build_framework.py`'s `BUILD_LIST` passthrough works cleanly
   end to end, versus invoking `cmake` directly.
5. The correct **iOS IPA-delta measurement method** — a static framework's on-disk
   size is meaningless; measure post-link, post-strip.
6. Whether `-Os` + `-ffunction-sections` + `--gc-sections` + LTO meaningfully
   shrink the static iOS link.

### Measurements to record

- installed size delta per ABI (`arm64-v8a`, `armeabi-v7a`) and iOS `arm64`
- cold-start time delta
- build time from clean
- 16 KB alignment verification output

### Acceptance

- [ ] All eight probes return `y` on both platforms, on real hardware
- [ ] Total installed size delta **≤ 25 MB per ABI** (raise deliberately if
      unavoidable — but decide, do not drift)
- [ ] All six open items above answered and appended to the R1 findings file
- [ ] The build is **scripted and reproducible from a clean checkout by someone
      who is not you**

### If it fails

Size unacceptable → drop `video` and `photo` if the Phase 05 fusion path can be
narrowed, and consider shipping `arm64-v8a` only (fine for iPads and any tablet
from the last six years). The algorithm-rewrite fallback is no longer a risk — R1
confirmed the full `detail::` pipeline ships inside OpenCV untouched.

---

## Spike B — Camera intrinsics on the real device fleet

R2 is done. It **resolved** two things that no longer need measuring:

- `videoFieldOfView` is **horizontal** FOV. Confirmed.
- Android `LENS_DISTORTION` is genuinely Brown–Conrady; the OpenCV mapping is a
  pure reorder `{κ1,κ2,κ4,κ5,κ3}`. Confirmed against AOSP.

It also found something that **changes the design**: full `AVCameraCalibrationData`
requires a multi-camera virtual device, which **excludes base iPad, iPad Air and
iPad mini outright**, and the newest iPad Pro may have dropped its second rear
lens. So on our fleet there may be **no** iPad with a calibrated-intrinsics path.

That makes the **top priority of this entire spike** a single question:

> **Does `AVCaptureConnection.cameraIntrinsicMatrix` (via
> `AVCaptureVideoDataOutput`, not photo output) actually deliver on our iPads?**

Its own docs impose no multi-camera requirement, but 2017–18 forum reports directly
conflict, including one explicitly claiming it does not work on iPad Pro. If it
fails, iOS falls back to FOV-derived `fx` with distortion left to bundle
adjustment — workable, but Phase 03 needs to know.

### What to prove

A debug screen that dumps, for every physical camera:

**Android**

```
cameraId, lensFacing, focalLengths[], SENSOR_INFO_PHYSICAL_SIZE,
SENSOR_INFO_ACTIVE_ARRAY_SIZE, SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE,
LENS_INTRINSIC_CALIBRATION (null?), LENS_DISTORTION (null? 5 values?),
largest JPEG size, largest 4:3 JPEG size,
→ derived fx, fy, HFOV, VFOV
```

**iOS**

```
uniqueID, deviceType, for each format:
  videoFieldOfView, photo dimensions, isHighestPhotoQualitySupported
isCameraCalibrationDataDeliverySupported
if supported: intrinsicMatrix, intrinsicMatrixReferenceDimensions,
              lensDistortionLookupTable length
→ derived fx, fy, HFOV, VFOV  (via BOTH interpretations of videoFieldOfView)
```

### The ground-truth FOV measurement

Still worth doing, now as a **cross-check on the derivation** rather than to settle
the horizontal-vs-diagonal question. Tape two marks on a wall, measure their
separation `s` and the perpendicular lens-to-wall distance `D`. Frame the marks
exactly at the left and right edges: `HFOV_true = 2·atan(s/(2D))`. Compare against
`videoFieldOfView` and against the physics-derived `fx`. Both should agree within
2%; a disagreement means the crop/aspect-fit term in §4.1 of the math doc is wrong.

### Acceptance

- [ ] Ran on the actual target devices (name each in the findings file)
- [ ] **`cameraIntrinsicMatrix` on `AVCaptureVideoDataOutput` — works or not,
      per iPad model.** The priority item
- [ ] Whether any current iPad has a dual/multi-camera rear system — if none do,
      delete the `AVCameraCalibrationData` path from Phase 06
- [ ] `LENS_INTRINSIC_CALIBRATION` / `LENS_DISTORTION` null-rate per Android device
- [ ] Whether `DISTORTION_CORRECTION_MODE` non-`OFF` exists anywhere on the fleet
- [ ] Physics-derived `fx` agrees with the measured FOV to **within 2%**
- [ ] Findings appended to `phases/findings/R2_intrinsics.md`

---

## Spike C — Bracketed burst capture  ← **HIGHEST-PRIORITY MEASUREMENT**

R3's headline result: **no source anywhere, official or community, publishes a
measured wall-clock time for a 3-frame full-resolution bracket on either
platform.** The ~600 ms budget the entire HDR strategy rests on is currently
supported by nothing. This is the single most load-bearing unmeasured number in
the project — if it comes back at 1.8 s, Phase 05 and Phase 06 both change and we
fall back to `ExposureStrategy.locked()`.

Measure this first, before the other two spikes if you have to choose.

R3 also confirmed and corrected several design points:

- ✅ **CameraX still has no bracketing API** (checked against 1.5, Nov 2025) —
  Camera2 remains correct. This was an assumption; it is now confirmed.
- ✅ **Native multi-frame HDR is not a substitute.** CameraX Extensions
  `ExtensionMode.HDR` returns a single already-fused, tone-mapped image with no
  per-frame control — exactly the photometric inconsistency we are avoiding.
- ⚠️ **Neither iOS bracket type locks focus or white balance.** Confirmed against
  Apple's own AVCamManual-Swift sample: bracket construction sets exposure values
  only. Phase 06 must call focus-lock and WB-lock **explicitly** before building
  any bracket. Also: a single bracket cannot mix AE and manual settings objects —
  mixing types raises an exception.
- ⚠️ **`maxBracketedCapturePhotoCount` is explicitly not a fixed number** — it
  varies with `sessionPreset` and `activeFormat`, and Apple publishes no per-device
  table. **Query it at runtime**; do not assume 3.
- ⚠️ **Open reliability risk:** Apple Developer Forums #749574 (unresolved, no
  Apple response) reports locked exposure/WB/focus values *silently drifting during
  capture* on iPad 8 and iPhone 15, with a workaround the reporter says fails on
  iPad 9 and iPhone 15. **Test for this explicitly** — it would undermine the AE
  lock that Phase 04's gain compensation assumes.

### What to prove

Three exposures at −2 / 0 / +2 EV from **one hardware burst**, with WB and focus
explicitly locked, and the wall clock from trigger to third frame.

**iOS** — `AVCapturePhotoBracketSettings`. Since we lock exposure via
`setExposureModeCustom`, use
`AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(duration:iso:)`
built from `currentExposureDuration`/`currentISO` — Apple's own sample shows custom
mode and manual brackets are designed to compose. Enable
`isLensStabilizationEnabled` where supported.

**Android** — Camera2 `captureBurst()` with three `CaptureRequest`s, fully manual
(`CONTROL_AE_MODE_OFF` + explicit `SENSOR_EXPOSURE_TIME`/`SENSOR_SENSITIVITY`).
Record `INFO_SUPPORTED_HARDWARE_LEVEL` **and** whether `MANUAL_SENSOR` is in
`REQUEST_AVAILABLE_CAPABILITIES` per device — R3 found no desk-research data on
this for our fleet, so a capability-dump utility across available hardware is the
only way to know.

**Also test on Android: YUV capture + deferred off-thread JPEG encode.** R3 found
evidence that **JPEG encoding, not sensor readout, is likely the dominant per-frame
latency**. If so, this alone could bring a failing burst inside budget, and it is
much cheaper than abandoning HDR.

### Measurements to record

- **trigger → 3rd frame wall clock** — the number the strategy rests on
- the same for YUV + deferred encode, on Android
- `maxBracketedCapturePhotoCount` per iPad model, at our actual format
- achieved EV separation vs requested
- whether WB/focus/exposure stayed genuinely fixed across the three — shoot a grey
  card and compare per-channel means; this also tests for the #749574 drift bug
- inter-frame hand drift from the gyro over the burst (feeds Phase 05 §3)
- `INFO_SUPPORTED_HARDWARE_LEVEL` + `MANUAL_SENSOR` per Android device

### Acceptance

- [ ] 3-frame burst works on both platforms, on real hardware
- [ ] **Burst wall clock measured and recorded** — a number, per device
- [ ] Achieved EV separation within 0.3 EV of requested
- [ ] Grey-card test confirms no locked-value drift (or documents that it occurs)
- [ ] `maxBracketedCapturePhotoCount` recorded per device
- [ ] Devices needing the single-exposure path listed by name
- [ ] Findings appended to `phases/findings/R3_bracketing.md`

### If it fails

Burst too slow or unsupported → fall back to `ExposureStrategy.locked()`. The
architecture already carries `shots: List<ExposureShot>` per position, so a
single-element list needs **no structural change** — this is exactly why §6.4 of
the architecture chose that model, and why Phase 05 §6 requires the single-shot
path to be a verified no-op. The cost is dynamic range in interiors, not a rewrite.

Intermediate option before giving up: 2-shot bracket (0 / +2 EV) instead of 3.
Mertens fuses any stack size, and two frames recovers most of the shadow detail.

---

## Phase deliverables

```
phases/findings/R1_opencv_distribution.md
phases/findings/R2_intrinsics.md
phases/findings/R3_bracketing.md
spikes/                      ← throwaway; delete after the findings are written
```

Each findings file must state: **what was measured, on which devices, and what
we decided.** A finding without a device name is not a finding.

---

## Exit criteria for Phase 00

- [ ] All three findings files written and committed
- [ ] The OpenCV build recipe reproduces from clean on both platforms
- [ ] Any architecture change implied by a failed spike is reflected in
      `00_ARCHITECTURE.md` **before** Phase 03 starts
