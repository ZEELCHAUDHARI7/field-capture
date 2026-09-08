# Phase 05 — HDR exposure fusion

**Goal:** collapse each position's 3-shot bracket into one well-exposed LDR
frame that holds detail in both a blown window and a dark corner.

**Duration:** 3–4 days. **Depends on:** 00 (Spike C), 02, 03.

This is stage 5 — it runs **before** registration, so everything downstream sees
a normal single frame per position and needs no changes.

---

## 1. Why this phase exists

A construction interior is the worst case for a phone camera. A room lit by one
window opening spans 12–16 EV; a phone sensor captures ~10 EV in a single JPEG.
With one locked exposure you must choose:

- expose for the interior → the window is a white rectangle, and you cannot see
  the façade, the glazing, or whether the frame is installed;
- expose for the window → the interior is black and you cannot see the defect
  you came to document.

Both make the panorama useless for the actual job. A 3-shot bracket fused
properly gives a single image where both are readable.

---

## 2. Algorithm: Mertens exposure fusion

```cpp
auto merge = cv::createMergeMertens(/*contrast_weight=*/1.0f,
                                    /*saturation_weight=*/1.0f,
                                    /*exposure_weight=*/0.0f);
cv::Mat fused_f32;                       // CV_32FC3, values ~[0,1]
merge->process(aligned_shots, fused_f32);
fused_f32.convertTo(fused_u8, CV_8U, 255.0);
```

**Mertens, not Debevec + tonemap.** Three reasons, in order of importance:

1. **No camera response function needed.** Debevec recovers a true radiance map,
   which requires knowing the sensor's response curve. Calibrating that per device
   model is a whole shipping problem we would own forever. Mertens works directly
   on the LDR pixels.
2. **Outputs display-ready LDR.** No tonemapper choice, no tonemapper parameters,
   no "why does it look like an HDR photo from 2009". The rest of the pipeline is
   untouched.
3. **It is what phone HDR modes do.** Results look normal to the user, which for a
   documentation tool is the whole point.

Mertens weights each pixel of each exposure by contrast × saturation ×
well-exposedness and blends the stack through a Laplacian pyramid — so it is a
multi-band blend in the exposure dimension, conceptually the same tool as Phase 04
§5.

**`exposure_weight = 0.0` is deliberate.** The default well-exposedness term
(Gaussian around 0.5) pulls everything toward mid-grey and flattens the image. We
already know the EV of each shot, so we do not need the algorithm to guess which
pixels were well exposed. Validate against the `hdr_interior` profile — if
flattening is visible, raise it to ~0.2, but start at 0 and measure.

A linear-HDR path (`createMergeDebevec` → EXR) stays behind
`--emit-linear-hdr` for future radiometric work. Not on the critical path.

---

## 3. Alignment: the hard part

The three shots come from a hardware burst in < 600 ms (Spike C), but the tablet
is handheld and still moves. Fusing misaligned frames produces **coloured
fringing on every edge** — worse than not bracketing at all.

### 3.1 Per-position alignment

