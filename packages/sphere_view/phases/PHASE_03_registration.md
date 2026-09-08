# Phase 03 — Native registration: features, matching, bundle adjustment

**Goal:** given a `CaptureBundle`, recover the true rotation of every frame and
the true shared focal length, to sub-pixel accuracy.

**Duration:** 5–7 days. **Depends on:** 00 (Spike A), 01, 02.

This is the phase that decides whether the panorama can ever be seam-free.
Compositing (Phase 04) can only hide what registration leaves behind.

---

## 1. The C ABI

One entry point, JSON in, file out (architecture §6.4):

```c
// sphere_stitch.h
#define SV_SCHEMA_VERSION 1

typedef struct {
    int32_t stage;       // StitchStage ordinal, written by C++
    int32_t permille;    // 0..1000 within the stage
    int32_t cancel;      // written by Dart, polled by C++
} SvProgress;

// Returns 0 on success, negative on error; message written to error_buf.
int32_t sv_stitch(const char* request_json,
                  SvProgress* progress,
                  char* error_buf, int32_t error_buf_len,
                  char** report_json_out);   // caller frees via sv_free

void sv_free(char* p);
const char* sv_version(void);
```

`request_json` mirrors `bundle.json` plus the tier and output path.
`report_json_out` deserialises straight into `StitchReport`.

`cancel` is polled between frames and between blend strips — cancellation that
only takes effect at stage boundaries is not cancellation.

---

## 2. Stage 6 — undistort

For each fused frame, apply the measured distortion model:

- `BrownConradyDistortion` → `cv::initUndistortRectifyMap` once (all frames
  share intrinsics) + `cv::remap` per frame.
- `LookupTableDistortion` (iOS) → build the map from the radial LUT once, then
  `remap`.
- `null` → skip, and add a `warnings` entry. Modern phone ISPs already correct
  most geometric distortion, so this is a legitimate path, not a failure.

**Critical:** undistortion changes the effective intrinsics. Use
`cv::getOptimalNewCameraMatrix(K, D, size, alpha=0)` and carry the **new** `K`
forward. Forgetting this is a subtle ~1% focal error that BA will partly absorb,
masking the bug.

### Intrinsics quality is a gradient — design for it

**R2 changed the assumption here.** There is no single reliable intrinsics source
across the fleet. Expect three tiers of input quality:

| Tier | `IntrinsicsSource` | Likely devices |
|---|---|---|
| best | `platformCalibration` + distortion | Android with non-null `LENS_DISTORTION`; possibly no iPad at all |
| middle | `derivedFromPhysics`, no distortion | most Android tablets |
| worst | FOV-derived `fx`, `distortion: null`, `p1=p2=0` | base iPad / Air / mini — likely most of our iOS fleet |

So this stage must **tolerate the whole range**, not assume one path:

- `distortion == null` is the *expected* case on iOS, not an error. Skip stage 6
  entirely (do not run a no-op remap — it wastes a full pass per frame) and let BA
  absorb what it can.
- iOS distortion, when present, is **radial-only** — `p1 = p2 = 0` forced, because
  Apple's lookup table gives no basis for tangential terms.
- Android distortion is safe to apply directly: **R2 confirmed** it is genuinely
  Brown–Conrady, and the mapping is a pure reorder
  `{κ1, κ2, κ4, κ5, κ3}` → `(k1, k2, p1, p2, k3)`, no value transform. The
  previously-flagged "wrong order degrades frames" risk is **closed**.
- Carry `IntrinsicsSource` into `StitchReport`, and add a warning when the worst
  tier is in use. It is how a soft panorama gets attributed to a weak focal estimate
  rather than to the stitcher.

Consequence for testing: the `nominal` synthetic profile should be run at **both**
the best and worst intrinsics tiers, and the S1/S3 gap between them recorded. That
number tells us how much the iOS fleet actually loses — which is worth knowing
before anyone tries to explain it away.

---

## 3. Stage 7 — features

