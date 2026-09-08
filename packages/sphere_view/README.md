# sphere_view

Capture a true 360°×180° spherical panorama from a handheld phone or tablet,
and stitch it into a single equirectangular image good enough that a
construction manager can read a defect off it.

`sphere_view` is a standalone Flutter package — no dedicated 360° camera, and no
host-app integration required. The driving use case is a **construction site
walk**: the manager draws a path on a plan and captures a 360 at each waypoint.
That is what sets the requirements — main-camera-only tablets, high-dynamic-range
interiors, low-texture surfaces, and a manager who cannot stand still for long.

> **Status: 0.1.0, and under construction.** Every phase is written: the stitch
> pipeline (03–05), the camera and pose plugins (06–07), the capture
> orchestration (08), the capture UI (09), the background isolate pipeline (10),
> the output metadata and viewer (11), the quality and device work (12), and the
> example app and release readiness (13).
>
> **What is measured and what is not.** The synthetic harness measures S1–S6 on
> nine profiles every run ([`docs/METRICS.md`](docs/METRICS.md)), and the parallax
> floor is measured and published rather than described. The **device matrix is
> empty**: S7, S8, S9, thermal behaviour and battery drain per station are
> statements about hardware, and no device has been run
> ([`docs/DEVICE_MATRIX.md`](docs/DEVICE_MATRIX.md) has a row per fleet device
> saying so, and one integration test fills a row in per device). The
> **real-site corpus is empty** too: the mechanism is in the quality gate and it
> reports itself absent on every run rather than passing quietly
> ([`docs/FIELD_CORPUS.md`](docs/FIELD_CORPUS.md) is the capture protocol). The
> capture UI's sunlight and gloves checks cannot be automated at all
> ([`docs/CAPTURE_UI_FIELD_CHECKLIST.md`](docs/CAPTURE_UI_FIELD_CHECKLIST.md)).
> See [`phases/README.md`](phases/README.md) for the state of each phase.

## What it does

1. **Probe** — reads the camera's *real* intrinsics: focal length in pixels,
   principal point, distortion model, field of view.
2. **Plan** — derives the ring/target list from the measured FOV at a 0.33
   target overlap, then *proves* on a 1° lattice that every sphere direction is
   covered at least twice before the camera ever opens.
3. **Meter** — a 2 s pre-sweep of the sphere picks one exposure, white balance
   and focus, then hard-locks all three for the session.
4. **Capture** — per target: aim gate, steadiness gate, dwell, then a hardware
   bracketed burst, with the device pose interpolated to the exact shutter
   timestamp.
5. **Stitch** — natively, on a background isolate: Mertens exposure fusion,
   undistortion, SIFT, IMU-gated matching, bundle adjustment seeded by the IMU,
   spherical warp, gain compensation, graph-cut seam finding, multi-band
   blending and pole fill.
6. **Tag** — XMP GPano and EXIF, so the file opens as an interactive sphere in
   Google Photos, Facebook, Street View, Marzipano and Pannellum. Without it the
   output is "a wide JPEG"; with it, a construction record attached to a plan
   works for somebody who does not have this app.

The IMU is used as a **prior, not a measurement**: it decides which image pairs
are worth matching, seeds bundle adjustment into the right basin, and supplies
the gravity axis for levelling. Bundle adjustment then overwrites the rotations
with photometrically correct ones.

## Device requirements

| | requirement | what happens otherwise |
|---|---|---|
| **gyroscope** | required, no exceptions | the feature is **hidden**, with a reason that names the missing part |
| camera | one rear camera is enough | — |
| exposure bracketing | wanted, not required | single-exposure capture; windows clip and shadows crush, and the report says so |
| lens distortion model | wanted, not required | slightly less exact joins near frame edges |
| RAM | 3 GB minimum | the output tier is probed from RAM: 4096 / 6144 / 8192 wide |
| Android | `minSdk 24`, Camera2, **arm64** | 32-bit ABIs are not shipped: S9 budgets 700 MB of peak RSS for one stitch |
| Android, for the lens model | **API 28+** | `LENS_DISTORTION` and `SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE` are 28+, so 24–27 is `noDistortionModel`. Every 28+ read is version-guarded; below it the two array rectangles are identical anyway (R2 §4), so the active array is the correct anchor |
| iOS | **14.0+** | `isContentAwareDistortionCorrectionSupported` (14.1, availability-guarded) must be switched off, because Apple applies that correction "at its discretion" and a variable geometry invalidates a fixed intrinsics model. The confirmed intrinsics path, `AVCaptureConnection.cameraIntrinsicMatrix`, is older than this |

