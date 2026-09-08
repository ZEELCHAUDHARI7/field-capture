# sphere_view — Architecture

> The technical design for capturing a true 360°×180° spherical panorama from a
> handheld phone or tablet, and stitching it into a single equirectangular image
> good enough that a construction manager can read a defect off it.

---

## 1. Success criteria

"Perfect" has to be measurable, otherwise we cannot tell whether a change helped.
Every one of these is checked automatically by the synthetic harness in
[Phase 02](PHASE_02_synthetic_rig.md) and reported at runtime in `StitchReport`.

| # | Criterion | Target | Measured by |
|---|---|---|---|
| S1 | Geometric accuracy | RMS reprojection error **< 1.0 px** at registration scale | bundle adjustment residual |
| S2 | Loop closure | yaw error after full 360° traverse **< 0.25°** | synthetic rig + BA |
| S3 | Seam invisibility | no seam detectable by the gradient-discontinuity metric above **2× local noise floor** | `seam_score` metric |
| S4 | Photometric consistency | max inter-frame gain ratio after compensation **< 1.03** | gain compensator output |
| S5 | Coverage | **100%** covered ≥1× (minus a declared-skipped nadir cap); every adjacent pair shares **≥25%**; ≥2× coverage **≥70%** | coverage validator |
| S6 | Fidelity vs ground truth (synthetic only) | **SSIM ≥ 0.97**, PSNR ≥ 32 dB | synthetic rig |
| S7 | Capture time | **≤ 90 s** per station on a main-camera-only tablet | on-device timing |
| S8 | Stitch time | **≤ 60 s** for 6144×3072 on an iPad (A14-class) / mid Android tablet | on-device timing |
| S9 | Peak RSS during stitch | **< 700 MB** | on-device instrumentation |
| S10 | Output validity | opens as a photo sphere in Google Photos / Facebook / any GPano viewer | XMP GPano validation |

S1–S6 are quality. S7–S9 are the constraints that stop us from "solving" quality
by throwing resolution at it. S10 is what makes the output useful outside our app.

---

## 2. Why the current implementation cannot reach these targets

The existing stitcher (`lib/src/stitching/equirectangular_stitcher.dart:225`)
reprojects each photo onto the sphere using **only the IMU quaternion**, then
averages overlapping contributions with a separable quadratic feather. Five
independent defects, none fixable by tuning:

1. **Sensor orientation is not accurate enough, by an order of magnitude.**
   The hand-rolled gyro-integration + accel complementary filter in
   `orientation_tracker.dart:42` is good to roughly ±2–5°. At a 6144 px wide
   equirect, 1° = 17 px. So every seam carries **35–85 px of misregistration**.
   No blend hides that.

2. **The focal length is a hard-coded guess.**
   `capture_config.dart:57` sets `horizontalFovDegrees = 52.0`. Real main-camera
   HFOV in portrait ranges ~46°–56° across the tablet fleet. A 4% focal error
   means the panorama **does not close** at 360° — the last frame lands ~14°
   away from the first.

3. **No lens distortion model at all.** Straight edges bow near frame borders,
   so even a perfectly-oriented frame cannot align with its neighbour at the
   overlap.

4. **Averaging is the wrong operator for misaligned pixels.** The feather at
   `equirectangular_stitcher.dart:325` *blends* the error into ghosting and
   blur. Real stitchers **cut** along a path where the two images agree
   (graph-cut) and only blend across a narrow band. Hide, don't average.

5. **No exposure compensation.** Auto-exposure changes between shots, so the
   output has visible brightness banding per frame even when geometry is right.

Additionally: 8 shots/ring at a 52° HFOV yields only ~15% overlap — below the
~30% that feature matching needs to be reliable. So the frames themselves are
not recoverable by a better algorithm; **the capture plan has to change too.**

**Conclusion:** the capture side (guidance, ring planning, isolate structure,
viewer) is worth keeping in spirit and rewriting for correctness. The stitcher
is replaced wholesale by a native OpenCV `detail::` pipeline.

---

## 3. The physical limit we cannot code around: parallax

