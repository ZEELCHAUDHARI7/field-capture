# Phase 01 — Package skeleton, data model, public API

**Goal:** the complete type surface and directory layout, with no behaviour.
Everything downstream depends on these types, so getting them right now avoids
churn in every later phase.

**Duration:** 2–3 days. **Depends on:** nothing. **Blocks:** everything.

Deliberately independent of Phase 00 so the two can run in parallel.

---

## 1. What gets deleted

The current `lib/` is replaced. Keep as reference until Phase 11, then delete:

| Path | Fate |
|---|---|
| `lib/src/stitching/equirectangular_stitcher.dart` | **delete** — replaced by the native pipeline. Its push–pull fill is worth porting to C++ for pole filling (Phase 04) |
| `lib/src/sensors/orientation_tracker.dart` | **delete** — replaced by platform AHRS (Phase 07) |
| `lib/src/guidance/capture_planner.dart` | **rewrite** as `plan/plan_builder.dart` — the ring/stagger idea is right, the hard-coded FOV is not |
| `lib/src/guidance/guidance_engine.dart` | **rewrite** — keep the shape |
| `lib/src/viewer/**` | **keep** — the GPU equirect viewer is fine; improved in Phase 11 |
| `lib/src/utils/{math_utils,quaternion_utils}.dart` | **keep**, extend |
| `lib/src/services/blur_detector.dart` | **keep** as `quality/sharpness.dart` |
| `lib/src/widgets/**` | **rewrite** as `ui/` — Phase 09 |
| `example/` | **rewrite** in Phase 09 |

Remove `camerawesome` and `sensors_plus` from `pubspec.yaml`: both are replaced
by our own platform plugin. Add `ffi`, and `pigeon` as a dev dependency.

---

## 2. Directory layout

Create every directory from §5 of [00_ARCHITECTURE.md](00_ARCHITECTURE.md), each
file present with its types and doc comments, `UnimplementedError` in bodies.

---

## 3. The data model

These are the types every other phase consumes. All are immutable, all have
`toJson`/`fromJson` (the stitch ABI is JSON), all have `==`/`hashCode`.

### 3.1 Intrinsics

```dart
enum IntrinsicsSource { platformCalibration, derivedFromPhysics, exifFallback, refinedByStitcher }

class CameraIntrinsics {
  final double fx, fy, cx, cy;        // pixels, in imageSize coordinates
  final Size imageSize;
  final DistortionModel? distortion;
  final IntrinsicsSource source;

  double get hfovRadians => 2 * atan(imageSize.width  / (2 * fx));
  double get vfovRadians => 2 * atan(imageSize.height / (2 * fy));

  /// Rescale to a different output resolution (same crop / aspect only).
  CameraIntrinsics scaledTo(Size newSize);
}

/// OpenCV Brown-Conrady ordering: (k1, k2, p1, p2, k3).
class BrownConradyDistortion implements DistortionModel { ... }

/// iOS radial-magnification LUT, applied directly.
class LookupTableDistortion implements DistortionModel { ... }
```

`source` is carried all the way into `StitchReport` so a bad panorama can be
traced back to a bad focal estimate.

### 3.2 Pose

```dart
class DevicePose {
  final Quaternion deviceToWorld;   // §2 of 01_MATH_AND_CONVENTIONS
  final Vector3 gravityWorld;       // measured up, for the levelling step (§7)
  final int timestampUs;            // monotonic clock, SAME base as frame timestamps
  final double angularSpeedRadPerSec;

  double get yaw   => atan2(forward.x, forward.z);
  double get pitch => asin(forward.y.clamp(-1.0, 1.0));
  Vector3 get forward => deviceToWorld.rotated(Vector3(0, 0, -1));

  /// Row-major 3x3, already converted to the OpenCV camera->pano frame.
  List<double> toOpenCvRotation();
}
```

The single most important field is `timestampUs`. It **must** share a clock base
with the camera's frame timestamps, or pose/frame pairing is wrong by tens of
milliseconds, which at a realistic 60°/s pan is 1–2° of error — larger than
everything bundle adjustment is trying to fix. Phase 07 owns proving this.

### 3.3 Plan

```dart
class CaptureTarget {
  final int index, ringIndex, indexInRing;
  final double yaw, pitch;          // radians, world frame
  final String ringLabel;
  Vector3 get direction;
}

class CapturePlan {
  final List<CaptureTarget> targets;
  final CameraIntrinsics intrinsics; // the plan is only valid for these
  final double overlapFraction;
  final CoverageReport coverage;     // must satisfy S5 or the plan is rejected
}

class CoverageReport {
  final double fractionCoveredAtLeastOnce;   // must be 1.0
  final double fractionCoveredAtLeastTwice;  // S5c sanity floor: >= 0.70
  final List<({double yaw, double pitch})> gaps;
  bool get isAcceptable;
}
```

### 3.4 Captured data

