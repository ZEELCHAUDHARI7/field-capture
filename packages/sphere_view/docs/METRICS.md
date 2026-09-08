# What the numbers mean

Ten criteria, S1–S10. Every one has a target, because *if it does not have a
number, it is not a criterion — it is an opinion*
(`phases/00_ARCHITECTURE.md` §1). This page says what each one measures, how to
read a `StitchReport`, and what the measured floors actually are.

---

## The ten criteria

| # | What it measures | Target | Where it comes from |
|---|---|---|---|
| **S1** | Geometric accuracy — RMS reprojection error at registration scale | **< 1.0 px** | bundle adjustment's residual, over *every* frame |
| **S2** | Loop closure — yaw error after a full 360° traverse | **< 0.25°** | the composed pairwise chain around the equatorial ring |
| **S3** | Seam invisibility — gradient discontinuity at a seam, against the local noise floor | **< 2×** | `seam_score`, harness only |
| **S4** | Photometric consistency — largest inter-frame gain ratio after compensation | **< 1.03** | the gain compensator |
| **S5** | Coverage — 100% covered ≥1×, every adjacent pair sharing ≥25%, ≥2× coverage ≥70% | see left | the coverage validator, before the camera opens |
| **S6** | Fidelity against ground truth | **SSIM ≥ 0.97, PSNR ≥ 32 dB** | synthetic rig only |
| **S7** | Capture time per station | **≤ 90 s** | on-device timing |
| **S8** | Stitch time for 6144×3072 | **≤ 60 s** | on-device timing |
| **S9** | Peak resident memory during a stitch | **< 700 MB** | on-device instrumentation |
| **S10** | Output validity as a photo sphere | opens in Google Photos / Facebook / any GPano viewer | `exiftool`, then a real viewer |

S1–S6 are quality. S7–S9 are the constraints that stop quality being "solved" by
throwing resolution at it. S10 is what makes the output useful outside this app.

**S5 is three sub-criteria, and one of them used to be wrong.** It read "≥95%
covered ≥2×" until the Phase 02 rasteriser measured it: in one dimension the
double-covered fraction is exactly `ω/(1−ω)`, so demanding 95% *is* demanding
`ω = 0.487` — against a documented default overlap of 0.33 twelve lines later.
The two could never both hold. Matching needs pairwise overlap (0.33 beats the
20–30% production stitchers work at); seams and blending need band *width*, not
sphere-wide redundancy. The criterion was fixed rather than the plan, which is
worth knowing because it is the one case in this project where a criterion turned
out to be the thing that was wrong.

---

## Reading a `StitchReport`

```dart
final result = await SphereStitcher().stitch(bundle);
final report = result.report;

report.meetsQualityTargets;        // S1, S2, S4, S5 and the levelling acceptance
report.rmsReprojectionErrorPx;     // S1, over every frame
report.loopClosureErrorDegrees;    // S2
report.maxGainRatio;               // S4
report.coverageFraction;           // S5's first part
report.residualTiltDegrees;        // Math §7's levelling acceptance
report.droppedPositionIndices;     // positions the pipeline could not use
report.warnings;                   // every compromise, coded
report.elapsedMs;                  // S8
report.tierUsed;                   // the size actually produced
```

Three things about it are deliberate and easy to misread:

**`meetsQualityTargets` excludes S3 and S6.** Both need a reference the device
does not have. They are asserted by the synthetic harness, not at runtime, and a
runtime figure claiming otherwise would be a number with nothing behind it.

**S1 covers every frame, including the ones that never registered.** It used to
exclude them, which read better and meant less: on `nominal` that was 0.295 px
against a ground-truth-referenced 4.65 px, with nothing explaining the gap. When
the two diverge, `imu_only_dominates_residual` reports both figures and names the
difference.

**`warnings` are codes, not sentences.** Each carries the numbers behind it and a
technical `detail` from the stage that raised it; `warning.message` is the
plain-language sentence, from one reviewable table
(`lib/src/api/models/stitch_warning.dart`). `docs/TROUBLESHOOTING.md` is keyed to
the codes. An empty list is the goal; a non-empty one must reach the user, because
**never silently degrade** is the architecture's core principle and a manager who
later discovers a panorama was quietly degraded stops trusting all of them.

The raw report JSON carries three more blocks the typed model does not
(`registration`, `compositing`, `hdr`) with per-stage timings, high-water memory
marks, inlier counts, seam scale and strip count. Those are where "why is S1
9 px" is answered.

---

## The parallax floor, measured

Architecture §3 says handheld capture cannot put every frame at one optical
centre, predicts the resulting disparity as `atan(r/d)`, and states plainly that
nothing removes it. This is that prediction measured against the shipping
pipeline — `dart run tools/parallax_sweep.dart`, with every other error source
switched off so the difference between rows *is* the parallax.

