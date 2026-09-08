# R2 — Camera intrinsics and distortion

**Researched:** 2026-08-06
**Sources:** developer.android.com/reference/android/hardware/camera2/CameraCharacteristics (LENS_INTRINSIC_CALIBRATION, LENS_DISTORTION, SENSOR_INFO_ACTIVE_ARRAY_SIZE, SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE, DISTORTION_CORRECTION_MODE/AVAILABLE_MODES), developer.android.com/reference/.../CaptureRequest#SCALER_CROP_REGION, AOSP `system/media/camera/docs/docs.html`, `github.com/rpview/android-camera-calibration` issue #3 (community), developer.apple.com/documentation/avfoundation (Format.videoFieldOfView, geometricDistortionCorrectedVideoFieldOfView, AVCameraCalibrationData, lensDistortionLookupTable, AVCaptureDevice/AVCapturePhotoOutput/AVCapturePhotoSettings distortion-correction properties), Apple Developer Forums threads #741815 (Apple engineer response) and #82668 (2017-2018, flagged as dated/unverified), Apple's AVCamManual-Swift sample code.

## Answer

**Android:** `LENS_DISTORTION` genuinely is the Brown-Conrady model (AOSP docs state this explicitly), so no value transform is needed to feed `cv::undistort` — only a **coefficient reordering**: `cv::Mat distCoeffs = {kappa_1, kappa_2, kappa_4, kappa_5, kappa_3}` (OpenCV's `k1,k2,p1,p2,k3` = Android's `kappa_1,kappa_2,kappa_4,kappa_5,kappa_3`). Both `LENS_DISTORTION` and `LENS_INTRINSIC_CALIBRATION` are optional and may be null on any device (confirmed even on Pixel hardware); derive fx/fy/cx/cy primarily from focal length + physical sensor size + crop region + output scale (formula below), treating `LENS_INTRINSIC_CALIBRATION` as an optional override when present. Always explicitly request `DISTORTION_CORRECTION_MODE_OFF` and anchor every coordinate (crop region, distortion coefficients, principal point) to `preCorrectionActiveArraySize` — this keeps the whole geometry pipeline self-consistent in one coordinate frame and sidesteps the HAL's own auto-correction, which AOSP's own docs admit is imprecise.

**iOS:** Full `AVCameraCalibrationData` (intrinsic matrix + lens distortion lookup table via `AVCapturePhotoOutput`) is **only available on multi-camera "virtual device" configurations** — confirmed by an Apple engineer. This excludes base iPad, iPad Air, and iPad mini outright (single rear lens), leaving only dual/multi-camera iPad Pro models as candidates — and even that is now in question, since a 2025 report claims the newest iPad Pro may have dropped its second rear lens. The documented fallback for single-lens devices, `AVCaptureConnection.cameraIntrinsicMatrix` via `AVCaptureVideoDataOutput` (not photo output), is not gated by the same multi-camera requirement per its own docs — but old, directly-contradicting forum threads (2017-2018) dispute whether it even works on iPad Pro. **This is the single highest-priority item for the Phase 00 spike**: on the actual target iPad lineup, neither the primary nor the fallback intrinsics path is confirmed to work, and if both fail, the only remaining option is deriving fx from `videoFieldOfView` (confirmed HORIZONTAL FoV) and assuming the ISP's default geometric correction as a black box (with distortion refined only via bundle adjustment — ties into R4).

## Evidence

### Android

**1. `LENS_INTRINSIC_CALIBRATION` gating.** No `REQUEST_AVAILABLE_CAPABILITIES` flag or hardware level gates this key. Docs, verbatim: *"Optional - The value for this key may be null on some devices."* No `CAPABILITIES_INTRINSIC_CALIBRATION`-style flag exists anywhere in the AOSP metadata docs. Community report (`rpng/android-camera-calibration#3`, 2018): null/zeroed even on a Google Pixel. Treat as frequently null on mid-range/rugged tablets — no device-specific prevalence data exists (see Still unknown).