Ask before offering the feature, not during it:

```dart
final capability = await SphereCapabilityProbe.probe();

if (!capability.isSupported) {
  // No gyroscope. There is no useful degraded mode — without one there is no
  // attitude source that tracks a pan — so hide the entry point and say why.
  return UnsupportedNotice(reason: capability.blockingReason!);
}

// What this device can actually do, applied to the session config: a `LEGACY`
// camera cannot bracket, and asking it for three exposures yields one frame,
// which a frame gate expecting three rejects at *every* position.
final config = capability.configFrom(const SphereCaptureConfig());

for (final warning in capability.warnings) {
  showBefore(warning.message);  // "single-exposure only on this tablet…"
}
```

`SphereCapability` is one of `full`, `noBracketing`, `noDistortionModel` or
`unsupportedNoGyro`. The probe opens no camera — it reads motion capabilities,
camera descriptors and total RAM — so it is cheap enough to stay at the entry
point, which is the point: discovering on site that a tablet cannot do this is
acceptable, discovering it after 25 captures is not.

## Getting started

```yaml
dependencies:
  sphere_view: ^0.1.0
```

### Build the native library — once, by script

The stitch pipeline is C++ over OpenCV. It is built from source, and **the
build is scripted rather than described**:

```sh
tools/build_native_mobile.sh          # Android + iOS; 10–20 min the first time, then cached
```

Do **not** install OpenCV from Homebrew, CocoaPods or a prebuilt release —
every one of those channels is wrong here for measured reasons.
[`docs/BUILDING_NATIVE.md`](docs/BUILDING_NATIVE.md) has the whole story,
including what to do when it goes wrong.

### Platform setup

New in Phase 13: [`docs/INTEGRATION.md`](docs/INTEGRATION.md) is the full guide
for a consuming app. The minimum is below.

#### Android

`minSdk 24`, arm64. The plugin declares `CAMERA` in its own manifest, so it
merges into yours — but **your app must request it at runtime**. Camera2 throws
a bare `SecurityException` from deep inside the framework when the permission is
missing, which reaches Dart as an untyped failure that looks like broken
hardware.

Set the same NDK in your app's `android/app/build.gradle.kts`:

```kotlin
ndkVersion = "28.2.13676358"   // must match spikes/spike_a_opencv/config.sh
```

Not a preference. The OpenCV static libraries your app links were built with
that NDK, and two NDK versions in one link is a libc++ ABI mismatch. It is also
the version that emits 16 KB-page-aligned output by default, which Google Play
has required since 2025.

`HIGH_SAMPLING_RATE_SENSORS` is **not** required: it gates sensor rates above
200 Hz on API 31+, and the attitude stream here runs at 100 Hz. If you raise the
rate yourself, you need it.

#### iOS

Deployment target **14.0**. Add both keys to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Used to capture 360° panoramas.</string>
<key>NSMotionUsageDescription</key>
<string>Used to track which way the device is pointing during a capture.</string>
```

**`NSMotionUsageDescription` is the one to get right.** Apple's guidance is to
include it whenever an app links CoreMotion, and its absence does not announce
itself: not a crash, not a prompt, but an attitude stream that never delivers.
The capture screen then shows dots that do not move and a shutter gate
that never opens, and it reads as a broken app rather than as a missing key. It
costs one line.

Capture needs a real device — a simulator has no camera and no gyroscope, and
the capability probe refuses on both counts.

## Usage

### Capture, stitch, view

```dart
import 'package:flutter/material.dart';
import 'package:sphere_view/sphere_view.dart';

Future<StitchResult?> captureAndStitch(BuildContext context) async {
  final session = await SphereCaptureSession.create(
    config: const SphereCaptureConfig(),
  );
  if (!context.mounted) return null;

  final bundle = await Navigator.push<CaptureBundle>(
    context,
    MaterialPageRoute(
      builder: (_) => SphereCaptureView(
        session: session,
        onCompleted: (bundle) => Navigator.pop(context, bundle),
      ),
    ),
  );
  if (bundle == null) return null;

  final result = await SphereStitcher().stitch(
    bundle,
    onProgress: (p) =>
        debugPrint('${p.stage.name} ${(p.fraction * 100).round()}%'),
  );

  if (!result.report.meetsQualityTargets) {
    for (final warning in result.report.warnings) {
      debugPrint(warning);
    }
  }
  return result;
}
```

That snippet is compiled by `test/readme_snippet_test.dart`, so it cannot drift
out of date silently.

### Stitch in the background instead

Awaiting the stitch is right for one station, where the panorama is the thing
the user pressed the button for. It is wrong for a site walk: 30 stations at up
to 60 s each is half an hour of standing still. `StitchQueue` is the other path.

```dart
final queue = StitchQueue(directory: await getApplicationSupportDirectory());
await queue.load();          // picks up anything a previous run left behind
await queue.enqueue(bundle); // returns immediately; the manager keeps walking
await queue.start();

