# Phase 04 — Native compositing: warp, gain, seam, blend, poles

**Goal:** turn registered frames into one seamless equirectangular image, within
the memory budget of a 3 GB tablet.

**Duration:** 6–8 days. **Depends on:** 02, 03.

Registration decided whether it *can* be seamless. This phase decides whether
it *looks* seamless — and it is where the two hard engineering problems live:
the **±180° wrap seam** and the **memory ceiling**.

---

## 1. Stage 10 — spherical warp onto a wrap-padded canvas

### Canvas geometry

```
W = tier width (4096 / 6144 / 8192)      H = W/2
warper scale = W / (2π)                  (§3 of the math doc)
wrap_pad = 256 px                        (see §2)
canvas width = W + 2·wrap_pad
```

```cpp
cv::Ptr<cv::detail::RotationWarper> warper =
    cv::makePtr<cv::detail::SphericalWarper>(static_cast<float>(W / (2.0 * CV_PI)));

for (int i = 0; i < n; ++i) {
    cv::Mat K; cams[i].K().convertTo(K, CV_32F);   // K() applies focal+aspect+pp
    warper->buildMaps(images[i].size(), K, cams[i].R, xmap, ymap);
    cv::remap(images[i], warped[i], xmap, ymap, cv::INTER_LINEAR,
              cv::BORDER_CONSTANT);
    warper->buildMaps(images[i].size(), K, cams[i].R, xmap, ymap);  // for the mask
    cv::remap(full_mask, warped_mask[i], xmap, ymap, cv::INTER_NEAREST,
              cv::BORDER_CONSTANT);
    corners[i] = warper->warpRoi(images[i].size(), K, cams[i].R).tl();
}
```

**Scale the focal back to full resolution first.** `cams[i].focal` came out of BA
in registration-scale pixels (Phase 03 §8.3). Multiply by `1/registration_scale`
before building `K`, and warp from the **full-resolution** fused frames, not the
downscaled ones used for features.

### Feather the frame borders

Undistortion and the pinhole model both misbehave at the extreme frame edge, and
vignetting is worst there. Erode each `warped_mask` by ~1.5% of the frame's
smaller dimension before seam finding, so seams are never placed on the outermost
ring of pixels. Cheap, and it removes a whole class of edge artefact.

---

## 2. The ±180° wrap seam

**The problem.** The equirect's left and right columns are the *same meridian* in
the world, but every OpenCV `detail::` component treats them as image borders.
The graph-cut finds seams that terminate at the border instead of continuing
across it, and the multi-band blender's pyramid uses border extrapolation on both
sides independently. Result: a **hard vertical line at yaw ±180°**. This is the
most common defect in hand-rolled 360 stitchers and it is invisible in a
half-panorama test, so it must be tested deliberately.

**The fix.** Composite onto a canvas that is `wrap_pad` wider on each side, where
the padding is a *duplicate* of the content from the opposite edge:

1. A frame whose warped ROI crosses the wrap boundary is emitted **twice** — once
   at `x` and once at `x ± W` — with the same rotation, so both copies carry
   identical pixels.
2. Gain compensation, seam finding, and blending all run on the padded canvas, so
   they see continuous content across the meridian.
3. Crop `[wrap_pad, wrap_pad + W)` at the end. Because the two copies were
   identical and blended identically, column `wrap_pad` and column
   `wrap_pad + W` agree to within rounding, and the wrap is invisible.

`wrap_pad = 256` comfortably exceeds both the multi-band pyramid support
(`2^5 × 4 = 128`, see §5) and the graph-cut's practical influence radius.

**Test:** the `pristine` profile must show **zero** measurable gradient
discontinuity at `x = 0` when the output is rolled by `W/2`. Rolling is the
trick — it moves the wrap seam to the image centre where the S3 metric can see
it. Without the roll, the metric never inspects the seam.

---

## 3. Stage 11 — exposure compensation

```cpp
auto comp = cv::detail::BlocksGainCompensator(/*bl_width=*/32, /*bl_height=*/32);
comp.feed(corners, warped, warped_masks);
for (int i = 0; i < n; ++i) comp.apply(i, corners[i], warped[i], warped_masks[i]);
```