**2. `LENS_DISTORTION` model and OpenCV mapping.** AOSP docs, verbatim (API 28+): *"Three radial distortion coefficients `[kappa_1, kappa_2, kappa_3]` and two tangential distortion coefficients `[kappa_4, kappa_5]`... `x_c = x_i*(1 + kappa_1*r² + kappa_2*r⁴ + kappa_3*r⁶) + kappa_4*(2*x_i*y_i) + kappa_5*(r² + 2*x_i²)`... **The distortion model used is the Brown-Conrady model.**"* Term-by-term comparison against OpenCV's model (`x' = x(1+k1r²+k2r⁴+k3r⁶) + 2p1xy + p2(r²+2x²)`) shows a direct 1:1 correspondence — Android orders as `[R,R,R,T,T]`, OpenCV as `[R,R,T,T,R]`. **This resolves the conflicting community claims: it's a coefficient permutation, not a mathematical model conversion.** Android's equation also defines `(x_c,y_c)` as the undistorted→distorted backward mapping, the same convention `cv::undistort`/`cv::initUndistortRectifyMap` use internally — so the reordered coefficients drop straight in with no further math. Both `LENS_DISTORTION` and `LENS_INTRINSIC_CALIBRATION` share the "optional, may be null" caveat.

**3. Deriving fx/fy/cx/cy in output-image pixels.**
```
pixel_pitch_x = physicalSize.width_mm  / pixelArraySize.width_px
pixel_pitch_y = physicalSize.height_mm / pixelArraySize.height_px
fx_sensor = focalLength_mm / pixel_pitch_x
fy_sensor = focalLength_mm / pixel_pitch_y
cx_sensor, cy_sensor = center of preCorrectionActiveArraySize (or LENS_INTRINSIC_CALIBRATION if present)

cx_crop = cx_sensor - cropRect.left;  cy_crop = cy_sensor - cropRect.top   (fx/fy unchanged by cropping)