queue.events.listen((event) {
  if (event.result != null) debugPrint('${event.entry.sessionId} done');
});
```

It stitches one bundle at a time — two at once will run the device out of
memory — persists to disk so it survives an app restart, and waits while the
device is thermally stressed. A bundle interrupted mid-stitch restarts from the
beginning rather than resuming: a restart costs 60 s, and checkpointing inside
the native pipeline does not pay for its own complexity.

### The capture screen

`SphereCaptureView` is six elements and nothing else:

```
┌────────────────────────────────────────┐
│  ▂▂▂▂▂▂▂ ▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂     7/29     │  segmented progress + counter
│                                        │
│                  ●                     │  target dot — moves with the scene
│                                        │
│              ╭───────╮                 │  centre ring — fixed. Grey until the
│             │         │                │  dot is inside it, then a white arc
│              ╰───────╯                 │  fills it clockwise over the 350 ms
│                                        │  dwell, and the shutter fires
│             Turn right                 │  one line, only when it adds
│                                        │  something
│  (✕)                        (◉)        │  exit · manual shutter
└────────────────────────────────────────┘
```

Put the dot in the ring and it fills. That is the whole interaction — grey means
keep looking, a filling arc means hold still, and the ring flashing white means
that one is done. Nothing to read, nothing to press.

The dot is geometrically truthful — it is projected through the live pose and the
*measured* intrinsics, so it sits where the target actually is in the scene.
When the target is off screen the dot is replaced by an arrow pinned to the
edge, never a dot clamped to it: a clamped dot implies "nearly there" when the
user has to turn 150°.

There is deliberately no coverage minimap, thumbnail strip, grid overlay,
histogram, filter, settings gear or resolution picker. Each was considered and
rejected. The user's attention has to be on the physical world — where they are
standing and what they are about to walk into — and every element on screen is
attention taken away from aiming.

Two thin screens bracket it, and both are exported so a host app can use its own
station list around them:

* `SpherePreCaptureScreen` — "stand where the pin is, hold the tablet upright,
  **pivot, don't walk**", with a diagram. That middle instruction is the
  parallax mitigation from architecture §3 and the highest-value sentence in the
  feature: handheld, a 10 cm swing puts ~97 px of irreducible disparity on a
  wall at 1 m, and no stitcher removes it.
* `SphereReviewScreen` — the capture, its coverage, and every compromise in
  plain language ("3 photos could not be used", "the horizon is off level by
  1.4°"), never a generic "stitching may be imperfect".

Capture is **portrait-locked** for the length of a session. That is a decision,
not a shortcut: the plan is computed for one intrinsics/orientation pair, so a
mid-session rotation would invalidate every remaining target — and portrait also
gives the larger vertical field of view, which means fewer rings and a shorter
capture.

### Which way does the panorama face?

The output records a compass heading for the image centre, and *where that
heading came from*, because the two are not separable in practice:

```dart
// Best source: the manager drew a path on a plan whose north is surveyed, so
// the facing direction at a station is arithmetic. Costs the user nothing.
session.setPlanHeading(127.5);

// Fallback. Indoors the compass is wrong by tens of degrees — rebar, lift
// motors, steel studs — so it is recorded as what it is and a warning reaches
// `report.warnings`.
session.setMagnetometerHeading(310.0);