**Blocks, not `GainCompensator`.** A single gain per frame cannot model
vignetting, which is the dominant residual once AE is locked — it is a smooth
radial falloff, brightest at frame centre. `BlocksGainCompensator` fits a gain
per 32×32 block and interpolates, absorbing vignetting as well as any AE leakage.

AE is hard-locked at capture (Phase 06), so the compensator is correcting
vignetting and lens shading, not exposure drift. That is why 32×32 blocks are
appropriate — the correction field is smooth.

Record `maxGainRatio` for criterion **S4**. A ratio above ~1.15 means AE lock is
not actually holding — that is a Phase 06 bug surfacing here, and the warning
should say so.

---

## 4. Stage 12 — graph-cut seam finding

```cpp
auto finder = cv::makePtr<cv::detail::GraphCutSeamFinder>(
    cv::detail::GraphCutSeamFinderBase::COST_COLOR_GRAD);
finder->find(warped_f32, corners, warped_masks);   // needs CV_32F input
```

**This is the stage that hides parallax** (architecture §3), and the reason the
whole native pipeline is worth building. Feathering *averages* misalignment into
ghosting; graph-cut *routes around* it, cutting through regions where the two
images agree and where the gradient is low, so the eye has nothing to lock onto.

`COST_COLOR_GRAD` over `COST_COLOR`: the gradient term penalises cutting across
strong edges, which is precisely where a misaligned seam would be visible. On the
`parallax_1m` profile the difference between the two costs should be clearly
measurable in S3 — make that comparison an explicit test, since it is the
justification for the whole approach.

### Memory and time

Graph-cut on a full 8192×4096 canvas with 29 overlapping frames is the slowest
stage and can dominate runtime. Mitigation: run seam finding at a **reduced
scale** (`seam_scale = sqrt(0.1e6 / canvas_area)`, the same trick stock OpenCV
uses), then upscale the resulting masks with `INTER_NEAREST` and dilate by 2 px.
Seam paths do not need full resolution — the blender feathers across them anyway.

---

## 5. Stage 13 — multi-band blending in padded strips

### The memory problem

At 8192×4096, `MultiBandBlender` with 5 bands needs roughly (architecture §7):

```
level-0 CV_16SC3 accumulator   201 MB
pyramid levels 1..5            + 67 MB
CV_32F weight maps + pyramid   +179 MB
output CV_8UC3                 +100 MB
                               ≈ 550-650 MB peak
```

Plus Flutter, the OS, and the camera. On a 3 GB tablet this is an OOM kill.

### The solution: padded horizontal strips

Split the canvas into `N` horizontal strips (`N` from the tier table). Blend each
strip alone, but **pad it vertically by `pad = 2^bands · 4 = 128 px`** on each
side, then discard the pad.

Why this is exact and not an approximation: the coarsest pyramid level is a /32
reduction, so a pixel in the kept region depends on at most ~32·(a few) rows of
context. With 128 px of padding, every pyramid level inside the kept region is
numerically identical to what a full-canvas blend would produce. Peak memory
drops by a factor of `N` with **bit-identical output**.

**Assert this.** A test must blend the `pristine` case both ways and require the
outputs to be identical (or within ±1 LSB from float rounding). If they differ,
`pad` is too small — do not just "look at it".

```cpp
for (int s = 0; s < N; ++s) {
    cv::Rect keep(0, s*strip_h, canvas_w, strip_h);
    cv::Rect work = inflate_vertically(keep, pad) & canvas_rect;

    cv::detail::MultiBandBlender blender(/*try_gpu=*/false, /*num_bands=*/5);
    blender.prepare(work);
    for (int i = 0; i < n; ++i) {
        cv::Rect isect = warped_roi[i] & work;
        if (isect.empty()) continue;                 // most frames skip most strips
        blender.feed(sub(warped_s16[i], isect), sub(masks[i], isect), isect.tl());
    }
    cv::Mat out_s, out_mask;
    blender.blend(out_s, out_mask);
    out_s.convertTo(sub(canvas, keep), CV_8U, 1.0, 0.0);   // discard the pad
    progress->permille = 1000 * (s+1) / N;
    if (progress->cancel) return SV_CANCELLED;
}
```

The `isect.empty()` skip matters: with 29 frames and 8 strips, each strip only
touches ~4–6 frames, so per-strip work is far below `n`.

