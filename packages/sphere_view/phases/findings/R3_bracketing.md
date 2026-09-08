# R3 — Bracketed burst capture

**Researched:** 2026-08-06
**Sources:** Apple SDK header doc-comments (archived, since live developer.apple.com pages are JS-rendered SPAs not directly fetchable), Apple's AVCamManual-Swift official sample code, Apple Developer Forums threads #749574 (unresolved) and general bracket-capture threads, community blog CameraPixels (2025, focus-bracketing context), developer.android.com/media/camera/camera2/capture-sessions-requests, developer.android.com/reference/android/hardware/camera2/CameraCharacteristics, android-developers.googleblog.com CameraX 1.5 release post (2025-11-13), developer.android.com/media/camera/camerax/extensions-api, GitHub `google/zsldemo` and community stall-time reports (Nexus 5 JPEG vs. YUV_420_888), CameraX developer forum threads on `Camera2Interop`.

## Answer

**No source anywhere — official or community — publishes a measured wall-clock number for a 3-frame full-resolution JPEG bracket/burst on either platform.** The ~600ms budget this design depends on is currently unverified by any external evidence; this must be measured directly in the Phase 00 spike before the capture design is finalized, and is the single most important empirical gap this research surfaced. Beyond that: on iOS, `AVCapturePhotoBracketSettings` remains current (no deprecation) but neither AE nor manual bracket settings lock focus/white balance automatically — the app must lock both explicitly, exactly as Apple's own sample code does; `maxBracketedCapturePhotoCount` is explicitly documented as device/format-dependent with no published table, so 3 must not be assumed available without a runtime check. On Android, the original assumption is confirmed correct: CameraX still has no first-class bracketing API (confirmed via its Nov 2025 1.5 release notes) and gains nothing over raw Camera2 for this use case; neither platform's built-in multi-frame HDR (CameraX Extensions `ExtensionMode.HDR`) is a viable substitute, since both return only a single already-fused/tone-mapped image with no per-frame control — exactly the photometric-inconsistency risk this design is trying to avoid.

## Evidence

### iOS

**1. `AVCapturePhotoBracketSettings` status.** No deprecation found. iOS 17's Deferred Photo Processing (`AVCaptureDeferredPhotoProxy`) and iOS 18's Zero Shutter Lag/Responsive Capture are additive and unrelated — they don't supersede bracket capture. Community forum activity around iPhone 16 Pro bracket questions confirms it's still in active current use.

**2. AE-bracket vs. manual-bracket and AWB/AF.** `AVCaptureAutoExposureBracketedStillImageSettings` varies only `exposureTargetBias`; `AVCaptureManualExposureBracketedStillImageSettings` varies `exposureDuration`+`ISO`. **Neither locks focus or white balance** — confirmed directly in Apple's own AVCamManual-Swift sample: bracket construction only sets exposure values, while focus/WB locking are separate methods (`changeFocusMode()`, `changeWhiteBalanceMode()`) the app must call itself before capture. Also: a single bracket cannot mix AE and manual settings objects — per SDK header doc-comments, mixing types raises an exception.

**3. Bracket + `setExposureModeCustom` (locked).** No documented hard conflict — Apple's own AVCamManual-Swift sample explicitly checks `if videoDevice.exposureMode == .custom` and, if so, builds the bracket from `AVCaptureManualExposureBracketedStillImageSettings` using `AVCaptureDevice.currentExposureDuration`/`currentISO`, i.e. custom mode and manual-exposure brackets are designed to compose. **However**, an unresolved Developer Forums thread (#749574, no Apple engineer response) reports locked exposure/WB/focus values silently drifting during capture on some devices (iPad 8, iPhone 15), with a workaround the reporter says "only works on older devices, not iPad 9 or iPhone 15." **Open reliability risk, not resolved by documentation.**