| lens offset `r` | nearest surface `d` | §3 disparity | predicted, frame px | **S1 measured** | measured ÷ predicted | S3 seam | SSIM | at 6144 wide |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 cm | 1 m | 0.00° | 0.0 | **0.14 px** | — | 3.36× | 0.9725 | 0 px |
| 3 cm | 1 m | 1.72° | 8.2 | **5.66 px** | 0.69 | 4.50× | 0.8370 | 29 px |
| 10 cm | 1 m | 5.71° | 27.4 | **19.24 px** | 0.70 | 4.95× | 0.6286 | 97 px |
| 25 cm | 1 m | 14.04° | 67.4 | **46.09 px** | 0.68 | 4.97× | 0.6163 | 240 px |
| 0 cm | 3 m | 0.00° | 0.0 | **0.17 px** | — | 3.64× | 0.9576 | 0 px |
| 3 cm | 3 m | 0.57° | 2.8 | **2.04 px** | 0.74 | 3.73× | 0.9392 | 10 px |
| 10 cm | 3 m | 1.91° | 9.2 | **6.87 px** | 0.75 | 3.66× | 0.6997 | 33 px |
| 25 cm | 3 m | 4.76° | 22.9 | **17.04 px** | 0.75 | 3.83× | 0.5010 | 81 px |

Four things this says:

1. **The analytic model holds.** Measured S1 is a consistent **0.68–0.75×** the
   predicted peak disparity across a 30× range of `r/d`, with no drift. The ratio
   is below 1 because the prediction is at the *nearest* surface while S1 averages
   over content at every depth — so it is the right shape as well as the right
   size. The last column reproduces architecture §3's own table (29 / 97 / 240 px
   at 1 m) from a completely different route, which is the closest thing to an
   independent check this project has.
2. **The control is genuinely a control.** At `r = 0` the pipeline reaches
   0.14–0.17 px, comfortably inside S1's 1.0 px, on the same scene that reads
   46 px at a 25 cm offset. So the floor is parallax rather than the stitcher.
3. **S1 cannot be met handheld at 1 m.** Even 3 cm of lens travel — careful
   pivoting, about the best a person achieves without a clamp — puts S1 at
   5.7 px, six times its target. A tight room is not a case the software can win;
   it is a case for a monopod or for standing somewhere else.
4. **The graph cut is doing its job, and its job is not fidelity.** Across the
   1 m block, S3 rises only 3.36× → 4.97× while SSIM collapses 0.97 → 0.63. The
   seam finder is hiding the disparity where a viewer looks for it — at the
   joins — and the fidelity loss is spread through the frame interiors instead.
   That is exactly the trade architecture §3 chose ("hide, don't average"), and
   it is worth knowing which of the two numbers moves when somebody walks.

The absolute figures are optimistic: this fixture has exact poses, exact
intrinsics, no noise and a perfect lens. A real device adds its own errors on top.
The *relationship* is what transfers, and it is what `CAPTURE_TECHNIQUE.md`'s
table is derived from.

**What is not measured:** the correlation between residual and feature scale that
architecture §3.3 proposes as a free translation detector. It is implemented, it
is reported as `residual_scale_correlation`, and on these fixtures it does not
separate a walked capture from a pivoted one — the profile built to contain
parallax has the *lowest* correlation of the set. See
`phases/findings/translation_signature.md`. No warning is raised from it, because
a fabricated cause is worse than a missing one.

---

## Where the stitch minute goes

`dart run tools/perf_profile.dart --tier mid`, on the synthetic corpus:

| stage | share | measured faithfully by the corpus? |
|---|---:|---|
| bundle adjust | 22% | yes |
| warp | 19% | yes |
| matching | 17% | yes |
| blend (strips) | 12% | yes |
| HDR fusion | 14% | **no** — see below |
| features (SIFT) | 6% | **no** |
| seam (graph-cut) | 5% | yes |
| pole fill | 2% | yes |
| encode | 1.5% | yes |

The corpus renders 480×640 frames; a device shoots 12 MP. Every stage whose cost
is per *input* pixel is therefore understated here, and worse than
proportionally, because Phase 05 §5's downscale-before-fusion never engages at
0.58× oversampling whereas at 12 MP it fires at 3.55× and changes the shape of the
stage. Those stages are measured at capture resolution in C++ instead
(`sphere_stitch_test`, `§5 one 12 MP position through the whole stage`): **717 ms
per fused position**, 3.54× oversampled, fused at 1512 px wide — about 21 s for 29
positions on a desktop core.

What the corpus *does* measure faithfully is everything driven by the output
canvas and the position count, because both are the real ones: a 6144×3072 canvas,
34 positions, 0.33 overlap. That is over half the pipeline.

---

## The quality gate

`tools/ci/quality_gate.sh` replays nine synthetic profiles and compares against
`phases/baselines/*.json`. Two rules make it useful rather than decorative:

- **A recorded FAIL is not a regression.** Several targets are not met yet; the
  baselines record where the pipeline *is*, and the gate's job is to notice
  movement. A gate that was red every day would be a gate nobody looked at —
  which is exactly how a 15× registration regression once survived two phases.
- **Baselines are never updated automatically.** Moving one is a deliberate act,
  in its own commit, with the reason in the message. That is the only thing
  between "we improved the stitcher" and "we got used to the number going up".

Two known noise sources are documented in the gate rather than hidden: peak RSS
gets a 25% band (it is a garbage-collected VM's high-water mark), and everything
downstream of HDR fusion gets 15% because `cv::MergeMertens` is
non-deterministic. The second is **a placeholder for a bug**, not a judgement
about the metrics, and it goes back to 5% the day fusion is deterministic.