A panorama is only geometrically consistent if every frame is taken from the
**same optical centre** (the lens entrance pupil / no-parallax point). Handheld,
the camera rotates about the user's wrist or torso, so the entrance pupil traces
a circle of radius `r`.

For an object at distance `d`, the induced angular disparity is `≈ atan(r/d)`:

| lens offset `r` | object at 1 m | object at 3 m | object at 10 m |
|---|---|---|---|
| 3 cm | 1.7° (29 px) | 0.6° (10 px) | 0.2° (3 px) |
| 10 cm | 5.7° (97 px) | 1.9° (33 px) | 0.6° (10 px) |
| 25 cm | 14° (240 px) | 4.8° (82 px) | 1.4° (24 px) |

(px at 6144-wide equirect.)

No amount of bundle adjustment fixes this, because there is no single rotation
that aligns both near and far content. Our three mitigations:

1. **Capture technique, documented and coached in-app.** Rotate the *tablet
   about a vertical axis through its own lens* — do not swing the tablet around
   your body. Target `r < 3 cm`. Stand ≥1.5 m from the nearest surface.
   A ~₹500 tablet clamp on a monopod makes `r ≈ 0` and is the recommended
   workflow for stations that matter.
2. **Graph-cut seam finding** routes the seam through low-gradient regions
   where the disparity is invisible, instead of averaging it into a ghost.
3. **Post-hoc detection from bundle adjustment.** A pure-rotation model fitted to
   data containing translation leaves a *structured* residual — larger for near
   content than far. Correlating residual magnitude with feature scale gives a
   translation signature for free, on every device, with no extra capture path. It
   is post-hoc, so it explains rather than prevents, but it turns "why does this one
   look bad" into a specific, honest warning (Phase 12 §2).

   *(An earlier plan used ARKit/ARCore to measure translation directly and warn
   during capture. It was cut for speed: VIO's unique value is translation, not
   accuracy — bundle adjustment already handles accuracy — and ARCore excludes much
   of the rugged-tablet fleet. If live walk detection is wanted later, the cheap
   route is optical-flow divergence on the preview stream, which works on every
   device, rather than an AR dependency.)*

This is documented up front so nobody spends a week trying to tune away a
physics problem.

---

## 4. End-to-end pipeline

```
┌─ ON DEVICE, FOREGROUND ─────────────────────────────────────────────────┐
│                                                                          │
│  1. PROBE          query every physical camera's real intrinsics         │
│                    (focal px, principal point, distortion, FOV)          │
│                          │                                               │
│  2. PLAN           plan_builder: measured FOV + target overlap 0.33      │
│                    → ring/target list; coverage_validator PROVES         │
│                      every sphere direction is hit ≥2×                   │
│                          │                                               │
│  3. METER          2 s pre-sweep of the sphere, pick one EV + WB + focus │
│                    → HARD LOCK AE / AWB / AF for the whole session       │
│                          │                                               │
│  4. GUIDED CAPTURE per target:  aim gate + steadiness gate + dwell       │
│                    → hardware bracketed burst (-2 EV, 0, +2 EV)          │
│                    → pose interpolated to the EXACT shutter timestamp    │
│                    → sharpness + steadiness recorded per shot            │
│                          │                                               │
│                    CaptureBundle {positions[], intrinsics, plan}         │
└──────────────────────────┼───────────────────────────────────────────────┘
                           │
┌─ BACKGROUND ISOLATE → FFI → C++ ────────────────────────────────────────┐
│                                                                          │
│  5. HDR FUSE       per position: ECC-align the 3 exposures,              │
│                    Mertens exposure fusion → one well-exposed LDR frame  │
│                          │                                               │
│  6. UNDISTORT      apply the measured Brown-Conrady / LUT model          │
│                          │                                               │
│  7. FEATURES       SIFT at ~0.6 MP registration scale                    │
│                          │                                               │
│  8. MATCH          ONLY pairs whose IMU poses overlap  → O(n·k), not n²   │
│                          │                                               │
│  9. BUNDLE ADJUST  BundleAdjusterRay, SEEDED with IMU rotations,         │
│                    refines all R_i + shared focal jointly;               │
│                    gravity axis CONSTRAINED by accelerometer             │
│                    (no blind waveCorrect guess)                          │
│                          │                                               │
│ 10. WARP           SphericalWarper → equirect canvas, scale = W/2π,      │
│                    with horizontal WRAP PADDING so the 360° seam closes  │
│                          │                                               │
│ 11. GAIN COMP      BlocksGainCompensator (kills residual banding)        │
│                          │                                               │
│ 12. SEAM           GraphCutSeamFinder (COST_COLOR_GRAD) — HIDES parallax │
│                          │                                               │
│ 13. BLEND          MultiBandBlender, 5 bands, in PADDED HORIZONTAL STRIPS│
│                    (memory bound — see §7)                               │
│                          │                                               │
│ 14. POLE FILL      push-pull pyramid fill for any uncovered nadir/zenith  │
│                          │                                               │
│ 15. ENCODE         JPEG + XMP GPano + EXIF (heading, GPS, station id)    │
│                          │                                               │
│                    StitchResult + StitchReport (S1..S5 measured)         │
└──────────────────────────────────────────────────────────────────────────┘
```