**4. `maxBracketedCapturePhotoCount`.** Explicitly documented as **not a fixed number** — SDK header doc-comment: *"the maximum number of photos that may be taken in a single bracket depends on the size and format of the images being captured... may vary with `AVCaptureSession` `sessionPreset` and `AVCaptureDevice` `activeFormat`."* No Apple-published per-device table found. Only concrete historical data point: iPhone 7 Plus / iOS 10.3.2 → 4 (2017-era, not an iPad, not current hardware). **No current iPad-specific figure exists — do not assume 3 is always available; query the property at runtime and design a graceful fallback** (e.g. sequential single-shot capture with manual exposure changes) for devices/formats that grant fewer.

**5. `isLensStabilizationDuringBracketedCaptureSupported`.** A capability check; `AVCapturePhotoBracketSettings.lensStabilizationEnabled` (default `NO`) may only be set `YES` when supported, and its value "may change as `sessionPreset` or `activeFormat` changes." A 2025 community blog (CameraPixels, in a focus-bracketing context, not exposure-bracketing) notes stabilization "reduce[s] motion blur between frames, though stabilization processing increases capture time" — **generalized from a different bracketing mode, unconfirmed for exposure brackets; no measured shift-reduction numbers found anywhere.**

**6. Measured wall-clock time.** **No hard number exists.** Exhaustive search (WWDC sessions, forums, blog posts, benchmark sites) found zero published "N ms for 3 frames" figures for `AVCapturePhotoOutput` bracket capture on any device, iPad or otherwise. Third-party bracketing apps (ProCamera, Brackt, CameraPixels) support 3+ frame brackets but publish no latency data. **Must be measured empirically in Phase 00 — the ~600ms budget is currently unverified.**

### Android