```dart
class ExposureShot {
  final String filePath;
  final double evBias;
  final int? exposureTimeNs, iso;
  final int timestampUs;
}

class CapturedPosition {
  final int targetIndex;
  final DevicePose pose;              // interpolated to the 0 EV shutter time
  final List<ExposureShot> shots;     // 3 when bracketing, 1 when locked
  final double sharpness;             // Laplacian variance of the 0 EV shot
  final double steadinessRadPerSec;   // angular speed at shutter
}

class CaptureBundle {
  final String sessionId;
  final Directory directory;          // holds the JPEGs + bundle.json
  final CapturePlan plan;
  final CameraIntrinsics intrinsics;
  final List<CapturedPosition> positions;
  final double? headingDegrees;       // for GPano PoseHeadingDegrees, optional
  final Map<String, Object?> deviceInfo;

  Future<void> save();                        // writes bundle.json
  static Future<CaptureBundle> load(Directory d);  // for tools/replay
}
```

`CaptureBundle` being a **self-describing on-disk directory** is what makes
offline replay and permanent regression tests possible (§6.6 of the
architecture). `save`/`load` must round-trip exactly — that is this phase's
most important test.

### 3.5 Config

```dart
sealed class ExposureStrategy {
  const factory ExposureStrategy.locked() = LockedExposure;
  const factory ExposureStrategy.bracket3({double evSpread}) = Bracket3Exposure;
}

enum QualityTier { low, mid, high }   // 4096 / 6144 / 8192 wide — see arch §6.5

class SphereCaptureConfig {
  final ExposureStrategy exposure;        // default bracket3(evSpread: 2.0)
  final double overlapFraction;           // default 0.33
  final bool captureNadir;                // default false — it is the user's feet
  final bool autoShutter;                 // default true
  final double aimToleranceDegrees;       // default 4.0
  final double steadinessThresholdRadPerSec; // default 0.12  (~7 deg/s)
  final Duration dwell;                   // default 350 ms
  final double minSharpness;              // Laplacian variance floor
  final QualityTier? qualityTier;         // null = auto-probe from RAM
}
```

Note the tightened gates versus the current code: aim tolerance 4° (was 10°) and
steadiness 0.12 rad/s (was 0.25). The old values were loose because the old
pipeline had no way to fix residual error; the new one wants good seeds and
sharp frames.

### 3.6 Results

```dart
enum StitchStage { fusing, undistorting, findingFeatures, matching,
                   adjusting, warping, compensating, seaming, blending,
                   fillingPoles, encoding }

class StitchProgress { final StitchStage stage; final double fraction; final String? message; }

class StitchReport {
  final double rmsReprojectionErrorPx;   // S1
  final double loopClosureErrorDegrees;  // S2
  final double maxGainRatio;             // S4
  final double coverageFraction;         // S5
  final double refinedFocalPx;
  final CameraIntrinsics refinedIntrinsics;
  final double residualTiltDegrees;
  final List<int> droppedPositionIndices;
  final List<String> warnings;           // never silently degrade
  final int elapsedMs;
  final QualityTier tierUsed;
  bool get meetsQualityTargets;
}

class StitchResult { final String equirectPath; final int width, height; final StitchReport report; }
```

`StitchReport` is what turns "perfect" from an opinion into a number, both in
tests and in the field.

---

## 4. Public API

`lib/sphere_view.dart` exports exactly:

```dart
// capture
SphereCaptureSession, SphereCaptureView, SphereCaptureConfig, ExposureStrategy, QualityTier
// stitch
SphereStitcher, StitchProgress, StitchResult, StitchReport, StitchStage
// data
CaptureBundle, CapturedPosition, ExposureShot, CapturePlan, CaptureTarget,
CameraIntrinsics, DevicePose, CoverageReport
// view
SphereViewer, SphereViewerController
```

Intended usage — keep this snippet in the README and make it compile:

```dart
final session = await SphereCaptureSession.create(config: const SphereCaptureConfig());

await Navigator.push(context, MaterialPageRoute(builder: (_) => SphereCaptureView(
  session: session,
  onCompleted: (bundle) => Navigator.pop(context, bundle),
)));

final result = await SphereStitcher().stitch(bundle, onProgress: (p) => setState(...));
if (!result.report.meetsQualityTargets) { /* surface report.warnings */ }
```

---

## 5. Tests

- `bundle_roundtrip_test.dart` — `save()` → `load()` is bit-exact for every field
- `conventions_test.dart` — the §2 verification from
  [01_MATH_AND_CONVENTIONS.md](01_MATH_AND_CONVENTIONS.md): forward, up, and a
  handful of known yaw/pitch → pixel mappings
- `intrinsics_test.dart` — `scaledTo` preserves FOV; FOV ↔ focal round-trips
- `json_schema_test.dart` — every model round-trips through JSON

---

## Exit criteria

- [ ] `flutter analyze` clean, zero warnings
- [ ] All four test files pass
- [ ] The README snippet compiles (as a test, not by eye)
- [ ] No `camerawesome` / `sensors_plus` remaining in `pubspec.yaml`
- [ ] Every public type has a doc comment explaining *why it exists*, not what it is