The three shots share a viewpoint and differ only by a small rotation, so a
**2-DOF translation** model is sufficient at frame scale (a 0.3° rotation over
600 ms is a few pixels of shift, and the residual rotation is well below the
fusion pyramid's sensitivity).

```cpp
// Estimate on gradient magnitude, NOT intensity: the frames differ by 4 EV,
// so intensity-based ECC would try to explain the exposure difference as motion.
cv::Mat ref_grad = gradient_magnitude(shots[EV0]);
for (int k : {EV_MINUS, EV_PLUS}) {
    cv::Mat warp = cv::Mat::eye(2, 3, CV_32F);
    cv::findTransformECC(ref_grad, gradient_magnitude(shots[k]), warp,
                         cv::MOTION_TRANSLATION,
                         cv::TermCriteria(cv::TermCriteria::COUNT+cv::TermCriteria::EPS,
                                          50, 1e-4),
                         cv::noArray(), /*gaussFiltSize=*/5);
    cv::warpAffine(shots[k], aligned[k], warp, size,
                   cv::INTER_LINEAR | cv::WARP_INVERSE_MAP);
}
```

Aligning on **gradient magnitude** rather than intensity is the key detail.
Gradient structure is roughly exposure-invariant where the pixels are not clipped;
raw intensity is not, and ECC on intensity will happily "explain" a 4 EV
difference as a translation and return nonsense.

Alternative worth benchmarking: `cv::createAlignMTB()` (median-threshold
bitmaps), which is designed exactly for exposure-invariant alignment and is
faster. It only does integer-pixel translation. Try it first; fall back to ECC if
sub-pixel accuracy proves necessary. Decide with the `hdr_interior` profile.

### 3.2 Reject, don't fuse badly

If the estimated shift exceeds `MAX_BURST_SHIFT_PX` (≈ 1.5% of frame width) or
ECC fails to converge:

- **Do not fuse.** Fall back to the 0 EV shot alone for that position.
- Record a `warnings` entry naming the position.
- The panorama is then locally lower dynamic range but geometrically correct —
  much better than fringing.

### 3.3 Ghost suppression

Anything that *moved* between the three shots (a worker walking, a crane, a
tarpaulin) cannot be fused and will ghost. After alignment, compute per-pixel
variance across the exposure-normalised stack; where variance exceeds a threshold,
fall back to the 0 EV shot for that pixel with a feathered mask.

On an active construction site people move constantly, so this is not an edge
case — it is the normal case. Budget real time for it.

---

## 4. Clipping-aware normalisation

Before fusion, exposure-normalise the three shots to a common scale using their
**actual** exposure parameters (`exposureTimeNs` × ISO gain from
`ExposureShot`), not the requested EV bias. Achieved EV can differ from requested
(Spike C measures by how much), and using the request introduces a systematic
brightness error.

Exclude clipped pixels from the normalisation fit: a pixel at 255 in the +2 EV
shot carries no information, and including it biases the estimate.

---

## 5. Performance and memory

For 29 positions × 3 shots at 12 MP:

- decode: 87 JPEG decodes. **Parallelise across cores** — this is embarrassingly
  parallel and otherwise dominates. Use `cv::parallel_for_` over positions.
- per position peak: 3 × 12 MP × 3 ch × 4 B (float) ≈ 430 MB if done naively.
  **Process one position at a time**, write the fused frame to disk, free
  everything. Peak stays ~450 MB for one position and downstream stages
  memory-map the fused files.
- estimated: ~0.8–1.5 s per position → **25–45 s** for 29 positions. This is the
  single most expensive stage in the pipeline.

Mitigation: fuse at full resolution but consider downscaling to the tier's needs
first. At `mid` tier (6144 wide) a 12 MP frame is already more resolution than
the output can use — downscaling *before* fusion cuts this stage by ~2.5× at no
quality cost. Measure and set per tier.

---

## 6. Graceful degradation — handle **any** stack size, not just 1 or 3

`shots.length` must be treated as genuinely variable, and the **R3 finding makes
this more likely than originally assumed**:

- iOS `maxBracketedCapturePhotoCount` is explicitly *not* a fixed number — it varies
  with session preset and active format, and Apple publishes no per-device table. A
  given iPad may grant only 2.
- Android devices without `MANUAL_SENSOR` fall back to single-exposure.
- If Spike C's measured burst time misses the 600 ms budget, the whole fleet drops
  to `ExposureStrategy.locked()`.

Mertens fuses any stack size, so this costs nothing structurally:

- `length == 1` → skip §3.1–3.3 entirely, pass through **byte-identical**
- `length == 2` → fuse normally; recovers most shadow detail, less highlight headroom
- `length >= 3` → the full path

This is why `CapturedPosition.shots` was modelled as a list in Phase 01, and it is
why the single-shot no-op is an exit criterion rather than a nicety.

Also confirmed by R3, and worth stating so nobody proposes it as a shortcut:
**platform-native multi-frame HDR is not a substitute.** CameraX Extensions
`ExtensionMode.HDR` and iOS's built-in HDR both return a single already-fused,
tone-mapped frame with no per-frame control — which reintroduces exactly the
photometric inconsistency between panorama positions that Phase 06's locked
exposure exists to prevent. Manual bracketing is the only viable primary method.

---

## 7. Tests

| Case | Assertion |
|---|---|
| `hdr_interior` | window detail recoverable (measure local contrast in the window region) **and** shadow detail recoverable; neither clipped |
| `hdr_interior`, single-exposure control | fused result strictly better on both metrics — proves the phase earns its cost |
| synthetic burst with known 8 px shift | alignment recovers it to < 1 px |
| synthetic burst with 40 px shift | rejected, falls back to 0 EV, warning recorded |
| synthetic burst with a moving object | ghost suppression engages; no doubled edges |
| `shots.length == 1` | passes through unchanged, byte-identical to input |
| ECC vs AlignMTB | benchmark both; record the choice and why |
| exposure normalisation | uses actual not requested EV; clipped pixels excluded |

---

## 8. Pitfalls

1. **`MergeMertens::process` outputs `CV_32FC3` in ~[0,1]**, but can exceed 1.0.
   Clamp before `convertTo`, or highlights wrap around to dark.
2. **`findTransformECC` needs `CV_32F` single-channel input** and fails on
   low-texture frames — always wrap in try/catch and have the fallback ready.
3. **`WARP_INVERSE_MAP`** — getting this flag backwards doubles the misalignment
   instead of removing it, and it looks *almost* right, which is worse.
4. **JPEG decode is not thread-safe in all builds.** Verify before parallelising.
5. **Do not fuse in sRGB and assume linearity.** Exposure normalisation is a
   linear operation, so linearise (approx. `x^2.2`) first, fuse, then re-encode.
   Mertens is more forgiving here than Debevec, but the normalisation in §4 is
   not. Measure the difference; if it is below noise, document skipping it.

---

## Exit criteria

- [x] All eight tests in §7 pass — plus a ninth for §5's budget. 128 checks in
      `sphere_stitch_test`, run by `tools/build_native.sh`.
- [x] `hdr_interior` measurably beats its single-exposure control — on **both**
      criteria and on every geometric metric:

      | | fused | single-exposure control |
      |---|---|---|
      | window detail (fraction below the 8-bit rail) | **99.4%** | 24.9% |
      | shadow detail (local contrast vs truth) | **77%**, 0.1% black | 65%, 5.4% black |
      | S1 | 7.4 px | 11.6 px |
      | S6 SSIM / PSNR | 0.513 / 11.3 dB | 0.374 / 8.4 dB |

- [x] Stage completes in **< 45 s** for 29 positions — 22–25 s projected from a
      measured 757–865 ms for one 12 MP position through the whole stage
      (decode, align, fuse, write) at `mid` tier. **On a desktop core**; like
      Spike C's burst wall clock, the number that decides the design still has to
      come from a device.
- [~] Peak RSS for this stage **~500 MB** against a 500 MB ceiling — met only
      marginally. See the known gap below.
- [x] Single-shot path is a verified no-op — asserted byte-identical in
      `testSingleShotIsAByteIdenticalNoOp`, and end to end by `pristine`
      (`ExposureStrategy.locked()`), which scores exactly what it did before this
      stage existed: S1 0.17 px, SSIM 0.965. The frame downstream reads *is* the
      file the camera wrote, not a re-encode of it.

### What the implementation found that this document assumed otherwise

Five things below were measured against what §2–§5 predicted and came out
differently. Each is argued at its definition in `hdr_fuse.h` / `hdr_fuse.cpp`
with the numbers.

1. **`exposure_weight` is 0.35, not 0.** §2 is right that the well-exposedness
   term pulls toward mid-grey, and says to start at 0 and measure. Measured, that
   term is *also* how the deep shadows become legible: at 0 the shadow region
   scores 49% of the truth's contrast — worse than the control this stage exists
   to beat — and S1 collapses to 31 px, because read noise has excellent local
   contrast and nothing else stops the darkest exposure winning the vote.
2. **ECC cannot find the shift on its own, and `AlignMTB` is not the fallback.**
   §3.1 offers ECC or MTB; neither works alone. ECC's basin is a couple of pixels
   while §3.2's limit is 45 px at 12 MP, and MTB thresholds each frame at its own
   median, which is exposure-invariant only on uniformly-lit scenes — the
   opposite of an interior with a window. The shipping estimator is a bounded
   cross-correlation search plus ECC for the fraction.
3. **Alignment runs on log-luminance, not gradient magnitude.** §3.1's reasoning
   about raw intensity is right and understates what is available: on the log
   image an exposure change is a constant offset, which both estimators are
   *exactly* invariant to.
4. **§3.2 rejects per exposure, not per bracket.** An exposure that cannot be
   aligned is one exposure's worth of dynamic range, not the bracket's.
5. **§4's measured ratio corroborates the metadata; it never overrules it.** The
   sensor's own report of what it did beats an inference from pixels that also
   carry noise and quantisation.

Two more, about the fixtures rather than the code:

- **`hdr_interior` could not test what it existed to test.** The rig had no
  metering pre-sweep, so a 0 EV exposure was metered for the interior and the sky
  sat 7 stops above it — clipped in *all three* frames, 18.4% of the window
  frames still blown at −3 EV. `SynthProfile.meteredEvBias` now models pipeline
  stage 3, and the scene is 12 EV metered at −3, which puts both ends inside the
  bracket's reach with ~3.6 EV of centring slack.
- **§8.5's linearity question is answered.** Normalisation, the ghost test and
  the fallback all work in linear radiance through a 256-entry table; Mertens
  keeps the display-referred pixels it expects.

### Known gap

**Peak RSS is ~500 MB against a 500 MB ceiling** — it meets the target only
marginally, and on a desktop build. Nearly all of it is inside
`cv::MergeMertens`, which converts the stack to `CV_32FC3` and builds a
full-depth Laplacian pyramid over it. Phase 04's strip trick does not transfer:
that blender is capped at 5 bands, so 128 px of pad makes a strip numerically
identical to a full-canvas blend, while Mertens uses `log2(min(rows, cols))`
levels — about 10 at capture resolution — whose coarsest support is the entire
frame. Cutting it further means either an in-house fusion or accepting frames
below the output canvas's own resolution, and neither is worth doing before a
device says whether it is needed.