**7. Manual burst pattern.** Official pattern (developer.android.com/media/camera/camera2/capture-sessions-requests, matching Google's camera2basic/HdrViewfinder samples): build a `CaptureRequest.Builder`, set `CONTROL_AE_MODE_OFF`, `CONTROL_AWB_MODE_OFF`, `CONTROL_AF_MODE_OFF`, then `SENSOR_EXPOSURE_TIME` (ns) and `SENSOR_SENSITIVITY` per-request, submit a `List<CaptureRequest>` via `captureBurst()`. Docs confirm `SENSOR_EXPOSURE_TIME`/`SENSOR_SENSITIVITY` only take effect when `CONTROL_AE_MODE`/`CONTROL_MODE` is OFF — otherwise AE silently overrides them. No AOSP bug tracker or named-device report of the HAL silently reverting to auto mid-burst was found — **flagged as unconfirmed/not found, not ruled out.**

**8. Hardware level requirement.** `INFO_SUPPORTED_HARDWARE_LEVEL_FULL` is the level that **guarantees** the `MANUAL_SENSOR` capability; `LIMITED` devices may or may not report it — **gate on `REQUEST_AVAILABLE_CAPABILITIES` containing `MANUAL_SENSOR` at runtime, not on the hardware-level name**; `LEGACY` never supports it. **No authoritative or crowd-sourced data was found for Galaxy Tab A series, Zebra, Honeywell, or Panasonic Toughbook tablets specifically** — general Camera2-capability-checker tools and Zebra's Enterprise Browser camera docs exist but don't cover `MANUAL_SENSOR` per-model for tablets. **Real gap — must be measured directly on fleet hardware; no viable desk-research source exists.**

**9. Measured burst latency.** **No hard published number for a 3-frame full-resolution JPEG burst.** Adjacent (non-matching, explicitly flagged) data points: Nexus 5 JPEG output stall ~243ms vs. ~0ms for `YUV_420_888` — i.e. JPEG encoding is the dominant per-frame cost, suggesting capturing YUV/RAW and deferring JPEG encode off the hot path is likely faster than requesting JPEG directly from the burst; Pixel ZSL capture-to-full-quality ~50-100ms/frame under vendor-optimized pipelines, not representative of raw `captureBurst`. **Treat the 600ms budget as unverified — Phase 00 must measure it, and should specifically test YUV-capture-plus-deferred-encode against direct JPEG burst.**

**10. CameraX bracketing.** **Still no first-class bracketing API** — confirmed via the CameraX 1.5 release blog (Nov 13, 2025): headline additions are DNG/RAW capture, Ultra HDR for Camera Extensions, and torch-strength control; no bracketing mention. Manual exposure is reachable only via the `Camera2Interop`/`Camera2CameraControl.setCaptureRequestOptions()` escape hatch — same underlying capture-request mechanism as raw Camera2, with the same `HARDWARE_LEVEL_FULL`/`MANUAL_SENSOR` gating (a forum source explicitly notes `SENSOR_EXPOSURE_TIME`/`SENSOR_SENSITIVITY` are only guaranteed reported on FULL). **Original assumption confirmed: Camera2 directly is the right choice; CameraX adds an interop-shim layer with no benefit here.**

**11. Built-in HDR/multi-frame capture.** CameraX Extensions `ExtensionMode.HDR` exists via vendor OEM libraries, but `ImageCapture.takePicture()` returns exactly **one** output image per call regardless of extension — multi-frame fusion happens inside the OEM vendor library, with only the final fused result exposed to the app (**inferred from the API contract, not verbatim-documented** — flagged accordingly). Consequence: even where available, HDR Extensions would **not** substitute for manual bracketing — a single already-tone-mapped image with no per-frame exposure/WB control is exactly the photometric-inconsistency risk this design needs to avoid across panorama capture positions. Manual `captureBurst`/`Camera2Interop` bracketing remains necessary.

## Consequences for the plan

- **Phase 06 (platform camera)** should keep Camera2 (not CameraX) as the Android capture mechanism — now confirmed against CameraX's current (1.5, Nov 2025) feature set, not just an assumption.
- **Phase 06's iOS capture sequence** must explicitly call focus-lock and white-balance-lock methods before constructing any bracket — this is not automatic on either bracket settings type, confirmed against Apple's own sample code.
- **Phase 06 should query `maxBracketedCapturePhotoCount` at runtime rather than assuming 3**, and have a defined fallback (sequential manual-exposure single shots) for devices/formats that grant fewer.
- **Phase 05 (HDR fusion)**'s `ExposureStrategy` design should not lean on platform-native HDR shortcuts (CameraX Extensions HDR) on either platform — both are confirmed to return a single non-controllable fused output that would break photometric consistency across the panorama. Manual bracketing stays the only viable primary method.
- **Phase 00's spike must prioritize measuring actual burst/bracket wall-clock time on both platforms** — this is not a refinement detail, it's the load-bearing number the entire HDR capture strategy depends on, and no published source anywhere gives one. If the measured number blows the ~600ms budget, this triggers the fallback to `ExposureStrategy.locked()` flagged in the original research question.
- On Android, **evaluate YUV capture + deferred/off-thread JPEG encode** as a candidate design in the spike, given evidence that JPEG encoding — not sensor readout — is likely the dominant per-frame latency cost.

## Still unknown

1. **Real measured wall-clock time for a 3-frame full-resolution JPEG bracket/burst on both iOS (target iPad models) and Android (target tablets).** No source anywhere gives a number for either platform — the single highest-priority Phase 00 measurement for this question.
2. **Actual `maxBracketedCapturePhotoCount` on current iPad Pro/Air/mini/base models**, at the specific resolution/format this app will use.
3. **Whether the iOS locked-exposure/WB/focus drift-during-capture issue (forum #749574) reproduces on the actual target iPad models.**
4. **Actual `MANUAL_SENSOR` capability presence on the specific fleet devices** (Galaxy Tab A series, Zebra/Honeywell/Panasonic rugged tablets) — no desk-research source exists for this; must be checked directly, e.g. via a simple capability-dump utility across available fleet hardware.
5. **Whether Camera2's `captureBurst` on target devices exhibits any HAL-reverts-to-auto-mode pitfall** — not found in either direction in this research pass; needs direct testing.
6. **Whether YUV capture + deferred JPEG encode meaningfully beats a direct JPEG burst in practice on the actual target hardware.**

---

# Phase 00 Spike C — harness built, measurements pending hardware

**Written:** 2026-08-06
**Spike code:** `spikes/spike_bc_device/` (throwaway Flutter app, compiles
clean for both platforms)
**Status:** no devices were attached to the session that built this. The
headline number still needs one run of the app per device — see
`spikes/README.md` for exactly what to run and what to send back.

## What gets measured, and why it is measured that way

R3's headline result was that **no source anywhere publishes a wall-clock number
for a 3-frame full-resolution bracket**, and that the ~600 ms budget the HDR
strategy rests on is supported by nothing. This harness produces that number.

The report's headline field is `HEADLINE_burstWallClockMs`, and the on-screen
log prints one line per configuration:

```
→ spikeC_jpeg: 512, 498, 505 ms (median 505 ms) — WITHIN the ~600 ms budget
```

Four decisions about *how* it is timed, because a sloppy measurement here would
be worse than none:

1. **Timing stops at pixel delivery, not at capture completion.** Android takes
   the mark in `ImageReader.onImageAvailable` for the last frame, iOS in
   `didFinishProcessingPhoto`. Metadata routinely completes well before pixels
   are in hand, and pixels are what Phase 05 needs. Timing `onCaptureCompleted`
   would have produced a flattering, useless number.
2. **Shutter-to-shutter cadence is recorded separately** — from Camera2
   `SENSOR_TIMESTAMP`s, and from `willCapturePhotoFor` callbacks on iOS. This
   separates *what the sensor can sustain* from *what processing then costs*,
   which is exactly the distinction R3 §9 says the design decision turns on.
3. **Three repeats per configuration.** The first burst on a cold pipeline is
   routinely slower than steady state; the summary reports the median and all
   three runs, so a single cold outlier cannot masquerade as the budget.
4. **No preview surface.** Android uses a small YUV `ImageReader` purely to
   drive AE/AWB/AF convergence, then `stopRepeating()` and a 150 ms drain before
   the burst, so nothing interleaves with the measurement.

## The A/B R3 asked for

R3 found evidence (Nexus 5: ~243 ms JPEG stall vs ~0 ms for `YUV_420_888`) that
JPEG *encoding*, not sensor readout, is the dominant per-frame cost — and that
if so, YUV capture with deferred encode could bring a failing burst inside
budget without touching the HDR design at all.

The Android path runs both `mode: "jpeg"` and `mode: "yuv"` and reports:

| Field | Meaning |
|---|---|
| `HEADLINE_burstWallClockMs` | trigger → last frame in hand, per mode |
| `deferredEncodeTotalMs` | what the YUV path *moved off* the hot path (not removed) |
| `yuvPlusEncodeEquivalentMs` | YUV burst + encode, the honest like-for-like against JPEG |
| `jpegStallDurationNs` / `yuvStallDurationNs` | the HAL's own declared stall per format |

That last row is a free corroboration: a non-zero
`getOutputStallDuration(JPEG, size)` is the HAL stating outright that encoding
blocks its pipeline, and it can be compared against the measured difference.

`yuvPlusEncodeEquivalentMs` exists to keep the comparison honest — deferring the
encode does not make it free, it moves it to where the manager is already
walking to the next target.

## The drift test (Forums #749574)

R3 flagged an unresolved report of locked exposure/WB/focus **silently drifting
during capture** on iPad 8 and iPhone 15, which would undermine the AE lock that
Phase 04's gain compensation assumes. It is tested three independent ways per
frame, so a drift cannot hide:

- **What was asked vs. what happened.** Android compares requested
  `SENSOR_EXPOSURE_TIME`/`SENSOR_SENSITIVITY` against the values in the
  `CaptureResult`; iOS compares the bracket settings against the delivered
  photo's **EXIF** exposure time and ISO. `achievedEvVsBase` is computed from
  the *actual* values, so the "EV separation within 0.3 EV of requested"
  acceptance criterion is checked against reality rather than intent.
- **Pixels.** Mean R,G,B over the centre 20% of every frame
  (`greyMeansRGB`), plus `channelRatios_RoverG_BoverG` on iOS. Shot against a
  grey card, a moving channel ratio is white balance failing to stay locked
  regardless of what the metadata claims.
- **Per-frame control state.** Android records `aeState`, `awbState`, `afState`,
  `lensFocusDistance` and `colorCorrectionGains` for each frame in the burst.

R3's finding that **neither iOS bracket type locks focus or white balance** is
built into the sequence rather than assumed: `BracketSpikeIOS` explicitly sets
`focusMode = .locked` and `whiteBalanceMode = .locked`, and disables geometric
distortion correction, *before* constructing any bracket — then the tests above
verify the locks actually held.

## Runtime capability queries, not assumptions

- **`maxBracketedCapturePhotoCount` is queried after the format is set**, per
  R3's finding that it varies with `sessionPreset`/`activeFormat` and has no
  published per-device table. If it comes back below the requested count the
  bracket is **trimmed to 2 shots** rather than failing — which is the
  intermediate fallback `PHASE_00_spikes.md` names before abandoning HDR. If it
  is below 2, the report says so explicitly and names the sequential fallback.
- **Android gates on `MANUAL_SENSOR` in `REQUEST_AVAILABLE_CAPABILITIES`, not on
  the hardware-level name**, exactly as R3 §8 requires. Both are recorded, so
  the findings can show whether the two ever disagree on real fleet hardware.
  Where `MANUAL_SENSOR` is absent the harness falls back to
  `CONTROL_AE_EXPOSURE_COMPENSATION` and says so in `bracketPlan.note` — that is
  not a true bracket, and it must not be mistaken for one in the results.
- **Clamping is reported, never silent.** If the requested EV cannot be reached
  within the sensor's exposure range the residual moves to ISO; if ISO clamps
  too, `bracketPlan.note` states that the requested separation was **not
  achieved**. A silently clamped bracket would otherwise look like a passing
  measurement while delivering less dynamic range than the budget assumes.

## Additional configurations measured

- **2-shot bracket (0 / +2 EV)** — measured on every device regardless of
  whether 3 passes, so the fallback decision is data-backed rather than a guess.
- **iOS lens stabilization on vs. off** — R3 §5 carried a claim that
  stabilization "increases capture time", generalised from a focus-bracketing
  blog post and never measured for exposure brackets. Measured here rather than
  inherited.
- **Gyro integration across the burst** on both platforms (total angular travel,
  peak and mean rate). Feeds Phase 05 §3: if the hand rotates more than a
  pixel's worth between bracket frames, ECC alignment before Mertens is
  mandatory rather than optional.

## Acceptance status

- [ ] 3-frame burst works on both platforms, on real hardware — **pending**
- [ ] **Burst wall clock measured and recorded, per device** — **pending**, this is the ask
- [ ] Achieved EV separation within 0.3 EV of requested — **pending**, computed from actuals
- [ ] Grey-card test confirms no locked-value drift — **pending**, instrumented three ways
- [ ] `maxBracketedCapturePhotoCount` recorded per device — **pending**, queried at runtime
- [ ] Devices needing the single-exposure path listed by name — **pending**

## What the answer changes

Stated in advance so the decision is not relitigated once a number exists:

| Median 3-shot wall clock | Consequence |
|---|---|
| ≤ 600 ms | Phase 05/06 proceed as designed, 3-shot Mertens |
| 600 ms – ~1.2 s | Try YUV + deferred encode first (Android); if that closes it, keep 3 shots. Otherwise drop to the 2-shot bracket |
| > ~1.2 s, both modes | Fall back to `ExposureStrategy.locked()`. Per R3 and Arch §6.4 this needs **no structural change** — `shots: List<ExposureShot>` becomes a single-element list. The cost is dynamic range in interiors, not a rewrite |

Per-device, not global: a device that fails goes on the single-exposure list by
name, it does not decide the design for the fleet.
