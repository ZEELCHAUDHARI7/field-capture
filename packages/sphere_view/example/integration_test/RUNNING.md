# Running the device tests

Four suites, all of which measure things that do not exist off a device:

| Suite | File | What it settles |
|---|---|---|
| **Phase 06** | `camera_device_test.dart` | burst wall clock, intrinsics, AE/AWB lock, clock drift — §§1–6 below |
| **Phase 07** | `pose_device_test.dart` | pose↔shutter timing, the conversion's sign, orientation drift — §7 below |
| **Phase 10** | `stitch_device_test.dart` | dropped frames during a stitch, the tier probe, cancel latency, the OOM downgrade — §8 below |
| **Phase 11** | `viewer_device_test.dart` | the GPU's texture ceiling, the black-sphere case, sustained frame rate while dragging — §9 below |
| **Phase 12** | `device_matrix_test.dart` | one row of the device matrix: capability, tier, S1–S6 on a fixed reference scene, S8, S9, thermal state, battery drain, and the 20-run low-tier soak — §10 below |

The Phase 06 setup section (§0) applies to 06 and 07. **Phases 10 and 11 need
none of it** — no camera, no permission, no grey card, no measured wall. Each
makes its own input and looks at it, so they are the two suites you can run on
any tablet you can reach in a few minutes.

---

# Running the Phase 06 device tests

Everything in `camera_device_test.dart` measures something that **does not
exist off a device**. R3's headline finding was that no source anywhere —
official or community — publishes a measured wall clock for a 3-frame
full-resolution bracket, and R2 left four questions open that only an iPad and
an Android tablet can settle. So this is not a regression suite you run to see
green; it is the instrument that produces the numbers.

Run it on **one iPad and one Android tablet**, and send back the two
`sphere_view_phase06_report.json` files.

---

## 0. Once, before the first run

```bash
cd /Users/purvangsuvagiya/Documents/sphere_view
flutter pub get
cd example && flutter pub get

# The native stitch library. 10-20 minutes the first time, then cached, and
# nothing that touches a stitch will run without it. See
# docs/BUILDING_NATIVE.md.
cd .. && tools/build_native_mobile.sh
```

The Android build needs a JDK. If `./gradlew` says "Unable to locate a Java
Runtime", Android Studio ships one:

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
```

### Camera permission

An integration test cannot tap a permission dialog, so grant it up front.

**Android** — install once, then grant:

```bash
flutter install -d <device-id>
adb -s <device-id> shell pm grant com.example.example android.permission.CAMERA
```

Without it the run fails immediately with `camera_permission_denied`, which is
deliberate: Camera2 otherwise throws a bare `SecurityException` from inside the
framework that nobody can branch on.

**iOS** — the plugin requests access and **waits up to 60 s for the dialog**, so
either tap Allow when it appears, or grant it in advance by launching the app
once by hand (`flutter run -d <device-id>`, open the Camera probe screen, tap
Allow, quit).

Do not skip this on iOS. An unauthorised `AVCaptureSession` does not fail — it
runs and delivers black frames. The metering sweep would meter black and the
grey-card test would measure a uniform zero and *pass*. That is why the plugin
blocks on authorisation rather than trusting the session to complain.

---

## 1. The quick run — burst timing and clock stability

This needs no physical setup at all. Point the tablet at anything with some
texture and depth; a room is fine. It produces the two numbers nothing anywhere
has measured.

```bash
cd example
flutter test integration_test/camera_device_test.dart -d <device-id>
```

`flutter devices` lists the ids. Grant the camera permission when it asks —
the run will fail immediately without it.

Takes about four minutes: 29 brackets, then a 60-second clock observation.

**What you get:** `HEADLINE_burst_wall_clock_ms` (median, min, max, every run,
and the shutter-to-shutter cadence separately), and the clock drift over 60 s.

---

## 2. The full run — all seven tests

Two pieces of physical setup, each enabling one test. Do them if you can; the
run works without either, and skips with a printed explanation rather than
failing.

### 2a. The intrinsics check (test 2)

You need the horizontal field of view measured with a tape measure, per
`spikes/README.md`:

1. Clamp or prop the tablet so it cannot move, facing a flat wall square-on.
2. Measure the perpendicular distance `d` from the **lens** to the wall.
3. Open the camera preview and mark the wall at the exact left and right edges
   of the frame. Measure the separation `s` between the marks.
4. `hfov = 2 · atan(s / (2·d))`, in degrees.

Worked: `d = 1.00 m`, `s = 1.22 m` → `hfov = 2·atan(0.61) = 62.7°`.

Hold the tablet in the orientation the capture stream uses — landscape, i.e.
the sensor's own — not portrait. The intrinsics are expressed in the capture
stream's coordinates; the portrait lock rotates the device, not the image.

### 2b. The grey-card lock check (tests 3 and 4)

This is the one that answers whether the unresolved Apple Forums #749574 lock
drift affects our devices. Phase 04's gain compensation assumes the lock holds,
so the answer matters more than it sounds.

1. Clamp the tablet so it cannot move for the duration — this is measuring the
   camera, and any movement measures the room instead.
2. Fill the centre of the frame with an evenly-lit neutral grey card. A sheet of
   white printer paper works if a proper card is not to hand; what matters is
   that it is flat, uniform, and covers the middle fifth of the frame.
3. Light it evenly and **do not change the lighting during the run**. Avoid
   sunlight through a window, which drifts on its own, and avoid fluorescent
   tubes if the shutter is short, which can beat against the mains frequency.

### Then

```bash
cd example
flutter test integration_test/camera_device_test.dart \
  -d <device-id> \
  --dart-define=SPIKE_B_HFOV_DEGREES=62.7 \
  --dart-define=GREY_CARD=true