Warped frames are held on disk as intermediate files and memory-mapped per strip,
not all kept in RAM — otherwise the warped frames themselves (29 × ~12 MB) exceed
the budget before blending starts.

---

## 6. Stage 14 — pole filling

Nadir is optional by default (`captureNadir = false`) because it contains the
user's feet, and even when captured the outermost ring may not quite reach a
pole. Uncovered regions must not be black.

Port the **push–pull pyramid fill** from the existing Dart implementation
(`lib/src/stitching/equirectangular_stitcher.dart:370` — the one genuinely good
piece of the old stitcher) to C++:

1. Push: repeatedly downsample the weighted colour sums and weights to 1×1, so
   coverage propagates outward.
2. Pull: from coarsest to finest, fill zero-weight pixels by bilinearly sampling
   the (already-filled) coarser level.
3. Adopt with a tiny weight (`1e-3`) so real photo data always dominates.

Result: a smooth extrapolation of the surrounding colours — reads as
out-of-focus floor rather than a black hole.

Two refinements over the Dart original:

- **Wrap-aware downsampling.** Do the pyramid on the wrap-padded canvas, or the
  fill develops a discontinuity at the meridian.
- **Pole convergence.** Near a pole, equirect rows represent vanishingly small
  world area, so a naive fill produces radial streaks. Weight the horizontal
  downsample by `cos(pitch)`.

Alternative offered via config: `PoleFill.logoPatch(image)` — stamp a circular
badge over the nadir. Standard practice for tripod-based capture and often what a
client actually wants.

Record `coverageFraction` (**S5**) *before* filling. The report must state how
much of the sphere is real photography.

---

## 7. Stage 15 — encode

- `cv::imencode(".jpg", canvas, {IMWRITE_JPEG_QUALITY, 92, IMWRITE_JPEG_OPTIMIZE, 1})`
- Then Dart writes XMP GPano + EXIF (Phase 11) — a C++ XMP writer is not worth
  the dependency.
- At `high` tier, also emit a 2048×1024 preview alongside, so the UI can show a
  result instantly while the full file is still being written.

---

## 8. Tests

| Case | Assertion |
|---|---|
| `pristine` | S6: SSIM ≥ 0.995, PSNR ≥ 42 dB. Near-perfect or the geometry is wrong |
| `pristine`, rolled by W/2 | S3 at the wrap seam ≤ 1.1× — **the wrap-seam test** |
| strip vs full-canvas blend | bit-identical (±1 LSB) |
| `nominal` | S3 ≤ 2.0×, S4 ≤ 1.03, S6 ≥ 0.97 |
| `parallax_1m`, graph-cut vs feather | graph-cut S3 measurably lower; record both |
| `hdr_interior` | no banding; S4 ≤ 1.03 |
| `partial` | pole/gap fill produces no black pixels; `coverageFraction` honest |
| memory | peak RSS < 700 MB at `high` tier on-device |

---

## 9. Pitfalls

1. **`GraphCutSeamFinder` requires `CV_32F` images.** Passing `CV_8U` fails
   silently or throws deep inside.
2. **`MultiBandBlender::feed` wants `CV_16SC3`.** Convert once, reuse.
3. **`blender.prepare(roi)` must be called before any `feed`,** and every `feed`
   ROI must lie inside it, or you get a crash far from the cause.
4. **`warpRoi` corners can be negative.** Normalise all corners against the
   canvas origin before feeding.
5. **Zenith frames warp to an extremely wide, short ROI** — a frame at pitch 90°
   spans the full canvas width. Do not assume ROIs are small; a naive bounding-box
   memory estimate will be wrong by 10×.
6. **Do not call `waveCorrect`.** Levelling was already done in Phase 03 §5;
   calling it again re-tilts the panorama.

---

## Exit criteria

- [ ] Full pipeline produces a valid equirect end to end
- [ ] Every test in §8 passes
- [ ] Strip-blend equivalence asserted, not eyeballed
- [ ] Wrap-seam test passes with the roll-by-W/2 method
- [ ] Peak RSS < 700 MB at `high` tier on real hardware
- [ ] Stitch of 29 frames at `mid` tier < 60 s on target devices