# aspect-fit sub-rect of the crop region per SCALER_CROP_REGION's own letterbox/pillarbox rule, then scale:
scaleX = outputWidth_px  / streamSourceRect.width
scaleY = outputHeight_px / streamSourceRect.height
fx_out = fx_crop * scaleX;  fy_out = fy_crop * scaleY
cx_out = (cx_crop - streamSourceRect.left) * scaleX
cy_out = (cy_crop - streamSourceRect.top)  * scaleY
```
**Worked example** (focal length 4.25mm, sensor 5.76×4.32mm, active array 4032×3024, crop = full array, output 1920×1080): `pixel_pitch = 0.0014286 mm/px` → `fx_sensor = fy_sensor = 2975.0 px`. 16:9 output vs. 4:3 crop region → per `SCALER_CROP_REGION`'s own worked examples, the stream keeps full width and letterboxes vertically: `streamSourceRect = (left=0, top=378, w=4032, h=2268)`. `scale = 1920/4032 = 0.47619` → **`fx = fy = 1416.7 px`; `cx = 960.0 px`; `cy = 540.0 px`** (cx/cy land exactly at image center, the expected sanity check for a centered crop).

**4. Pre-correction vs. regular active array.** Confirmed directly from AOSP docs: `SENSOR_INFO_ACTIVE_ARRAY_SIZE`, verbatim: *"For devices that do not support `android.distortionCorrection.mode` control, the active array must be the same as `android.sensor.info.preCorrectionActiveArraySize`."* `LENS_INTRINSIC_CALIBRATION` doc, verbatim: coordinates are defined in the `preCorrectionActiveArraySize` system, and after applying pose/intrinsics/distortion, results must be adjusted into `activeArraySize` for non-RAW output. `DISTORTION_CORRECTION_AVAILABLE_MODES`, verbatim: *"No device is required to support this API; such devices will always list only 'OFF'."* **Practical consequence:** on devices without `DISTORTION_CORRECTION_MODE` support (likely most mid-range/rugged tablets), the two arrays are identical and the distinction is moot; on devices that do support it, explicitly request `DISTORTION_CORRECTION_MODE_OFF` so `SCALER_CROP_REGION` and everything else stays in the `preCorrectionActiveArraySize` frame — the same AOSP doc admits the HAL's own auto-correction mapping *"is not very precise, since rectangles do not generally map to rectangles when corrected."*

### iOS

**5. `videoFieldOfView`.** HORIZONTAL field of view in degrees (0 if unknown); a fixed property of the selected `AVCaptureDevice.Format` regardless of which output (photo/video) is attached. Related, separately-gated: `geometricDistortionCorrectedVideoFieldOfView` (iOS 13+) — the FoV *after* GDC is applied; equals `videoFieldOfView` if the device doesn't support GDC, differs when GDC is active (default on ultra-wide lenses). For a fixed-intrinsics model, use `videoFieldOfView` with GDC explicitly disabled (§8), not the GDC-corrected variant.

**6. `AVCameraCalibrationData` gating.** Confirmed via an Apple engineer's forum response (#741815): full calibration data delivery via `AVCapturePhotoOutput` requires **all** of: `virtualDeviceConstituentPhotoDeliveryEnabled = YES` (a multi-camera "virtual device" — dual/dual-wide/triple), `contentAwareDistortionCorrectionEnabled = NO`, `geometricDistortionCorrectionEnabled = NO`. Quote: *"Camera calibration data delivery (of which intrinsics are a part) is currently only supported when GDC is off, unfortunately."* **No degraded single-lens mode exists — it's simply unavailable there.** Among iPads, this restricts eligibility to dual/multi-camera iPad Pro models (11"/12.9" 3rd gen 2018 onward); base iPad, iPad Air, and iPad mini are excluded outright. A 2025 report (unverified, flag for confirmation) claims the newest OLED iPad Pro dropped its ultra-wide/second lens, which — if true — would mean **no current iPad qualifies for full calibration data delivery at all.**

Separate fallback for single-lens devices: `AVCaptureConnection.isCameraIntrinsicMatrixDeliverySupported`/`cameraIntrinsicMatrixDeliveryEnabled` via `AVCaptureVideoDataOutput` (not `AVCapturePhotoOutput`) delivers `cameraIntrinsicMatrix` (focal length + principal point in pixels) as a `CMSampleBuffer` attachment per frame; its own doc states support depends only on *"both the connection's input device format and output class support[ing] delivery of camera intrinsics"* — no explicit multi-camera requirement. **However**, dated (2017-2018) forum threads (#82668) directly conflict on this: one claims it breaks with video stabilization enabled, another reports it works regardless of stabilization on iPhone X/7 Plus but **explicitly "does not work on an iPad Pro."** Flagged as folklore/unverified against current hardware — this is the top empirical item for Phase 00.

**7. `lensDistortionLookupTable`.** A 1D array of float magnification factors, evenly distributed along a radius from `lensDistortionCenter` to the image corner — **purely radial, no tangential component**; `inverseLensDistortionLookupTable` is the reverse-direction counterpart. No Apple-published closed-form rectification algorithm was found beyond this description. Community best practice (not Apple-documented): sample the LUT at N radii, compute normalized `r` and its magnified counterpart `r'`, then least-squares fit `r'/r = 1 + k1·r² + k2·r⁴ + k3·r⁶` — with **p1 = p2 = 0 forced**, since Apple's model provides no basis for tangential terms.

**8. Automatic geometric/content-aware correction.** Confirmed current API surface: `AVCaptureDevice.isGeometricDistortionCorrectionSupported`/`Enabled` (device-level; on by default for ultra-wide lenses), `AVCapturePhotoOutput.isContentAwareDistortionCorrectionSupported`/`Enabled` (pipeline-level), `AVCapturePhotoSettings.isAutoContentAwareDistortionCorrectionEnabled` (per-capture-request). Apple's own doc phrasing — *"the photo output, at its discretion, uses content-aware distortion correction"* — confirms variable, content-dependent application, which **invalidates a fixed intrinsics model if left enabled**. To fully disable: set all three to `false`/off on every capture. This is the same precondition §6 requires for calibration-data delivery — a fixed-model pipeline and GDC-corrected images are mutually exclusive on `AVCapturePhotoOutput` either way, so disabling correction is mandatory regardless of which intrinsics path is used.

## Consequences for the plan

- **Phase 06 (platform camera)** needs two independent, platform-specific intrinsics acquisition paths, not one shared abstraction:
  - **Android:** derive fx/fy/cx/cy from focal length + physical size + crop region + output scale (formula above) as the primary path; use `LENS_INTRINSIC_CALIBRATION` only as an optional override when non-null. Always request `DISTORTION_CORRECTION_MODE_OFF` and keep all geometry (crop region, distortion coefficients) in the `preCorrectionActiveArraySize` frame. Apply `LENS_DISTORTION` via the exact reordering `distCoeffs = {kappa_1, kappa_2, kappa_4, kappa_5, kappa_3}`.
  - **iOS:** attempt `AVCameraCalibrationData` only on confirmed dual/multi-camera devices; on single-lens iPads, attempt `AVCaptureConnection.cameraIntrinsicMatrix` via `AVCaptureVideoDataOutput` as the fallback, but do not assume it works without on-device confirmation. If neither path delivers data on a given target device, fall back to `videoFieldOfView`-derived fx and a distortion-free (or bundle-adjustment-refined) model. In all cases, disable `isGeometricDistortionCorrectionEnabled`, `isContentAwareDistortionCorrectionEnabled`, and `isAutoContentAwareDistortionCorrectionEnabled` before capture.
- This affects the accuracy claims in **Phases 03/04** (registration/compositing): the plan cannot assume a single reliable intrinsics source on iOS across the iPad fleet — the registration stage should be designed to tolerate an intrinsics-quality gradient (calibrated dual-cam iPad Pro > intrinsic-matrix-only iPad > FoV-derived-only iPad), not a uniform input.
- The distortion model mismatch between platforms is now resolved with no unknowns on the Android side (exact reordering, no value transform) — the previously-flagged risk of "wrong order actively degrading frames" is closed for Android. iOS's distortion model is inherently radial-only from the lookup table, so p1/p2 should be fixed at zero there rather than fit.

## Still unknown

1. **Whether `AVCaptureConnection.cameraIntrinsicMatrix` actually works on the specific target iPad models** (Pro, Air, mini, base) — old forum evidence directly conflicts, including a claim it doesn't work on iPad Pro at all. Top-priority Phase 00 measurement.
2. **Whether the current-generation iPad Pro still has a dual/multi-camera system** — a 2025 report claims it doesn't. Confirm against the actual target device lineup before assuming `AVCameraCalibrationData` is available on any iPad.
3. **Real-world null-rate of `LENS_INTRINSIC_CALIBRATION`/`LENS_DISTORTION` on the actual Android fleet** (Galaxy Tab A series, Zebra/Honeywell/Panasonic rugged tablets) — no device-specific data exists; only generic "often null even on Pixel" anecdote.
4. **Whether `DISTORTION_CORRECTION_MODE` is supported at all (non-OFF-only) on any target Android tablet**, and whether `activeArraySize` differs from `preCorrectionActiveArraySize` in practice on those specific devices.

---

# Phase 00 Spike B — harness built, measurements pending hardware

**Written:** 2026-08-06
**Spike code:** `spikes/spike_bc_device/` (throwaway Flutter app, compiles
clean for both platforms)
**Status:** no devices were attached to the session that built this. Every
number below marked *pending* needs one run of the app per device.

## What the harness measures

One app, one button, one JSON report per device. Device identity is captured
automatically — `Build.MANUFACTURER`/`MODEL`/`DEVICE` on Android, the `utsname`
machine identifier (`iPad14,3`, not the ambiguous marketing name) on iOS — so no
finding can end up without a device name attached.

**Android** (`android/.../CameraProbe.kt`), per physical camera:
focal lengths, `SENSOR_INFO_PHYSICAL_SIZE`, pixel-array / active-array /
`preCorrectionActiveArraySize` (plus an explicit `activeArraysDiffer` flag),
`LENS_INTRINSIC_CALIBRATION`, `LENS_DISTORTION`,
`DISTORTION_CORRECTION_AVAILABLE_MODES`, hardware level, capabilities,
timestamp source, JPEG/YUV size lists with per-format stall durations, and the
derived `fx/fy/cx/cy/HFOV/VFOV`.

Three details worth noting, because they are where this kind of dump usually
goes wrong:

- The null-rate questions are recorded as `lensIntrinsicCalibration_isNull`
  **and** `_isAllZero`. The community report R2 cites ("null/zeroed even on a
  Pixel") describes both failure shapes, and a present-but-zeroed key is just as
  useless as a null one while looking like success.
- `LENS_DISTORTION` is emitted *both* raw and pre-reordered as
  `lensDistortion_asOpenCV_k1k2p1p2k3`, applying R2's `{κ1,κ2,κ4,κ5,κ3}`
  mapping, so the result can be pasted straight into a Phase 06 test fixture.
- The derivation implements the **full** R2 §3 formula including the
  crop/aspect-fit term, not the naive `focal/pitch` shortcut. It also reports
  `hfovDeg_portrait`, since capture is portrait-locked and that is the number
  Phase 08's ring planner actually consumes.

**iOS** (`ios/Runner/CameraProbeIOS.swift` + `IntrinsicsSpike.swift`):
device enumeration including a dedicated multi-camera discovery pass, per-format
`videoFieldOfView`, `geometricDistortionCorrectedVideoFieldOfView`,
`supportedMaxPhotoDimensions`, and the photo-output calibration gates.

## The priority question is instrumented to answer, not to report a flag

R2 named one item as top priority: does
`AVCaptureConnection.cameraIntrinsicMatrix` via `AVCaptureVideoDataOutput`
actually deliver on our iPads?

`IntrinsicsSpike.swift` deliberately does **not** stop at
`isCameraIntrinsicMatrixDeliverySupported`. Reporting that flag is precisely the
mistake that has left this question open since 2017. Instead it enables
delivery, runs real frames through a `AVCaptureVideoDataOutputSampleBufferDelegate`,
and checks whether `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` is
actually attached to the buffers. The headline field is
`ATTACHMENT_ACTUALLY_ARRIVED`.

It runs the whole test **twice, with video stabilization off and on**, because
that is the specific variable the conflicting 2017–18 forum reports disagree
about (#82668: one report blames stabilization, another says it works regardless
but "does not work on an iPad Pro").

When the matrix does arrive it also records:

- `fx_percentDisagreement` — measured `fx` against `videoFieldOfView`-derived
  `fx`. This is the number that tells us how much Phase 03 actually loses by
  falling back to path 3.
- `cx_over_width` / `cy_over_height` — a principal point far from 0.5 means the
  matrix is expressed for a different reference size than the buffer.
- `fx_isConstantAcrossFrames` — intrinsics must be fixed for a fixed format;
  drift would mean the ISP is varying its correction frame to frame.

## Multi-camera iPads: expected dead, confirm with the dump

R2 flagged an unverified 2025 report that the newest iPad Pro dropped its second
rear lens. To the best of my knowledge that is correct and the situation is
worse than "the newest": **no current iPad ships a multi-camera rear system.**
The M4 iPad Pro (2024) dropped the ultra-wide that the M2 iPad Pro carried, and
iPad Air, iPad mini and base iPad have always been single-lens. The last
qualifying device was the 2022 M2 iPad Pro.

I am flagging this as **high-confidence but not measured** — it is a
product-lineup claim, and product lineups are exactly the thing to verify rather
than assert. The dump settles it empirically per device via
`hasAnyRearMultiCamera` and `multiCameraDevices`.

**If it holds, the consequence is already decided by R2:** delete the
`AVCameraCalibrationData` path from Phase 06 entirely. It also raises the stakes
on the priority question above — with path 1 gone, `cameraIntrinsicMatrix` is
the *only* measured-intrinsics path that exists on our entire iOS fleet, and if
it fails too, every iPad falls to FOV-derived `fx` with distortion left to
bundle adjustment.

## The FOV cross-check

Kept as PHASE_00 specifies — a cross-check on the derivation, not a way to
settle horizontal-vs-diagonal, which R2 already closed. The iOS report emits
`derived_fx_horizontal` **and** `derived_fx_ifDiagonal` side by side, so the
wall measurement discriminates between the two readings conclusively rather than
merely being consistent with the accepted one. Procedure and the 2% acceptance
threshold are in `spikes/README.md`.

## Acceptance status

- [ ] Ran on the actual target devices — **pending hardware**
- [ ] `cameraIntrinsicMatrix` works or not, per iPad model — **pending**, harness ready
- [ ] Whether any current iPad has a dual/multi-camera rear system — **expected no** (see above), harness confirms
- [ ] `LENS_INTRINSIC_CALIBRATION` / `LENS_DISTORTION` null-rate per Android device — **pending**
- [ ] Whether `DISTORTION_CORRECTION_MODE` non-`OFF` exists anywhere — **pending**
- [ ] Physics-derived `fx` agrees with measured FOV within 2% — **pending**, derivation implemented and emitted
