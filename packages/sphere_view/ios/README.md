# `ios/` — the AVFoundation + CoreMotion plugin

> **`Frameworks/sphere_stitch.xcframework` is not in this repository.** Field
> Capture targets Android only, and the prebuilt xcframework is 53 MB of static
> archive that no build here consumes. `sphere_view.podspec` still declares it as
> a `vendored_framework`, so an iOS target would fail at `pod install` until it is
> rebuilt:
>
> ```
> tools/build_native_mobile.sh --ios
> ```
>
> Nothing else in this directory was trimmed. The Swift sources, the podspec and
> `Classes/SphereStitchSymbols.c` are all intact.

The iOS half of the platform channels declared by
[`camera_platform.dart`](../lib/src/camera/camera_platform.dart) and
[`pose_platform.dart`](../lib/src/tracking/pose_platform.dart), plus the podspec
that builds [`src/sphere_stitch`](../src/sphere_stitch) and links the OpenCV
static libs.

Written in Phases 06 and 07. **Not yet run on a device** — it compiles and the logic it
delegates to is unit tested, but every number in Phase 06's exit criteria comes
from `example/integration_test/RUNNING.md`.

Deployment target is **iOS 14.0**, set by
`isContentAwareDistortionCorrectionSupported` (iOS 14.1, availability-guarded) —
which R2 §8 makes mandatory to switch off, because Apple applies that correction
"at its discretion" and variable geometry invalidates a fixed intrinsics model.

| File | What it does |
|---|---|
| `SphereViewPlugin.swift` | Entry point. Serialises every camera operation onto one queue, which is also how "never touch the session between requests" becomes a guarantee |
| `CameraSessionIOS.swift` | Open, probe the three intrinsics tiers, meter, lock, bracket, close |
| `TimestampMapper.swift` | Host time → `systemUptime`, measured rather than assumed |
| `PreviewTexture.swift`, `ThermalMonitor.swift`, `ImageStatistics.swift` | Preview via `FlutterTexture`; thermal state; the grey-card measurement |
| `MotionSessionIOS.swift` | Phase 07. `CMDeviceMotion` under `.xArbitraryCorrectedZVertical` |
| `Messages.g.swift` | Generated from `pigeons/camera_api.dart`. Do not edit |

| Concern | Lands in |
|---|---|
| `sphere_view.podspec` wiring the OpenCV static libs | Phase 00 Spike A / Phase 03 |

**Mandatory on every capture, whichever intrinsics path is used** (Math §4.2):
set `isGeometricDistortionCorrectionEnabled`,
`isContentAwareDistortionCorrectionEnabled` and
`isAutoContentAwareDistortionCorrectionEnabled` all to `false`. Apple's own docs
say content-aware correction is applied "at its discretion" — variably,
per-frame, content-dependent — which invalidates any fixed intrinsics model.

The intrinsics fallback chain, in priority order:

1. **`AVCameraCalibrationData.intrinsicMatrix`** — a true 3×3 plus
   `lensDistortionLookupTable`. Requires a dual/multi-camera virtual device, so
   R2 found it **unavailable on base iPad, iPad Air and iPad mini outright**.
   Design for its absence; this is not a degraded case, it is the common one.
2. **`AVCaptureConnection.cameraIntrinsicMatrix`**, via
   `AVCaptureVideoDataOutput` — *not* photo output. The only measured path on a
   single-lens iPad. **Unconfirmed on our fleet**: forum evidence directly
   conflicts, and Phase 00 Spike B (`spikes/spike_bc_device`) exists to settle
   whether the sample-buffer attachment actually arrives per device.
3. **`AVCaptureDevice.Format.videoFieldOfView`** — confirmed **horizontal** (R2),
   so `fx = (W_px / 2) / tan(FOV / 2)`. Use it with GDC explicitly disabled, not
   `geometricDistortionCorrectedVideoFieldOfView`, which describes the post-GDC
   frame and only applies while GDC is on.
4. **EXIF fallback**, `fx = W_px · FocalLengthIn35mmFilm / 36`.

**The chain itself is not in this directory.** `CameraSessionIOS.swift` reports
what it observed — including, critically, whether the tier-2 sample-buffer
attachment *actually arrived* rather than merely whether the capability flag said
it would — and computes no `fx`. Math §4.2 lives once, in
`lib/src/camera/intrinsics_resolver.dart`, alongside Android's §4.1. Two
implementations of one formula drift, and this one decides the focal length; it
also makes the branch-selection test a laptop test over all six rungs instead of
a device test over the one rung an iPad happens to reach.

**Distortion on iOS is radial-only.** `lensDistortionLookupTable` is a 1D array
of magnification factors along the radius from `lensDistortionCenter`, with no
tangential component. Fitting Brown–Conrady means least-squares on
`r'/r = 1 + k1·r² + k2·r⁴ + k3·r⁶` with `p1 = p2 = 0` **forced** — Apple's model
gives no basis for tangential terms, so fitting them would be fitting noise.

## The pose half (Phase 07)

**`.xArbitraryCorrectedZVertical`, never `.xTrueNorthZVertical`.** The
true-north frames pull in the magnetometer, and indoors that field is bent tens
of degrees by rebar, steel studs and lift motors — the failure Math §1.1 rejects
the compass to avoid. The `Corrected` in the name is Core Motion's own long-term
yaw-drift compensation, which is exactly what §1.1 wants: gravity-locked pitch
and roll, and a yaw that means "relative to where the session started".

**Apple's reference frame is Z-vertical and ours is Y-up, and that conversion is
not here.** Phase 07 §2 says it must be settled by experiment rather than by
derivation, so it lives once in
[`pose_frame_conversion.dart`](../lib/src/tracking/pose_frame_conversion.dart)
where it can be unit-tested over every branch, and the device test then confirms
the platform documentation rather than the arithmetic.

Two things *are* resolved here:

- **The gravity sign.** `CMDeviceMotion.gravity` reads `(0, 0, −1)` with the
  device flat on its back — pointing *toward* the earth, the opposite of
  Android's `TYPE_GRAVITY`. It is negated and normalised so the wire carries one
  convention, and Dart cross-checks the result rather than trusting it.
- **Nothing about the clock.** `CMDeviceMotion.timestamp` is `systemUptime`,
  which is the base `TimestampMapper` already converts sample buffers *onto*, so
  the offset is exactly zero and is reported as such. Measuring it a second time
  here would measure the same quantity twice and invite the two answers to
  disagree.

**`NSMotionUsageDescription` is required — this reversed in Phase 13.** The
narrow reading is still true as far as it goes: the key gates `CMPedometer` and
`CMMotionActivity`, and `CMMotionManager`'s device motion does not itself raise
a TCC prompt on the iOS versions we have looked at. But Apple's own guidance is
to include the string whenever an app links CoreMotion, more CoreMotion APIs
have been pulled under the requirement over time, and App Store review has
rejected for it.

What settles it is the failure mode rather than the letter. If the key turns out
to be needed and is missing, the attitude stream simply never delivers: no
crash, no prompt, no log. The capture screen shows a reticle that does not move
and a shutter gate that never opens, on a site, and it reads as a broken app.
The key costs one line, and being wrong in the other direction costs nothing at
all. Include it; `docs/INTEGRATION.md` tells consumers to.