```

Takes about eight minutes: 29 brackets, then 29 more grey-card single shots,
then the clock window.

---

## 3. Getting the report back

The JSON is **printed to the console** between `===== PHASE 06 REPORT =====`
markers — copying it out of the terminal is the shortest path. It is also
written to the app's documents directory:

- **Android:** `adb exec-out run-as com.example.example cat files/phase06/sphere_view_phase06_report.json > android_report.json`
- **iOS:** Xcode → Window → Devices and Simulators → select the iPad → the
  example app → the ⚙ under the app list → **Download Container**, then look
  inside `AppData/Documents/phase06/`.

Rename them `android_<model>.json` and `ipad_<model>.json` so the findings can
be filed per device — R2 and R3 both ask for results *by device name*, since a
device that fails goes on a list by name rather than deciding the design for the
fleet.

---

## 4. What the numbers mean

| Field | Criterion | If it fails |
|---|---|---|
| `HEADLINE_burst_wall_clock_ms.median` | ≤ 600 ms | Re-run with `useDeferredJpegEncode` (see below) **before** dropping to a 2-shot bracket. R3 §9's evidence is that JPEG *encoding*, not sensor readout, dominates |
| `intrinsics_check.relative_error` | ≤ 0.02 | A 4% focal error means the panorama does not close (arch §2 defect 2). Check `intrinsics_branch` first — a device on `exif` is expected to be ~10% out |
| `lock_stability.luminance_variation` | ≤ 0.01 | The AE lock is not holding. Check `monotone_trend`: a trend is drift (#749574), scatter is noise |
| `lock_stability.channel_ratio_variation` | ≤ 0.01 | White balance is moving even if luminance is not — R:G and B:G are where that shows |
| `clock.drift_us` | ≤ 2000 | Every pose in every bundle is wrong by this much. On Android `REALTIME` this is 0 by construction (`is_exact: true`), which is the right answer |
| `session.achieved_requested_separation` | `true` | The bracket did not actually separate. Check `clamped_iso` — if true, the requested EV range was not achieved and the fused frame has less dynamic range than the plan assumes |

### If the burst misses 600 ms on Android

R3 §9 predicted this and named the fix. Change one line in the test's
`CaptureFormatSpec`:

```dart
CaptureFormatSpec(
  captureSize: probe.selectCaptureSize(selection.camera),
  computeFrameStatistics: true,
  useDeferredJpegEncode: true,   // ← YUV_420_888 burst, encode off the hot path
)
```

Then compare `HEADLINE_burst_wall_clock_ms.median` against
`deferred_encode_ms`. The honest like-for-like is the sum: deferring the encode
does not make it free, it moves it to where the manager is already walking to
the next target. If burst + encode still beats direct JPEG, keep it.

---

## 5. What is *not* in this file

**Test 7** — "the intrinsics fallback chain picks the right branch for each
synthetic capability set" — is a unit test, not a device test:

```bash
cd /Users/purvangsuvagiya/Documents/sphere_view
flutter test test/intrinsics_chain_test.dart test/camera_selection_test.dart
```

It belongs on a laptop precisely because it has to cover branches this fleet
will never take. A chain tested only on the two devices in the room is a chain
tested on two of its six rungs.

---

# 7. The Phase 07 pose tests

`pose_device_test.dart`. One of its four tests matters far more than the other
three, and the phase document says so: **the timestamp-alignment test.**

Everything else in Phase 07 is provable on a laptop, and is proved there —
`test/pose_conversion_test.dart`, `test/pose_buffer_test.dart` and
`test/pose_source_test.dart` cover the frame conversion, the SLERP, the buffer
boundary, the warm-up, the quaternion sign ambiguity and the gyro-less refusal
between them. What they cannot cover is whether the *platform documentation* is
true and whether the camera's shutter clock and the sensor's clock really are
one clock. That is what this file is for.

## 7a. The quick run — capabilities and drift

No physical setup beyond a table.

```bash
cd example
flutter test integration_test/pose_device_test.dart -d <device-id>
```

Takes about four minutes, three of which are the drift measurement. **Put the
tablet down when it tells you to and do not touch it** — any movement is
measured as drift, and the test says so by failing on peak angular speed rather
than by quietly reporting the room.

Shorten the drift window while iterating with
`--dart-define=DRIFT_SECONDS=30`. Do not report a number measured that way: the
criterion is stated over three minutes because gyro bias is a *rate*, and thirty
seconds of it is a sixth of the answer.

## 7b. The full run — the test that matters

Two minutes of setup, and it is the difference between shipping a mirrored
panorama and knowing you are not.

### The edge

1. Find a **high-contrast vertical edge** 2–3 m away. A dark doorframe against a
   light wall works; so does a strip of black tape or gaffer on white plaster.
   It needs to run floor-to-ceiling through the middle of the frame, and it
   needs to be the *strongest* vertical edge in view — the detector takes the
   largest column-gradient response, so a brighter window frame beside it would
   win instead.
2. **Hold the tablet in landscape** — the capture stream's own orientation, the
   same instruction §2a gives for the field-of-view measurement. The intrinsics
   are expressed in the stream's coordinates, and a physically vertical edge
   only lands on an image *column* when the sensor is the right way up.
3. Even, unchanging light. The exposure is locked at the start of the sweep.

### The sweep

```bash
cd example
flutter test integration_test/pose_device_test.dart \
  -d <device-id> \
  --dart-define=EDGE=true