```cpp
auto detector = cv::SIFT::create(/*nfeatures=*/0, /*nOctaveLayers=*/3,
                                 /*contrastThreshold=*/0.03,   // lowered: bare concrete
                                 /*edgeThreshold=*/10,
                                 /*sigma=*/1.6);
cv::detail::computeImageFeatures(detector, images_scaled, features);
```

**SIFT, not ORB.** Construction interiors are the adversarial case for feature
detection: bare drywall, poured slab, uniform ceiling tile, repeated formwork.
ORB's FAST corners collapse on low-contrast texture and its binary descriptors
alias badly on repetitive structure. SIFT is slower but it is the difference
between a stitch and a failure on the frames we actually get. It is
patent-free and in OpenCV main since 4.4.

`contrastThreshold` is lowered from the 0.04 default specifically for low-texture
surfaces. Tune it against the `low_texture` profile from Phase 02.

**Registration scale.** Work at ~0.6 MP:
`scale = min(1.0, sqrt(0.6e6 / (w·h)))`. Record it — every pixel-unit metric in
`StitchReport` is at this scale and must be labelled as such.

---

## 4. Stage 8 — IMU-gated pairwise matching

This is the first place we beat stock OpenCV.

Stock `Stitcher` matches all `n(n−1)/2` pairs. For 29 frames that is 406 pairs,
most of which point in opposite directions and can only produce false matches on
repetitive structure. Instead:

```cpp
// A pair is worth matching only if their frusta plausibly overlap.
bool should_match(const Pose& a, const Pose& b, double hfov, double vfov) {
    double ang = angle_between(a.forward(), b.forward());
    return ang < 0.85 * std::hypot(hfov, vfov) + IMU_SLACK;   // IMU_SLACK ≈ 10°
}
```

`IMU_SLACK` must be generous enough to survive the `harsh_imu` profile (6° RMS).
For the worked plan in §8 of the math doc this cuts 406 pairs to ~70 — roughly
6× less matching time, **and** it structurally eliminates the
distant-false-match failure mode.

```cpp
cv::detail::BestOf2NearestMatcher matcher(/*try_use_gpu=*/false,
                                          /*match_conf=*/0.3f);
for (auto& [i, j] : candidate_pairs) matcher(features[i], features[j], pairwise[i*n+j]);
```

`match_conf` 0.3 (below the 0.65 default) because we already trust geometry from
the IMU gate — we want recall here, and RANSAC plus BA rejects the rest.

### Connectivity check

Build the match graph, weight = inlier count. Then:

- **Any frame with < `MIN_INLIERS` (≈ 25) total** → it cannot be registered
  photometrically. Do **not** drop it: fall back to its IMU prior, mark it
  `imu_only` in the report, and exclude it from BA (fixed, not free). It still
  contributes pixels; it is just less accurate. Dropping frames leaves holes,
  which is worse.
- **Graph disconnected** → run BA independently per component, then rigidly align
  each component using its IMU poses. Report it as a warning.
- Never call `leaveBiggestComponent` — it silently throws frames away, which
  violates the never-silently-degrade principle.

---

## 5. Stage 9 — bundle adjustment

### Seeding

```cpp
std::vector<cv::detail::CameraParams> cams(n);
for (int i = 0; i < n; ++i) {
    cams[i].focal  = init_focal_px;        // from measured intrinsics (§4 math doc)
    cams[i].aspect = fy / fx;
    cams[i].ppx    = cx;  cams[i].ppy = cy;
    cams[i].R      = imu_rotation_opencv(poses[i]);   // §2 math doc: M·R·N
    cams[i].t      = cv::Mat::zeros(3, 1, CV_32F);    // pure rotation
}
```

`HomographyBasedEstimator` is **not** used. It builds rotations by chaining
pairwise homographies, so one bad pair corrupts everything downstream of it, and
it needs a connected chain in capture order. We already have a globally
consistent rotation estimate from the IMU that is good to a few degrees — a far
better starting point.