// Optional, and supplied rather than measured: this package holds no location
// permission and deliberately does not ask for one.
session.setLocation(GeoLocation(latitudeDegrees: 51.5074, longitudeDegrees: -0.1278));
```

With neither, `PoseHeadingDegrees` is **omitted** rather than written as 0 —
zero is a real bearing, due north, so writing it would make an unknown heading
indistinguishable from a surveyed one and every viewer would open the sphere
confidently facing the wrong way.

### View an existing equirectangular image

```dart
SphereViewer(
  image: File('path/to/panorama.jpg'),
  showControls: true,
);
```

Drag to look, pinch to zoom (clamped to 30°–100°), double-tap to reset. Pitch
stops at ±90° with a soft resistance rather than a wall, so there is no
upside-down state to get stuck in.

The viewer shows the 2048-wide preview written beside the panorama the moment it
has it and swaps in the full image when that decodes — it finds
`<name>_preview.jpg` on its own, so this costs nothing to use. It also queries
the GPU's maximum texture size and downscales to fit: many mid-range tablets cap
at 4096, and an 8192-wide upload there does not fail loudly, it renders a **black
sphere**.

Any 2:1 JPEG or PNG works, and any Flutter `ImageProvider` is accepted:

```dart
SphereViewer(imageProvider: AssetImage('assets/sample_pano.jpg'));
```

### Open facing a particular direction

```dart
SphereViewer(
  image: file,
  controller: SphereViewerController.forPanorama(
    metadata,               // from onMetadata, or GPanoReader
    lookAtCompassDegrees: 0, // open looking north
  ),
);
```

### Optional gyro look

```dart
SphereViewer(image: file, gyroscopeEnabled: true);
```

Hold the tablet up and move it to look around, on the same `PoseSource` capture
uses. Off by default: it is delightful when expected and disorienting when not.

### Drive the viewer programmatically

```dart
final controller = SphereViewerController(initialFovDegrees: 90);
SphereViewer(image: file, controller: controller);
// later:
controller.animateTo(yaw: math.pi / 2, fovDegrees: 60);
controller.autoRotateSpeed = 0.25; // rad/s
```

## Configuration

```dart
const config = SphereCaptureConfig(
  exposure: ExposureStrategy.auto(),
  overlapFraction: 0.33,
  captureNadir: true,
  autoShutter: true,
  aimToleranceDegrees: 4.0,
  steadinessThresholdRadPerSec: 0.12,
  dwell: Duration(milliseconds: 350),
);
```

Every default is the product decision, not a starting point. There is
deliberately **no output-size setting**: multi-band blending is memory-bound, so
the output resolution is a device tier probed from RAM (4096 / 6144 / 8192 wide)
rather than something a user should have to reason about.

## What "good" means here

Ten measurable criteria, checked by the synthetic harness and reported at
runtime in `StitchReport`:

```
S1  RMS reprojection error  < 1.0 px       S6  SSIM ≥ 0.97 / PSNR ≥ 32 dB
S2  loop closure            < 0.25°        S7  capture ≤ 90 s
S3  seam score              < 2× noise     S8  stitch ≤ 60 s
S4  max gain ratio          < 1.03         S9  peak RSS < 700 MB
S5  coverage: 100% ≥1×, every adjacent     S10 opens as a GPano photo sphere
    pair ≥25%, ≥2× at least 70%
```

S5 read "95% ≥2×" until Phase 02 measured it. That was wrong, and the derivation
is worth keeping: the double-covered fraction is exactly `ω/(1−ω)`, so demanding
95% *is* demanding 49% overlap — against a documented default of 33%. What the
pipeline needs is **pairwise** overlap, because feature matching works on pairs.
See Math §8.

If it does not have a number, it is not a criterion — it is an opinion. And the
package never silently degrades: every compromise it makes lands in
`StitchReport.warnings` and reaches the caller.

Warnings are **coded**, not prose:

```dart
for (final warning in result.report.warnings) {
  switch (warning.code) {
    case StitchWarningCode.positionsDropped:
      offerRetake(warning.data['indices']! as List);
    case StitchWarningCode.tierDowngradedAfterOom:
      suggestClosingOtherApps();
    default:
      show(warning.message);   // the plain-language sentence
  }
}
```

`warning.message` names the cause *and what to do differently* — "Stitching may
be imperfect" teaches nothing and reads as a shrug. The sentences live in one
reviewable table, a `switch` over the enum makes a missing one a compile error,
and a test asserts that every code the native library can emit is one Dart has a
sentence for. [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) is keyed to the
codes, symptom first.

## Honest limits

- **Parallax, measured.** Handheld, the lens traces a circle instead of staying
  at one point. At a 10 cm offset, a wall 1 m away carries 5.7° of irreducible
  disparity — 97 px at 6144 wide — and the measured S1 tracks that prediction at a
  consistent 0.7× across a 30× range of offset-to-distance
  ([`docs/METRICS.md`](docs/METRICS.md)). Graph-cut seam finding *hides* it: over
  the same range the seam score rises 3.4× → 5.0× while SSIM collapses 0.97 →
  0.63. Nothing removes it. **Even 3 cm of lens travel puts S1 six times over its
  target at 1 m**, so a tight room is a case for a monopod rather than for
  tuning — pivot on the lens, stand ≥1.5 m off surfaces, or clamp it
  ([`docs/CAPTURE_TECHNIQUE.md`](docs/CAPTURE_TECHNIQUE.md)).
- **Nadir.** Points at your feet, so it is off by default and filled instead.
- **Moving subjects.** A worker walking through the sphere appears once, twice,
  or half-cut.
- **No gyroscope, no capture.** Detected and refused up front.

## Architecture

```
lib/
  sphere_view.dart              public barrel
  src/
    api/         session, capture view, stitcher, and the data model
    camera/      platform interface, intrinsics probe, exposure lock
    tracking/    pose source, pose buffer (SLERP to shutter time)
    plan/        plan builder, capture plan, coverage validator
    guidance/    guidance engine, shutter gate
    quality/     sharpness, frame gate
    stitch/      isolate, FFI bindings, request builder, memory tier,
                 background queue
    metadata/    XMP GPano + EXIF writer, JPEG segment surgery
    viewer/      GPU equirect viewer, texture-limit probe, progressive load
    ui/          capture HUD