```

When it prints `PAN NOW`, sweep the tablet left and right past the edge for
about a minute, keeping the edge crossing the frame. **Vary the speed** —
several slow passes (a lazy sweep, ~20°/s), several fast ones (a brisk turn,
~120°/s), and everything between. Pan both directions.

The speed range is not a nicety. The whole method rests on it: a timing error
and a geometry error look identical at any single pan rate and completely
different across a range of them, because timing error scales with angular
velocity and geometry error does not. A sweep that was all one speed produces a
number with no lever arm, and the test rejects it rather than reporting it.

Rotate about the tablet's own vertical axis, not about your body — the same
technique note the capture UI gives, and for the same parallax reason.

## 7c. What the numbers mean

| Field | Criterion | If it fails |
|---|---|---|
| `timestamp_alignment.HEADLINE_residual_offset_ms` | ≤ 3 ms | The pose lags or leads the shutter. **Check `exposure_midpoint_offset_ms` first**: both platforms stamp the *start* of exposure, so at 1/250 s the true instant is 2 ms later, and if the midpoint number is inside the budget the fix is to stamp the middle of the exposure |
| `timestamp_alignment.constant_offset_degrees` | small | A constant that does not scale with rate is **not** a timing error — it is the frame conversion, the principal point, or the focal length. §5 separates the two on purpose |
| `timestamp_alignment.fit_r_squared` | high | A low value with a small slope means the sweep was too slow or too short to measure anything; a low value with a large slope means something else is moving |
| `mirroring.agreement_fraction` | > 0.9 | Near **0** means the conversion is **mirrored** — Phase 07 §2 predicts exactly this, and the fix is the determinant of `PoseFrameConversion.referenceToWorldRowMajor`. Near **0.5** means poses and frames are not paired at all, which is the timestamp test's problem |
| `drift.max_yaw_excursion_degrees` | < 1.5° | Yaw has no absolute reference and is only bias-corrected, so it creeps. Over budget means the OS filter is not doing what it claims |
| `drift.max_pitch_excursion_degrees` / `..._roll_...` | < 0.3° | These are gravity-locked and should be **flat**, not merely small. Wander here means the accelerometer correction is not running — and Math §7 levels the whole panorama against exactly this |
| `sample_rate.measured_hz` | ~100 | Lower is not fatal — SLERP still interpolates — but it widens the gap being interpolated across, so it belongs in the record |
| `support.uses_magnetometer` | `false` | A `true` means the build reached for `TYPE_ROTATION_VECTOR` or `.xTrueNorthZVertical`, which is the failure Math §1.1 rejects the compass to avoid |
| `stream.clock.base` | `androidElapsedRealtime` / `iosSystemUptime` | `androidMonotonicNanoTime` is §6 pitfall 1's device. It is handled — the offset is measured — but it is worth knowing which devices do it |

`timestamp_alignment.points` holds the raw (rate, residual) pairs. Plotting them
is the whole diagnostic §5 describes: a sloped line is timing, a flat offset is
geometry, and a scatter with no structure means the pose and the frame are not
about the same instant at all.

## 7d. On a device with no gyroscope

Test 1 detects it, asserts the refusal is readable, and skips the rest. That is
the code working, not failing — §6 pitfall 3 and Phase 12 §1 both say such a
device is refused at the feature entry point rather than allowed to produce a
panorama built on tilt alone. `report.refused` is `true` and
`support.unsupported_reason` is the sentence the user would see. Send that
report back too; a named device that cannot be supported is a finding.

## 7e. Getting the report back

Same as §3, with `phase07` in place of `phase06`:
`sphere_view_phase07_report.json`, printed between
`===== PHASE 07 REPORT =====` markers and written to the app's documents
directory.


---

# 8. Running the Phase 10 device tests

```bash
cd example
flutter test integration_test/stitch_device_test.dart -d <device-id>
```

Nothing to set up. No camera permission is needed — the suite never opens the
camera. It renders a small synthetic capture set with the Phase 02 harness
(31 positions at 240x320, which takes a minute or two of pure-Dart pixel work on
a tablet) and then stitches it through the shipping path: the progress struct
allocated on the main isolate, the address passed to a worker, `sv_stitch`
blocking there, and the UI free to poll and to cancel.

Run it on **one 3 GB Android tablet and one iPad**. The 3 GB tablet is named
specifically in Phase 10's exit criteria, because it is the device the whole
tier table exists for.

## 8a. What the numbers mean

| Field | Criterion | If it fails |
|---|---|---|
| `frames_over_32ms` | **0** | The stitch blocked the UI thread. This is the phase's headline criterion, and a non-zero value means either the FFI call is not on a worker isolate or the 10 Hz poll timer is doing too much per tick |
| `worst_frame_ms` | well under 32 | Reported even when the count is zero, because a run that peaks at 30 ms has no margin and the next device will fail |
| `frames_built` | large | A small number means the animation stopped and the measurement is vacuous. The spinning square exists to prevent exactly that |
| `total_physical_memory_mb` | matches the spec sheet | `ActivityManager.MemoryInfo.totalMem` reports slightly less than the marketed RAM — a "3 GB" tablet reads ~2.8 GB — which is correct and is why the `low` threshold is 3072 rather than 3000 |
| `tier` / `tier_from_total_memory` | equal, on Android | A difference means the iOS pre-flight downgraded, which should not happen on Android at all since it reports `-1` |
| `available_process_memory_mb` | > 0 on iOS, `-1` on Android | A `-1` on iOS means `os_proc_available_memory` is not being reached, and the only defence against a jetsam kill is not running |
| `cancel_latency_ms.*` | each < 500 | Which stage is over tells you where to look: `blending` points at the per-tile poll, `warping` at the per-frame one, `findingFeatures` at the per-frame poll in `registration.cpp` |
| `oom_tiers_attempted` | exactly two, one step apart | Three means the retry loop is not bounded; one means the failure was not recognised as memory and the retry never ran |
| `oom_warning` | mentions running out of memory | Architecture §8 — a downgrade the caller cannot see is a silent degradation |
| `stitch_ms` | — | Not a criterion here, because the frames are 240x320 rather than 12 MP. S8's 60 s budget is measured on a real capture, not on this |
| `queue_interruptions` | ≥ 1 | The queue recovered a bundle that was in flight when the app died. Zero means the recovery path did not run and the test proved nothing |

## 8b. Getting the report back

`sphere_view_phase10_report.json`, in the app's documents directory and printed
to the console — same as §3.

## 8c. What this suite does *not* settle

S8 (stitch under 60 s) and S9 (peak RSS under 700 MB) are budgets against a
**real** capture at capture resolution, and the frames here are deliberately
tiny so the rendering is quick. Those two need a bundle captured with
`camera_device_test.dart` or with the example app, stitched at the device's own
tier. They belong to Phase 12.

---

# 9. Running the Phase 11 device tests

```bash
cd example
flutter test integration_test/viewer_device_test.dart -d <device-id>
```

Nothing to set up: no camera, no permission, nobody holding anything. The suite
writes its own panoramas — up to 8192×4096 — and looks at them.

Run it on **the lowest-end tablet in the target fleet**, and on an iPad. The
low-end one is the point: Phase 11 §3.1's failure mode is a GPU that caps
`GL_MAX_TEXTURE_SIZE` at 4096, and the whole reason the criterion exists is that
such a device renders a **black sphere** rather than raising an error.

## 9a. What the numbers mean

| Field | Criterion | If it fails |
|---|---|---|
| `max_texture_size` | ≥ 4096 | This is the number §3.1 turns on. A device reporting 4096 is not a failure — it is the device the phase is about, and the next test is what proves it still works |
| `max_texture_size_probed` | `true` | `false` means the platform did not answer and the conservative 4096 floor was assumed, so every panorama on this device is displayed at 4096 whether it needed to be or not. Worth knowing which devices those are |
| `non_black_fraction_8192` | > 0.5 | **The black-sphere criterion.** A value near 0 means the oversized texture was uploaded anyway and the shader is sampling nothing. Nothing else in the system will tell you: the upload does not throw and does not log |
| `downscale_warning` | present iff the GPU capped it | Architecture §8 — a manager judging a defect deserves to know they are looking at a reduced rendering rather than at the file |
| `fps_<tier>.raster_p95_ms` | < `budget_ms` | **The frame-rate criterion.** Raster, not build: the equirect shader is fill-rate bound, so a build-time measurement would report a comfortable margin on a device that is visibly stuttering |
| `fps_<tier>.budget_ms` | — | Derived from the display's real refresh rate, not assumed to be 16.7. A 120 Hz iPad budgets 8.3 ms, and judging it against 60 Hz would pass a viewer dropping every other frame |
| `fps_<tier>.fraction_over_budget` | small | Reported alongside the p95 because one long frame and a sustained stutter are different problems with the same average |
| `preview_visible_ms` | < 600 | §3.1 budgets ~50 ms for the preview against ~800 ms for the full image. The whole reason the preview exists is that 800 ms of blank screen after a tap is long enough that people tap again |

## 9b. Getting the report back

`sphere_view_phase11_report.json`, in the app's documents directory and printed
to the console — same as §3.

## 9c. What this suite does *not* settle

**S10's real criterion is manual and stays manual.** `exiftool` in CI
(`tools/ci/validate_metadata.sh`, wired into the quality gate) proves the file is
*well-formed*; only Google Photos and Facebook prove it is *accepted*. Do that
once, and again after any change to the XMP packet:

1. Run a real capture, or `dart run tools/ci/write_sample_panorama.dart`.
2. Upload the JPEG to Google Photos. It must open with the pan/zoom sphere
   control, not as a flat wide image.
3. Post it to Facebook. It must be detected as a 360 photo on upload.

If either shows a flat image, the packet is being written but not found — check
that the XMP `APP1` is still the *first* segment after `SOI`, because several
readers stop scanning early.


---

# 10. Running the Phase 12 device matrix

**Run this on the low-end rugged Android tablet first.** The phase doc is blunt
about it and it is the only instruction here that changes the outcome of the
project rather than the outcome of a test: iPads will be fine. The 3 GB tablet
with a `LEGACY` camera and possibly no gyroscope is what determines whether the
feature ships, and finding that out on device six is a week spent on the wrong
question.

```sh
cd example
flutter test integration_test/device_matrix_test.dart -d <device-id>
```

Tests 1–5 are **unattended**: no grey card, no measured wall, nobody holding
anything. The suite renders its own reference scene with the same harness the
quality gate uses — seeded by profile name, so every device renders the *same*
scene, which is what makes the rows comparable — then stitches it, measures, and
runs twenty consecutive `low`-tier stitches looking for a memory creep. Budget
about twenty-five minutes on a slow tablet and leave it on a desk.

Test 6 is **attended**, takes two minutes, and is the only source of S7. Stand
somewhere with a bit of structure in view, start it, and follow the prompts:
pivot on the spot through every position until the counter fills. If nobody is
there it skips rather than fails — a suite that cannot run unattended stops being
run, and the other five tests are worth having on their own.

Then pull the row off the device and merge it:

```sh
# Android
adb exec-out run-as com.asite.sphere_view_example \
  cat files/sphere_view_device_matrix.json > tab-a9.json