Progress from stages 5–15 is streamed to the UI via a shared-memory counter
(§6.3), not FFI callbacks.

---

## 5. Component architecture

```
sphere_view/
├── lib/
│   ├── sphere_view.dart                    public barrel (capture + stitch + viewer)
│   └── src/
│       ├── api/
│       │   ├── sphere_capture_session.dart  session lifecycle, the orchestrator
│       │   ├── sphere_capture_view.dart     the camera widget (minimal UI)
│       │   ├── sphere_stitcher.dart         stitch entrypoint, isolate owner
│       │   └── models/                      config, intrinsics, pose, bundle,
│       │                                    progress, result, report
│       ├── camera/
│       │   ├── camera_platform.dart         Pigeon-generated interface
│       │   ├── camera_probe.dart            intrinsics discovery + fallback chain
│       │   └── exposure_controller.dart     metering pre-sweep, AE/AWB/AF lock
│       ├── tracking/
│       │   ├── pose_source.dart             interface
│       │   ├── platform_ahrs_pose_source.dart
│       │   └── pose_buffer.dart             ring buffer + SLERP to shutter time
│       ├── plan/
│       │   ├── plan_builder.dart            measured FOV → targets
│       │   ├── capture_plan.dart
│       │   └── coverage_validator.dart      proves ≥2× coverage (S5)
│       ├── guidance/
│       │   ├── guidance_engine.dart         aim error → hint + gate state
│       │   └── shutter_gate.dart            aim ∧ steady ∧ dwell → fire
│       ├── quality/
│       │   ├── sharpness.dart               Laplacian variance
│       │   └── frame_gate.dart              accept / retake decision
│       ├── stitch/
│       │   ├── stitch_isolate.dart          worker isolate entry
│       │   ├── native_stitcher.dart         FFI bindings (ffigen)
│       │   ├── stitch_request.dart          JSON ABI payload builder
│       │   └── memory_tier.dart             device tier → output size, strips
│       ├── metadata/
│       │   └── gpano_writer.dart            XMP GPano + EXIF
│       ├── viewer/                          GPU equirect viewer (kept, improved)
│       └── ui/                              reticle, target dot, progress arc
│
├── src/sphere_stitch/                       NATIVE C++ (shared iOS + Android)
│   ├── sphere_stitch.h                      the C ABI (JSON in, file out)
│   ├── sphere_stitch.cpp                    stage orchestration + progress
│   ├── hdr_fuse.cpp                         stage 5
│   ├── registration.cpp                     stages 6–9
│   ├── compositing.cpp                      stages 10–13
│   ├── pole_fill.cpp                        stage 14
│   ├── report.cpp                           metric computation
│   └── CMakeLists.txt
│
├── android/                                 Camera2 + SensorManager plugin, CMake
├── ios/                                     AVFoundation + CoreMotion plugin, podspec
│
├── tools/
│   ├── synth/                               synthetic capture-set generator
│   └── replay/                              desktop CLI: bundle → stitch → metrics
│
├── phases/                                  ← this documentation
└── PROMPTS.md                               ← sequential build prompts
```

