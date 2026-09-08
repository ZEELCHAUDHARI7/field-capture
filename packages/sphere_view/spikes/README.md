# Phase 00 spikes — how to run them

**Throwaway.** Delete this directory once the findings are written.

Two things live here:

| Directory | Spike | Needs a device? |
|---|---|---|
| `spike_a_opencv/` | A — OpenCV build, size, 16 KB alignment | Build: no. Probe: yes |
| `spike_bc_device/` | B — intrinsics, C — bracketed burst | **Yes** |

Spike A's build measurements are already done and recorded in
`phases/findings/R1_opencv_distribution.md`. What is left everywhere else needs
hardware.

---

## What I need from you

Run **one app** on **each device you can get hold of**, tap one button, and send
back one JSON blob. That is the whole ask.

**Name the device every time.** A measurement without a device name is not a
finding — for Android the report captures `Build.MODEL` automatically, for iOS
it captures the machine identifier (`iPad14,3` etc.), so as long as you send the
JSON the naming is handled.

### The devices that matter most

1. **Any iPad you will actually ship on** — this settles whether
   `cameraIntrinsicMatrix` works, which is the top Spike B question and has
   conflicting evidence going back to 2017.
2. **The rugged Android tablets** (Zebra / Honeywell / Panasonic) — R3 found
   *no* data anywhere on whether these have `MANUAL_SENSOR`. If they don't,
   manual bracketing is impossible on them and Phase 06 needs the fallback path.
3. **A Galaxy Tab A** or whatever mid-range Android tablet is in the fleet.

More devices is better, but one iPad plus one Android tablet already unblocks
Phase 03 and Phase 06.

---

## Running it

```bash
cd spikes/spike_bc_device
flutter pub get

# Android — just plug in and go
flutter run --release -d <device-id>

# iOS — needs a signing team set once
open ios/Runner.xcworkspace   # or Runner.xcodeproj if there is no workspace
#   Runner target -> Signing & Capabilities -> pick your Team
flutter run --release -d <device-id>
```

`flutter devices` lists the ids.

**Use `--release`.** A debug build's timing numbers are worthless, and timing is
the entire point of Spike C.

### At the device

1. Point the camera at a **static, evenly lit scene**. Ideally a **grey card**
   (or any neutral card / white paper) filling the middle of the frame — the
   centre 20% is what the drift test measures.
2. Prop the tablet up or brace it. The gyro trace during the burst is part of
   the measurement, so hand shake shows up as data.
3. Tap **Run everything**. It takes about a minute.
4. Tap **Copy JSON** and paste it back to me. It is also written to disk:
   - Android: `/sdcard/Android/data/com.asite.sphereview.spike_bc/files/spike_c/spike_report.json`
   - iOS: the app's Documents dir (Files app → On My iPad → spike_bc)

The captured frames land next to the report, so if a number looks odd we can
look at the actual pixels.

### Reading the on-screen log

The app prints a line like:

```
→ spikeC_jpeg: 512, 498, 505 ms (median 505 ms) — WITHIN the ~600 ms budget
```

That single line is the answer to the highest-priority question in the project.
If the median comes back over 600 ms, the JSON still tells us *why* — whether
the sensor cadence or the JPEG encode is the cost — and the `yuv` run tells us
whether deferring the encode fixes it.

---

## The one manual measurement: FOV cross-check

Worth ten minutes, per device. It is the cross-check that proves the derived
focal length is right, and Phase 08's ring planner is built on that number.

1. Tape two marks on a wall. Measure the distance between them, `s`.
2. Stand the tablet so the lens is perpendicular to the wall. Measure the
   lens-to-wall distance, `D`. Both in the same units, to the mm if you can.
3. In any camera app, at the **same aspect ratio the spike reported as
   `largestJpeg4x3`**, move until the two marks sit **exactly at the left and
   right edges** of the frame.
4. Report `s`, `D`, and the device name.

Then `HFOV_true = 2·atan(s / (2·D))`. This should agree within 2% with the
`hfovDeg` in the report's `derivedIntrinsics` (Android) or with
`derived_vfov_horizontal` / the `videoFieldOfView` reading (iOS). A bigger
disagreement means the crop/aspect-fit term in Math §4.1 is wrong, which would
be worth knowing before Phase 06 is built on it.

---

## Spike A on-device probe (optional, do last)

Spike A's *build* questions are already answered. This step only confirms the
library runs on real hardware.

```bash
cd spikes/spike_a_opencv
./build_android.sh                       # ~2 min per ABI
mkdir -p ../spike_bc_device/android/app/src/main/jniLibs/arm64-v8a
cp out/android/base/arm64-v8a/libsv_spike.so \
   ../spike_bc_device/android/app/src/main/jniLibs/arm64-v8a/
```

Rebuild and rerun the app; the `spikeA_opencv` section of the report fills in
with the result of *executing* SIFT, bundle adjustment, graph-cut, multi-band
blending, spherical warping, Mertens fusion and ECC on device. Until then it
reports `available: false`, which is expected and does not block B or C.

---

## If something goes wrong

- **`runBracket` throws on Android** — check `hasManualSensor` in the
  capabilities dump. If it is `false`, that *is* the finding; the app falls back
  to AE compensation and says so in `bracketPlan.note`.
- **Permission denied** — the app asks on first run; if you dismissed it, grant
  Camera in Settings and rerun.
- **iOS build fails on signing** — set the Team in Xcode once, as above.
- **Anything else** — send me the on-screen log, it records every failure with
  the step that produced it.
