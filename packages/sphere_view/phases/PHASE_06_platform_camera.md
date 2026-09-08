# Phase 06 — Platform camera plugin (iOS + Android)

**Goal:** a camera we actually control — real intrinsics, hard AE/AWB/AF lock,
bracketed hardware burst, and shutter timestamps on the same clock as the pose
stream.

**Duration:** 7–9 days. **Depends on:** 00 (Spikes B, C), 01.

No existing Flutter camera plugin exposes what this pipeline needs. `camera`,
`camerawesome`, and `CameraX` all abstract away exactly the controls that matter:
exposure bracketing, intrinsics, and frame timestamps. So we write a focused
plugin instead of fighting one.

---

## 1. Interface (Pigeon)

Use `pigeon` for type-safe channel generation — hand-written `MethodChannel`
string keys are a recurring source of silent breakage across two platforms.

```dart
// pigeons/camera_api.dart
@HostApi()
abstract class SphereCameraHostApi {
  List<CameraDescriptor> listCameras();
  CameraOpenResult open(String cameraId, CaptureFormatRequest format);
  int  attachPreview();                 // returns the Flutter texture id
  MeteringResult meterAndLock(double durationSeconds);
  void unlock();
  CaptureResponse captureBracket(List<double> evBiases);
  void close();
  ThermalState thermalState();
}

@FlutterApi()
abstract class SphereCameraFlutterApi {
  void onFrameAvailable(int timestampUs);       // for preview-time pose pairing
  void onError(String code, String message);
  void onThermalStateChanged(ThermalState state);
}
```

`CameraDescriptor` carries the full intrinsics block from Phase 01 §3.1 plus
`hardwareLevel` / `supportsBracketing`, so the Dart side can decide the plan and
the exposure strategy from real capability rather than guessing.

---

## 2. Android — Camera2

**Camera2, not CameraX.** CameraX does not expose `captureBurst` with per-request
exposure control, nor reliable per-frame intrinsics. We need both.

### 2.1 Camera selection

Enumerate `cameraManager.cameraIdList`, filter `LENS_FACING_BACK`, then pick the
main camera: the one whose `LENS_INFO_AVAILABLE_FOCAL_LENGTHS[0]` is **not** the
shortest (that is the ultra-wide) and which offers the largest 4:3 JPEG. The user
decided main-camera-only, so ultra-wide is explicitly excluded — but log what was
skipped, since a future config may want it.

Prefer a **4:3** output: it matches the sensor's full active array, so no crop
factor enters the intrinsics (§4.1 of the math doc), and it gives the largest
vertical FOV, which directly reduces the number of rings.

### 2.2 Intrinsics

Implement §4.1 of [01_MATH_AND_CONVENTIONS.md](01_MATH_AND_CONVENTIONS.md) exactly,
and always report which branch was taken via `IntrinsicsSource`.

Per the **R2 finding**, note two reversals from the obvious approach:

1. **Physics derivation is the primary path**, not `LENS_INTRINSIC_CALIBRATION`.
   That key is gated by no capability flag, is documented as "may be null on some
   devices", and has been reported null even on Pixel hardware. Use it only as an
   override when non-null.
2. **`LENS_DISTORTION` is safe to apply** — R2 confirmed against AOSP that it is
   genuinely Brown–Conrady, and the OpenCV mapping is a pure reorder with no value
   transform:
   ```
   distCoeffs = { kappa_1, kappa_2, kappa_4, kappa_5, kappa_3 }
   //             k1        k2        p1        p2        k3
   ```
   The previously-flagged "wrong order makes distortion worse" risk is closed.