### Why native code is unavoidable

| Need | Dart possible? | Why native |
|---|---|---|
| SIFT + bundle adjustment | technically | 10–50× too slow; months to reimplement; lower ceiling |
| Graph-cut seam finding | no | needs max-flow over a large lattice |
| Multi-band blending | technically | huge Float32List churn, GC pressure, no SIMD |
| Bracketed hardware burst | no | `AVCapturePhotoBracketSettings` / Camera2 `captureBurst` |
| Real camera intrinsics | no | `CameraCharacteristics` / `AVCaptureDeviceFormat` |
| AE/AWB/AF hard lock | partially | existing plugins expose too little control |
| OS sensor fusion | no | `TYPE_GAME_ROTATION_VECTOR` / `CMDeviceMotion` |

So: one FFI native library for the pipeline, and one method-channel plugin per
platform for camera + sensors.

---

## 6. Key design decisions

### 6.1 The IMU is a *prior*, not a *measurement*

This is the central idea and it is what separates us from both the current
implementation and from stock OpenCV `Stitcher`.

- The current code **trusts** the IMU → 35–85 px errors.
- Stock OpenCV **ignores** the IMU → it chains pairwise homographies, which
  fails on low-texture construction surfaces (bare drywall, concrete slab) and
  aborts all-or-nothing.

We use the IMU pose to (a) decide *which pairs are worth matching* — turning
O(n²) matching into O(n·k) — (b) **seed** bundle adjustment so it converges to
the right basin instead of a local minimum, and (c) supply the **gravity axis**
so we never need OpenCV's `waveCorrect` heuristic. Then BA overwrites the
rotations with photometrically-correct ones. Best of both.

### 6.2 Mertens exposure fusion, not Debevec + tonemap

For the 3-shot bracket we use `cv::createMergeMertens()`, not
`createMergeDebevec()` + a tonemapper:

- Mertens needs **no camera response function calibration** (which would need
  its own per-device calibration step we cannot ship).
- It outputs a **display-ready LDR** image directly, so the rest of the pipeline
  is unchanged.
- It is exactly what phone HDR modes do; results look "normal", not tonemapped.
- It is contrast/saturation/well-exposedness weighted, so a blown window and a
  dark corner both survive.

A linear-HDR path (Debevec → EXR) stays behind a flag for future radiometric
work, but is not on the critical path.

### 6.3 Progress via shared memory, not FFI callbacks

The stitch runs on a worker isolate. Calling back into Dart from a C++ thread
requires `NativeCallable.listener` bound to that isolate, which is fragile
across the isolate's lifecycle. Instead the C ABI takes a
`Pointer<Int32>` triple — `{stage, permille, cancelFlag}` — in shared memory.
C++ writes; the Dart isolate polls at 10 Hz and forwards to the UI; the UI can
set `cancelFlag` and C++ checks it between tiles. Simple, no lifetime hazards,
and cancellation actually works.

### 6.4 JSON at the ABI boundary

`sv_stitch(const char* request_json, char* error_out, int32_t* progress)`.
Passing a JSON string instead of a packed struct means the ABI does not break
every time we add a field (bracket count, distortion coefficients, quality
tier). One versioned `schema_version` field gates compatibility. The cost —
parsing a few KB of JSON once — is irrelevant next to a 40 s stitch.

### 6.5 Output size is a device tier, not a user setting

Multi-band blending memory scales with canvas area (§7). We probe total RAM and
pick:

| Tier | Detected RAM | Output | Strips |
|---|---|---|---|
| `low` | < 3 GB | 4096×2048 | 4 |
| `mid` | 3–6 GB | 6144×3072 | 6 |
| `high` | > 6 GB | 8192×4096 | 8 |

A phone camera at ~50° HFOV over 3024 px gives ~60 px/°, i.e. a theoretical
21600-wide equirect. We are resolution-limited by memory, not optics — so
`high` is genuinely sharper and the tiers are meaningful.

### 6.6 Everything is replayable offline