# iOS: the Files app, or the container from Xcode's Devices and Simulators window

dart run tools/device_matrix.dart --add tab-a9.json --key rugged_android
```

`tools/device_matrix.dart` writes `docs/DEVICE_MATRIX.md` and **exits non-zero
while any fleet row is unmeasured**, so "the matrix passes" cannot come to mean
"the two tablets on the desk pass".

### What each row has to clear

* **S7 ≤ 90 s** — a full station. Only measured when the operator finishes every
  position; a partial session is reported as one rather than counted.
* **S8 ≤ 60 s** — a stitch. **The figure here is a lower bound**: the reference
  scene is rendered on-device from 240×320 frames because the renderer is pure
  Dart, so the decode and fusion stages do less work than a 12 MP capture gives
  them. The capture-resolution figure comes from `sphere_stitch_test`.
* **S9 < 700 MB** — asserted, not just recorded, because a device over it is a
  device that gets killed mid-stitch on a bad day.
* **The soak** — 20 runs, no tier downgrade, and the last five runs averaging
  under 1.4× the first five. A leak is invisible in one run and obvious by the
  twentieth, on the device with the least headroom to absorb it.

### If the tablet has no gyroscope

The suite says so and stops, and that is a complete and valid matrix row: the
feature must hide itself on that device (Phase 12 §1). It is not a test failure
and it should not be worked around — there is no useful degraded mode, because
without a gyroscope nothing tracks a pan.