Always request `DISTORTION_CORRECTION_MODE_OFF`, and anchor the crop region,
principal point and distortion coefficients to
`SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE`. AOSP's own docs concede the HAL's
correction is imprecise ("rectangles do not generally map to rectangles when
corrected"), and keeping one coordinate frame throughout is what makes the geometry
self-consistent.

### 2.3 Metering pre-sweep and lock

```
1. CONTROL_AE_MODE_ON, CONTROL_AWB_MODE_AUTO, CONTROL_AF_MODE_CONTINUOUS_PICTURE
2. Let the user pan the sphere for `durationSeconds` while we record the
   converged AE results (SENSOR_EXPOSURE_TIME, SENSOR_SENSITIVITY) each frame.
3. Choose the target exposure: the ~65th percentile of the observed EV
   distribution, not the mean. Interiors are mostly mid-tone with a few very
   bright windows; the mean is dragged bright by the windows and crushes the
   interior.
4. Lock:  CONTROL_AE_MODE_OFF + explicit SENSOR_EXPOSURE_TIME / SENSOR_SENSITIVITY
          CONTROL_AWB_MODE_OFF + explicit COLOR_CORRECTION_GAINS / TRANSFORM
          CONTROL_AF_MODE_OFF  + explicit LENS_FOCUS_DISTANCE
5. Also pin: NOISE_REDUCTION_MODE, EDGE_MODE, TONEMAP_MODE, COLOR_CORRECTION_MODE
```

Step 5 is easy to miss and matters: if the ISP's tonemap or noise reduction is in
an adaptive mode, it varies per frame and reintroduces exactly the photometric
inconsistency the AE lock was meant to remove. Pin them to fixed modes.

**Focus distance:** lock to a distance that keeps the whole scene acceptably
sharp — roughly the hyperfocal distance. For a phone lens this is often 2–3 m;
locking to infinity softens near objects, locking to macro ruins everything else.
Choose from the metering sweep's observed AF results, then fix it.

`meterAndLock` returns the chosen exposure so the Dart side can compute exact EV
biases for the bracket.

### 2.4 Bracketed burst

```kotlin
val requests = evBiases.map { ev ->
    builder.apply {
        set(CaptureRequest.SENSOR_EXPOSURE_TIME, (baseExposureNs * 2.0.pow(ev)).toLong())
        set(CaptureRequest.SENSOR_SENSITIVITY, baseIso)   // vary TIME, not ISO
    }.build()
}
session.captureBurst(requests, callback, handler)
```

**Vary exposure time, not ISO.** Changing ISO changes the noise characteristics
between shots, which confuses both the fusion weighting and the ghost detector.
Changing time keeps noise consistent. Exception: if the required time exceeds the
motion-blur limit (~1/60 s), clamp it and take the remaining stops from ISO,
recording what actually happened in `ExposureShot`.

Gate on **`MANUAL_SENSOR` in `REQUEST_AVAILABLE_CAPABILITIES`**, not on
`INFO_SUPPORTED_HARDWARE_LEVEL` alone — R3 found no fleet data for either, so
record both per device. Fall back to `CONTROL_AE_EXPOSURE_COMPENSATION` where manual
control is missing, and to single-exposure if even that is unavailable.

**Also implement YUV capture + deferred off-thread JPEG encode as an option here.**
R3 found evidence that JPEG encoding, not sensor readout, is likely the dominant
per-frame latency. If Spike C's measured burst time misses the 600 ms budget, this
is the cheapest way to recover it — far cheaper than abandoning HDR. Build it behind
a flag so the spike can A/B the two.

**Do not use CameraX Extensions `ExtensionMode.HDR`** as a shortcut. R3 confirmed it
returns a single already-fused, tone-mapped image with no per-frame control — which
reintroduces exactly the photometric inconsistency between panorama frames that the
locked-exposure design exists to prevent.

### 2.5 Timestamps — the critical detail

`TotalCaptureResult.get(CaptureResult.SENSOR_TIMESTAMP)` is in the time base named
by `SENSOR_INFO_TIMESTAMP_SOURCE`:

- `TIMESTAMP_SOURCE_REALTIME` → same base as `SystemClock.elapsedRealtimeNanos()`,
  which is also the base of `SensorEvent.timestamp`. **Directly comparable.**
- `TIMESTAMP_SOURCE_UNKNOWN` → base is `System.nanoTime()`, which is *not* the
  sensor base. An offset must be estimated.

Read `SENSOR_INFO_TIMESTAMP_SOURCE` and handle both. When it is `UNKNOWN`,
estimate the offset once at session start by sampling both clocks in a tight loop
and taking the minimum observed difference. Report the residual uncertainty.

Getting this wrong is a silent 10–50 ms pose/frame mismatch. At a realistic 60°/s
pan that is **0.6–3° of rotation error**, larger than everything Phase 03 works to
remove — and it will look like a stitcher bug.

---

## 3. iOS — AVFoundation

### 3.1 Session

`AVCaptureSession` with `.photo` preset, device
`.builtInWideAngleCamera` (main), `AVCapturePhotoOutput`. Preview to Flutter via
a `CVPixelBuffer` → `FlutterTexture`.

### 3.2 Intrinsics — expect the worst case

The **R2 finding changes this section materially**: full `AVCameraCalibrationData`
requires a *multi-camera virtual device*, confirmed by an Apple engineer. That
**excludes base iPad, iPad Air and iPad mini outright**, and a 2025 report suggests
the newest iPad Pro dropped its second rear lens. So there may be **no iPad in our
fleet with a calibrated-intrinsics path at all.**

Implement all three tiers of §4.2 of the math doc, in order, and expect to land on
tier 3:

1. `AVCameraCalibrationData.intrinsicMatrix` — only attempt when
   `isCameraCalibrationDataDeliverySupported`. Requires
   `virtualDeviceConstituentPhotoDeliveryEnabled` plus GDC and content-aware
   correction off. Rescale from `intrinsicMatrixReferenceDimensions`.
2. `AVCaptureConnection.cameraIntrinsicMatrix` via **`AVCaptureVideoDataOutput`**
   (not photo output) — delivered as a `CMSampleBuffer` attachment per frame. Its
   docs impose no multi-camera requirement, but **whether it works on iPad is
   unconfirmed and contested** (Spike B's top item). Treat a missing attachment as
   normal and fall through.
3. `videoFieldOfView` — **confirmed horizontal FOV** (R2), so
   `fx = (W/2)/tan(FOV/2)`. Use this and *not*
   `geometricDistortionCorrectedVideoFieldOfView`, which describes the post-GDC
   frame and only applies while GDC is on.

**Distortion on iOS is radial-only.** `lensDistortionLookupTable` is magnification
factors along the radius from `lensDistortionCenter`, with no tangential component.
Fit `r'/r = 1 + k1·r² + k2·r⁴ + k3·r⁶` over sampled radii and **force p1 = p2 = 0** —
fitting tangential terms against a purely radial model is fitting noise. When the
LUT is unavailable (tier 3), report `distortion: null` and let bundle adjustment
absorb what it can.

Because intrinsics quality is a gradient rather than a constant, `IntrinsicsSource`
must reach `StitchReport` — it is how a soft panorama gets traced to a weak
intrinsics path instead of being blamed on the stitcher.

### 3.3 Lock

```swift
try device.lockForConfiguration()
device.setExposureModeCustom(duration: chosenDuration, iso: chosenISO)   // locks AE
device.whiteBalanceMode = .locked
device.setFocusModeLocked(lensPosition: chosenLensPosition)
device.isSubjectAreaChangeMonitoringEnabled = false
device.videoHDREnabled = false                 // we do our own HDR
device.automaticallyAdjustsVideoHDREnabled = false
device.unlockForConfiguration()
```

Disabling the device's own HDR is essential: leaving it on means the ISP applies
its own per-frame tonemapping, which both fights our bracket and breaks
photometric consistency.

Also set `photoSettings.photoQualityPrioritization = .quality` and disable any
automatic content-aware processing (`isAutoContentAwareDistortionCorrectionEnabled
= false`) — Apple's distortion correction is applied *variably*, which invalidates
a fixed intrinsics model. Turning it off and modelling distortion ourselves is
the whole point of measuring intrinsics.

### 3.4 Bracket

```swift
let settings = AVCapturePhotoBracketSettings(
    rawPixelFormatType: 0,
    processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg],
    bracketedSettings: evBiases.map {
        AVCaptureAutoExposureBracketedStillImageSettings
            .autoExposureSettings(exposureTargetBias: Float($0))
    })
settings.isLensStabilizationEnabled = photoOutput.isLensStabilizationDuringBracketedCaptureSupported
photoOutput.capturePhoto(with: settings, delegate: self)
```

**R3 resolved the AE-vs-manual tension.** Since we lock exposure with
`setExposureModeCustom`, use
`AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(duration:iso:)`
built from `device.currentExposureDuration` / `device.currentISO`. Apple's own
AVCamManual-Swift sample does exactly this — it checks
`if device.exposureMode == .custom` and switches to manual bracket settings — so the
two are designed to compose. A single bracket **cannot mix** AE and manual settings
objects; mixing types raises an exception.

Three R3 findings that are easy to get wrong:

1. **Neither bracket type locks focus or white balance.** Confirmed against Apple's
   sample: bracket construction sets exposure values only. Call the focus-lock and
   WB-lock methods **explicitly, before** building the bracket. Forgetting this
   looks like a stitcher problem later, as colour and focus banding.
2. **`maxBracketedCapturePhotoCount` is not a fixed number** — it varies with
   `sessionPreset` and `activeFormat`, and Apple publishes no per-device table.
   **Query it at runtime** and fall back to a 2-shot bracket, then to sequential
   single shots with manual exposure changes, if it returns < 3.
3. **Known open reliability risk:** Forums #749574 (unresolved) reports locked
   exposure/WB/focus values *silently drifting during capture* on iPad 8 and
   iPhone 15. Phase 04's gain compensation assumes the lock holds, so the grey-card
   test in §6 is not optional — it is how we find out whether this affects our
   devices.

Enable `isLensStabilizationDuringBracketedCaptureSupported` when available — it
directly reduces the inter-frame shift Phase 05 §3 has to correct.

### 3.5 Timestamps

`CMSampleBufferGetPresentationTimeStamp` is on the `CMClockGetHostTimeClock`
base, i.e. `mach_absolute_time`. `CMDeviceMotion.timestamp` is
`systemUptime`-based. Convert both to a single monotonic microsecond base at the
plugin boundary and document the conversion in one place. Same hazard as Android
§2.5.

---

## 4. Preview

Preview is only used for aiming, so it should be cheap: request a modest preview
resolution (~1280 wide) regardless of capture resolution. A full-resolution
preview on a tablet wastes battery and thermal headroom that the stitch will need.

Deliver via the platform texture APIs (`SurfaceTexture` / `CVPixelBuffer` +
`FlutterTexture`). Do **not** stream preview bytes over the channel.

---

## 5. Thermal management

Both platforms report thermal state (`PowerManager.getCurrentThermalStatus()` /
`ProcessInfo.thermalState`). Surface it through `onThermalStateChanged`. An
87-frame bracketed capture followed by a 60 s stitch is a genuine thermal load,
especially on a tablet in a sunny site.

Policy: at `serious`, warn the user and suggest stitching later. At `critical`,
refuse to start a stitch and say why. Never silently produce worse output — the
architecture's core principle.

---

## 6. Tests

- integration: enumerate → open → meter+lock → 29 brackets → close, on real
  hardware, both platforms
- assert intrinsics `hfovRadians` matches the Spike B physical measurement within 2%
- assert AE lock holds: capture a static grey card 29 times, mean luminance
  variation **< 1%**
- assert AWB lock holds: same, per-channel
- assert burst timing < 600 ms
- assert `SENSOR_TIMESTAMP` ↔ sensor-clock offset is stable within ±2 ms over a
  60 s session
- unit: intrinsics fallback chain picks the right branch for each synthetic
  capability set

---

## 7. Pitfalls

1. **`captureBurst` fails silently if the session is reconfigured mid-burst.**
   Never touch the session between requests.
2. **Android `LEGACY` devices** cannot do manual exposure at all. Detect early and
   degrade the exposure strategy, do not fail the session.
3. **iOS `AVCaptureSession` interruptions** (phone call, another app, split view
   on iPad) must be handled — `AVCaptureSessionWasInterrupted`. On iPad, a second
   app taking the camera is common.
4. **Android `ImageReader` buffers must be closed** or capture stalls after a few
   frames. With 87 frames this fails fast and looks like a hardware bug.
5. **Do not assume the largest JPEG size is 4:3.** Filter by aspect explicitly.
6. **`setExposureModeCustom` completion handler** — the lock is not in effect
   until it fires. Awaiting it is required, and skipping it makes the first few
   frames of the session inconsistent.

---

## Exit criteria

- [ ] All seven tests in §6 pass on real iPad **and** real Android tablet
- [ ] AE/AWB lock verified with a grey-card measurement, not by eye
- [ ] Timestamp base conversion documented and its uncertainty measured
- [ ] Intrinsics agree with the physical measurement within 2%
- [ ] Bracket burst < 600 ms
- [ ] Thermal state surfaced and acted on
