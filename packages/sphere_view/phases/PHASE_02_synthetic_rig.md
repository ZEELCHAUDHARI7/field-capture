# Phase 02 — Synthetic harness, offline replay, metrics

**Goal:** be able to evaluate a stitcher change in **seconds, on a laptop**, with
a number, against ground truth — before the stitcher exists.

**Duration:** 4–5 days. **Depends on:** Phase 01. **Blocks:** 03, 04, 05.

---

## Why this comes before the stitcher

You cannot tune a panorama stitcher by walking to a construction site. Each
real-world iteration is 30+ minutes and gives you an opinion ("looks a bit
ghosty") instead of a measurement. With a synthetic harness each iteration is
~10 seconds and gives you SSIM, loop closure, and reprojection RMS.

There is a second, larger payoff: because the harness **starts from a known
ground-truth equirectangular image**, we can compare the stitched output to the
exact image it should have reproduced. That is the only way to satisfy criterion
**S6**, and it is impossible with real captures.

Third payoff: every real-world failure later becomes a permanent regression
test, because a `CaptureBundle` is just a directory (Phase 01 §3.4).

---

## 1. `tools/synth` — the forward renderer

Takes a ground-truth equirect and produces a `CaptureBundle` that is
indistinguishable in structure from one a real device produces.

```
dart run tools/synth --input ground_truth_8k.jpg \
                     --out /tmp/bundles/case_nominal \
                     --profile nominal
```

### Pipeline per synthetic frame

For each planned target (using the real `plan_builder` from Phase 08 — reuse,
do not reimplement):

1. **Sample** the ground-truth equirect through the inverse pinhole projection
   for rotation `R_true` and intrinsics `K_true`, with bicubic interpolation.
   This is the exact inverse of the mapping in §3 of
   [01_MATH_AND_CONVENTIONS.md](01_MATH_AND_CONVENTIONS.md) — so a bug here and a
   matching bug in the stitcher could cancel out. Guard against that with the
   independent check in §4.
2. **Apply lens distortion** with `k_true` (forward Brown–Conrady).
3. **Apply vignetting** — `cos⁴(θ)` falloff, plus a configurable extra term.
4. **Apply per-frame exposure gain** to simulate imperfect AE lock.
5. **Simulate the 3-exposure bracket** — render at −2 / 0 / +2 EV against a
   synthetic camera response, clipping highlights to 255 and crushing shadows
   into noise, so Mertens fusion has something real to recover.
6. **Add sensor noise** — Poisson shot noise scaled by exposure + Gaussian read
   noise.
7. **Add motion blur** — directional, from a simulated angular velocity.
8. **Simulate rolling shutter** — per-row rotation offset proportional to row
   index × readout time × angular velocity.
9. **Perturb the recorded pose** — write `R_true · δR` into the bundle, where
   `δR` is the simulated IMU error (bias drift + noise), so the stitcher receives
   a realistically *wrong* prior, exactly as on-device.
10. **Perturb the recorded intrinsics** — write `K_true · (1+ε)` so the stitcher
    must refine the focal, as it will in reality.
11. **Simulate parallax** (see §3) for the profiles that need it.

Ground truth (`R_true`, `K_true`, `k_true`) goes into a **separate**
`ground_truth.json`, never into `bundle.json`. The stitcher must never be able
to read it.

### Profiles

| Profile | Purpose |
|---|---|
| `pristine` | zero noise, exact poses, exact intrinsics. **Output must be near-pixel-perfect.** If this fails, the geometry or conventions are wrong — nothing else matters |
| `nominal` | realistic tablet: IMU 2° RMS, focal 3% off, mild distortion/vignette, small exposure drift, no parallax |
| `harsh_imu` | IMU 6° RMS + 1.5°/min drift — proves BA recovers from a bad prior |
| `low_texture` | ground truth = bare drywall / concrete slab. Proves graceful degradation, not just success on textured scenes |
| `hdr_interior` | dark interior with blown windows, 14 EV range. Validates the whole Phase 05 bracket path |
| `parallax_1m` | nearest surface at 1 m, 10 cm lens offset. This is **expected to be imperfect** — it pins down *how* imperfect, and proves graph-cut beats feathering |
| `motion_blur` | tests the sharpness gate, not the stitcher |
| `sparse_plan` | 15% overlap (today's bad plan). Must fail loudly, not silently produce mush |
| `partial` | user quit after 60% of targets. Must emit a valid partial pano with an honest coverage number |

Every profile is a **fixture directory** committed to the repo (small ground
truths, ~2048×1024, to keep the repo sane; the 8K ones live outside git and are
downloaded by a script).

---

## 2. `tools/replay` — the offline runner

```
dart run tools/replay --bundle /tmp/bundles/case_nominal \
                      --tier high \
                      --compare ground_truth_8k.jpg \
                      --report json
```

Runs the **exact same native library** the device runs — a desktop build of
`src/sphere_stitch`. Same code path, or the harness is measuring the wrong
thing.

Output:

```
stage timings          fuse 3.1s  features 5.2s  match 2.8s  BA 1.4s
                       warp 4.0s  gain 0.6s  seam 6.1s  blend 9.9s  encode 1.2s
S1  rms reproj         0.61 px          target < 1.0    PASS
S2  loop closure       0.11 deg         target < 0.25   PASS
S3  seam score         1.4x noise       target < 2.0x   PASS
S4  max gain ratio     1.018            target < 1.03   PASS
S5  coverage           1.000 / 0.807    target 1.0/0.70 PASS
S6  ssim / psnr        0.981 / 34.2 dB  target 0.97/32  PASS
    residual tilt      0.08 deg         target < 0.2    PASS
    peak rss           612 MB           target < 700    PASS
```

Also emits a **diff image**: `|stitched − ground_truth|` amplified 4×, with the
seam paths overlaid. One glance tells you whether errors are at the seams
(registration) or spread over the frame (intrinsics/distortion).

---

## 3. Simulating parallax honestly

For the `parallax_*` profiles, a single equirect is not enough — parallax needs
depth. Two options; implement **(a)**, and treat (b) as optional:

**(a) Layered depth panorama.** Ground truth is an equirect plus a coarse depth
equirect (hand-painted or from any depth-estimation model, offline — accuracy is
not critical, only plausibility). Render each frame from a camera displaced by
the lens-offset vector, reprojecting through depth. Disoccluded pixels get
inpainted from the background layer.

**(b) A tiny textured 3D room** rendered with any offline renderer. More faithful,
more work.

The point of these profiles is **not** to pass S6. It is to answer: given
realistic parallax, does graph-cut + multi-band produce a result a manager can
read, and is it measurably better than feathering? Record the numbers and accept
them as the physical floor (see §3 of [00_ARCHITECTURE.md](00_ARCHITECTURE.md)).

---

## 4. The metrics — and how not to fool yourself

### S3, seam score

Seams are *localised gradient discontinuities*. For each seam path pixel,
compare the gradient magnitude across the seam to the median gradient magnitude
in a 32 px neighbourhood. `seam_score = 95th percentile of that ratio`. A
perfect blend gives ≈1.0. Report the worst 10 locations with coordinates so they
can be inspected.

### S6, SSIM / PSNR

Compute over the region covered by ≥1 frame only, excluding pole-filled areas
(otherwise the fill's smooth blur inflates SSIM). Report the excluded fraction.

### The independent convention check

The forward renderer and the stitcher share the mapping formulas, so a sign error
in both would cancel and every test would pass on garbage. Guard with a test
that does **not** use either code path:

`test/synthetic_sanity_test.dart` — place a distinctive marker (a red square) at
a known yaw/pitch in the ground truth, run the full synth → stitch → compare
loop, and assert the marker lands within 2 px of
`(W·(½ − yaw/2π), H·(½ − pitch/π))` computed **inline in the test, by hand**.
Do this for eight directions including both poles and both sides of the ±180°
wrap seam.

This single test is what stops the mirrored-panorama class of bug.

---

## 5. CI

```
tools/ci/quality_gate.sh
```

Runs every profile, writes a markdown table, fails the build if any profile
regresses more than a tolerance against `phases/baselines/<profile>.json`.
Baselines are committed and updated deliberately, with the commit message
explaining why the number moved.

This is what makes "perfect" hold over time rather than being true once.

---

## Exit criteria

- [ ] All nine profiles generate bundles that `CaptureBundle.load` accepts
- [ ] `tools/replay` runs the desktop build of the native library
- [ ] All eight metrics compute and print
- [ ] `synthetic_sanity_test.dart` passes for all eight directions
- [ ] `quality_gate.sh` runs green with a stub stitcher whose baselines are
      recorded as `FAIL` — proving the harness detects badness before the real
      stitcher exists
- [ ] Full suite completes in **< 5 minutes** on a laptop

---

## Note on sequencing

The stub-stitcher requirement is deliberate. Wire the harness against a
deliberately-bad stitcher (e.g. the current Dart one, ported to the replay tool)
and confirm it reports `FAIL` on `pristine`. A harness that has never printed
FAIL has not been tested.