### Adjust

```cpp
cv::detail::BundleAdjusterRay adjuster;
adjuster.setConfThresh(1.0);
cv::Mat_<uchar> mask = cv::Mat::zeros(3, 3, CV_8U);
mask(0,0) = 1;                 // refine fx  (shared across frames)
// mask(1,1) = 1;              // aspect: enable only if S1 says it helps
// principal point: leave FIXED — weakly observable, absorbs real error
if (!adjuster(features, pairwise, cams)) { /* fall back to IMU-only, warn */ }
```

**`BundleAdjusterRay`, not `BundleAdjusterReproj`.** Ray minimises the angle
between corresponding rays, which is the natural error metric for a
rotation-only panorama and is better conditioned near the poles — where
`Reproj`'s image-plane error blows up.

Refine focal only. The principal point is weakly observable from a rotational
panorama and, if freed, absorbs distortion and pose error into a plausible-looking
but wrong `K` — which then poisons the warp. Validate this decision against the
`pristine` and `nominal` profiles rather than taking it on faith.

### Levelling (replaces `waveCorrect`)

Implement §7 of [01_MATH_AND_CONVENTIONS.md](01_MATH_AND_CONVENTIONS.md):
Kabsch-align the BA-recovered up axes to the measured gravity vectors, apply the
resulting single global rotation to every camera. `waveCorrect` is never called.

Report `residualTiltDegrees`; must be < 0.2° on `pristine` and `nominal`.

---

## 6. Metrics this phase must produce

| Field | How |
|---|---|
| `rmsReprojectionErrorPx` | RMS ray-angle residual over all inliers, converted to px at registration scale |
| `loopClosureErrorDegrees` | compose the relative rotations around the equatorial ring; the deviation of the product from identity |
| `refinedFocalPx` + `refinedIntrinsics` | from BA, rescaled to full resolution |
| `residualTiltDegrees` | angle between mean BA up and mean IMU up, after levelling |
| `droppedPositionIndices` + `warnings` | `imu_only` frames, disconnected components, BA failure |

---

## 7. Tests

- `pristine` → S1 < 0.1 px, S2 < 0.02°, refined focal within 0.1% of truth
- `nominal` → S1 < 1.0 px, S2 < 0.25°, refined focal within 0.5% of truth
- `harsh_imu` → same targets as `nominal`. **This is the proof that the IMU is a
  prior and not a measurement.** If it fails, `IMU_SLACK` or the seeding is wrong
- `low_texture` → completes; `imu_only` count reported and non-fatal
- `sparse_plan` → fails loudly with an actionable warning, does not crash
- unit test: `imu_rotation_opencv` against the hand-derived values in §2 of the
  math doc
- unit test: `should_match` is symmetric, and true for a frame against itself

---

## 8. Pitfalls

1. **`cams[i].R` must be `CV_32F`.** Passing `CV_64F` gives silent garbage.
2. **`features[i].img_idx`** must be set consistently; several `detail::`
   functions rely on it.
3. **Registration-scale focal.** `cams[i].focal` is in *registration-scale*
   pixels. Scale by `1/scale` before warping at full resolution. This
   off-by-a-scale-factor is the most common bug in `detail::`-based code.
4. **`pairwise` is a flat `n·n` vector**, indexed `i*n+j`, and
   `BundleAdjusterRay` expects unmatched entries to be default-constructed with
   `confidence = 0` — not absent.
5. **`setConfThresh`** interacts with which frames BA considers connected; a high
   value silently excludes frames. Keep it at 1.0 and handle exclusion ourselves.

---

## Exit criteria

- [ ] `sv_stitch` returns registration metrics with compositing stubbed out
- [ ] All six test cases in §7 pass via `tools/replay`
- [ ] `harsh_imu` reaches the same accuracy as `nominal`
- [ ] Registration completes in **< 15 s** for 29 frames on a tablet
- [ ] Cancellation via `SvProgress.cancel` takes effect within 500 ms
