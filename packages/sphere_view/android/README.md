# `android/` — the Camera2 + SensorManager plugin

The Android half of the platform channels declared by
[`camera_platform.dart`](../lib/src/camera/camera_platform.dart) and
[`pose_platform.dart`](../lib/src/tracking/pose_platform.dart), plus the CMake
entry point that builds [`src/sphere_stitch`](../src/sphere_stitch) for the NDK.

Written in Phases 06 and 07. **Not yet run on a device** — it compiles and the logic it
delegates to is unit tested, but every number in Phase 06's exit criteria comes
from `example/integration_test/RUNNING.md`.

| File | What it does |
|---|---|
| `SphereViewPlugin.kt` | Entry point. Serialises every camera operation onto one thread, which is also how "never touch the session between requests" (§7 pitfall 1) becomes a guarantee rather than a hope |
| `CameraSession.kt` | Open, meter, hard lock, bracketed `captureBurst`, close |
| `CameraFacts.kt` | Reads `CameraCharacteristics` and computes no intrinsics — see below |
| `TimestampMapper.kt` | `SENSOR_TIMESTAMP` → the sensor clock, for both timestamp bases |
| `ThermalMonitor.kt`, `ImageUtils.kt` | Thermal state; pixel plumbing and the grey-card measurement |
| `MotionSession.kt` | Phase 07. `TYPE_GAME_ROTATION_VECTOR` + gravity + gyroscope, and the `SensorEvent.timestamp` clock-base probe |
| `Messages.g.kt` | Generated from `pigeons/camera_api.dart`. Do not edit |

| Concern | Lands in |
|---|---|
| `CMakeLists.txt` wiring the OpenCV static libs into the NDK build | Phase 00 Spike A / Phase 03 |

Three decisions are already settled and should not be re-litigated here:

- **Camera2, not CameraX** (R3). CameraX 1.5 still has no bracketing, and
  `ExtensionMode.HDR` returns one pre-fused frame with no per-frame control —
  which is exactly the control the pipeline needs.
- **Anchor every coordinate to `SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE`
  and always request `DISTORTION_CORRECTION_MODE_OFF`** (Math §4.1). That keeps
  the crop region, principal point and distortion coefficients in one frame and
  sidesteps the HAL's own correction, which AOSP concedes is imprecise.
- **`LENS_DISTORTION` → OpenCV is a pure reorder**, `{κ1, κ2, κ4, κ5, κ3}` →
  `(k1, k2, p1, p2, k3)`, with no value transform (R2, verified against AOSP).
  That reorder already exists in Dart as
  `BrownConradyDistortion.fromAndroidLensDistortion`; do not write a second copy
  in Kotlin.

Derive intrinsics **from physics as the primary path** and treat
`LENS_INTRINSIC_CALIBRATION` as an optional override when non-null — the reverse
of the usual instinct, and what R2's evidence supports: it is gated by no
capability flag and comes back null even on Pixel hardware.

**That derivation is not in this directory.** `CameraFacts.kt` reports raw
characteristics and computes no `fx`; the whole of Math §4.1 lives once, in
`lib/src/camera/intrinsics_resolver.dart`. The reason is the same one already
given above for the distortion reorder, one step up: two implementations of one
formula drift, this formula decides the focal length, and a Kotlin-versus-Swift
divergence would present as a device-specific stitcher bug rather than as a
plugin bug. It also makes Phase 06 §6's "picks the right branch for each
synthetic capability set" a laptop test that covers every rung, instead of a
device test that covers whichever two rungs the hardware in the room takes.

## The pose half (Phase 07)

**`TYPE_GAME_ROTATION_VECTOR`, never `TYPE_ROTATION_VECTOR`.** The two are
identical except that the plain one folds in the geomagnetic field, and indoors
that field is bent tens of degrees by rebar, steel studs and lift motors — the
failure Math §1.1 rejects the magnetometer to avoid. `usesMagnetometer` is
reported on the wire so a build that reaches for the wrong sensor shows up as a
recorded fact rather than as an unexplained heading error on a site.

**The Android world frame is Z-up and ours is Y-up, and that conversion is not
here.** Phase 07 §2 is explicit that it "must be proven by the §5 test, not by
derivation" — its own worked derivation produces a determinant −1 reflection
that would mirror the panorama. It lives in
[`pose_frame_conversion.dart`](../lib/src/tracking/pose_frame_conversion.dart),
for the same reason the intrinsics chain does one paragraph up, and one sharper
one: a conversion written in Kotlin could only ever be exercised on the devices
in the room.

Two things *are* resolved here, because both are facts about what this platform
reads rather than pieces of geometry:

- **The gravity sign.** AOSP documents the accelerometer as reading `+9.81` on
  Z with the device flat on its back, and `TYPE_GRAVITY` shares its coordinate
  system, so the reported vector points *away* from the earth. iOS reports the
  opposite sign. Each side normalises to one wire convention — unit, away from
  the earth — and Dart cross-checks the result rather than trusting either.
- **The timestamp base.** §6 pitfall 1 says `SensorEvent.timestamp`'s base
  varies by device, and Phase 06's `TimestampMapper` already *assumed* the usual
  case when it declared the camera-side `REALTIME` offset to be exactly zero.
  `MotionSession` measures it instead: the two candidates differ by however long
  the device has slept since boot, so one probe settles it beyond doubt.