src/sphere_stitch/              native C++ pipeline (shared iOS + Android)
tools/synth, tools/replay       synthetic capture sets and offline replay
docs/                           platform requirements, integration notes
phases/                         the implementation plan
```

### Documentation

| | for whom |
|---|---|
| [`docs/INTEGRATION.md`](docs/INTEGRATION.md) | **anybody putting this in an app.** The three-call quickstart, the background queue, what to persist, the storage policy, and the capability gate |
| [`docs/BUILDING_NATIVE.md`](docs/BUILDING_NATIVE.md) | anybody whose first build failed. What `tools/build_native_mobile.sh` does, and what to do when it does not |
| [`docs/CAPTURE_TECHNIQUE.md`](docs/CAPTURE_TECHNIQUE.md) | the site team. One page, with the pivot diagram. Has more effect on output quality than most of the algorithm work |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | anybody holding a bad panorama. Symptom → cause → fix, keyed to the warning codes |
| [`docs/METRICS.md`](docs/METRICS.md) | anybody reading a `StitchReport`. What S1–S10 mean, and the measured parallax floor |
| [`docs/DEVICE_MATRIX.md`](docs/DEVICE_MATRIX.md) | whoever decides what ships. Generated from a device run, not typed |
| [`docs/FIELD_CORPUS.md`](docs/FIELD_CORPUS.md) | whoever goes to the site. The seven scenes and how to shoot them |
| [`docs/PLATFORM_ANDROID.md`](docs/PLATFORM_ANDROID.md), [`docs/PLATFORM_IOS.md`](docs/PLATFORM_IOS.md) | integrators |

`android/` and `ios/` hold the camera plugin, added in Phase 06 together with
the `flutter: plugin:` block — see [`docs/README.md`](docs/README.md) for why
they could not exist before it. The intrinsics derivation deliberately does
**not** live there: it is one Dart implementation over raw platform facts, in
`lib/src/camera/intrinsics_resolver.dart`, so that it can be unit-tested over
every branch on a laptop rather than only over the two branches the devices in
the room happen to take.

Full design rationale is in [`phases/00_ARCHITECTURE.md`](phases/00_ARCHITECTURE.md);
the normative coordinate frames and formulas are in
[`phases/01_MATH_AND_CONVENTIONS.md`](phases/01_MATH_AND_CONVENTIONS.md).

## Example

[`example/`](example) is one screen, three actions and no chrome, and it is the
working reference for everything in `docs/INTEGRATION.md`. It demonstrates seven
flows: capture, the **background queue** (two stations back to back, rows moving
`queued → stitching 42% → ready`), the viewer with gyro look, the full
`StitchReport` in plain language, export through the share sheet so the result
can be opened in Google Photos, a device report that answers "will this work on
my tablet", and resume-after-kill with a button that really does end the
process.

No plan viewer, no PDF, no map, no auth, no backend — those belong to the
consuming app, and leaving them out is what keeps the demo a demonstration of
this package rather than of an app that happens to use it.

## License

MIT.