A `CaptureBundle` is a directory: JPEGs + one `bundle.json` with poses,
intrinsics, plan, timings. `tools/replay` runs the *identical* native pipeline
on desktop against a bundle and prints the metrics table. This means:

- stitcher iteration takes seconds, not a trip to a site;
- every real-world failure becomes a permanent regression test;
- the synthetic harness and the real device share one code path.

This is the single highest-leverage decision in the project and it is why
[Phase 02](PHASE_02_synthetic_rig.md) comes *before* the stitcher.

---

## 7. Memory budget (the binding constraint)

At an 8192×4096 canvas, `MultiBandBlender` with 5 bands holds:

- level-0 accumulator, `CV_16SC3`: 8192·4096·3·2 B = **201 MB**
- pyramid levels 1..5 add ≈ ⅓ → **+67 MB**
- weight maps, `CV_32F`: 8192·4096·4 B = **134 MB**, +⅓ → **+45 MB**
- plus warped frame + mask per input, plus the output `CV_8UC3` 100 MB

≈ **550–650 MB peak**, before the OS, Flutter, and the camera. On a 3 GB
Android tablet this is an OOM kill.

**Solution: padded horizontal strip blending.** Split the equirect canvas into
`N` horizontal strips. Blend each strip independently, but pad it vertically by
`2^bands · 4 = 128 px` on each side and discard the pad afterwards. Because the
coarsest pyramid level is a /32 reduction, 128 px of pad is enough for every
pyramid level inside the kept region to be numerically identical to a full-canvas
blend. Peak memory drops by ≈ `N`, exactly, with **bit-identical output**.

**The 360° wrap seam** needs the same trick horizontally: the equirect's left
and right edges are the same meridian, but the blender treats them as image
borders. So the canvas is built with `wrap_pad = 256 px` of duplicated content
on each side, blended, then cropped. Without this there is a visible vertical
seam at yaw = ±180° — the single most common bug in hand-rolled 360 stitchers.

---

## 8. Failure modes and how each is handled

| Failure | Detection | Response |
|---|---|---|
| User walked instead of pivoting | BA residual spikes; AR translation (P14) | warn + offer restage; graph-cut minimises damage |
| Low-texture wall, no features | matched-inlier count per pair | fall back to the IMU prior for that pair only, flag in report |
| Frame is motion-blurred | Laplacian variance < tier threshold | reject at capture, re-prompt that target |
| Rotation during shutter (rolling shutter skew) | gyro magnitude at shutter | steadiness gate blocks the shutter |
| Auto-exposure drifted | not possible — AE hard-locked | gain compensator absorbs the residual |
| Nadir has the user's feet | always true | nadir is optional; push-pull fill or logo patch |
| Sphere incomplete (user quit early) | coverage validator | emit a valid partial pano + honest coverage number, do not pretend |
| OOM mid-stitch | tier probe + strip count | degrade tier and retry once, report the downgrade |
| Thermal throttling | platform thermal state | pause stitch, resume; never silently produce worse output |

Principle: **never silently degrade.** Every compromise lands in
`StitchReport` and is surfaced to the caller.

---

## 9. Coordinate conventions

Defined once in [01_MATH_AND_CONVENTIONS.md](01_MATH_AND_CONVENTIONS.md) and
referenced by every phase. Mismatched conventions between the planner, tracker,
stitcher, and viewer are the #1 source of mirrored / upside-down / 90°-rotated
panoramas, so that document is normative — Dart and C++ both cite it.

---

## 10. Open questions requiring research

Listed with ready-to-run prompts in
[RESEARCH_QUESTIONS.md](RESEARCH_QUESTIONS.md). The blocking ones are:

- **R1** — how to ship OpenCV with the `stitching` module to both platforms at
  acceptable binary size. This gates Phase 00 and therefore everything.
- **R2** — real-world availability of `LENS_INTRINSIC_CALIBRATION` /
  `LENS_DISTORTION` on Android tablets, and of intrinsics on iPad.
- **R3** — bracketed-burst support and latency on the actual target devices.

Phases 01 and 02 are independent of all three and can start immediately.
