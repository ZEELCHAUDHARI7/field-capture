# Architecture §3.3's translation signature: implemented, measured, not shipped

**Status:** negative result. The computation is in the shipping pipeline and its
value is in every report; **no warning is raised from it.**

---

## What §3.3 claims

> Post-hoc detection from bundle adjustment. A pure-rotation model fitted to data
> containing translation leaves a *structured* residual — larger for near content
> than far. Correlating residual magnitude with feature scale gives a translation
> signature for free, on every device, with no extra capture path.

This matters more than most items on the list, because it is the only diagnostic
in the whole pipeline that would tell a user something they can *change*.
Parallax is the honest floor under output quality (architecture §3), the
mitigation is entirely capture technique, and a manager cannot correct a
technique nobody tells them about. Phase 12 §2 gives it a row in the failure-UX
table: *"You moved about 40 cm while capturing. Stand still and pivot in place
for the best result."*

The argument is sound in outline. Parallax disparity for a lens offset `r`
against content at depth `d` goes as `r/d`, so a residual left by a
rotation-only fit should grow for near content; and a surface twice as close
images its texture twice as large, so SIFT's detection scale is a proxy for
`1/d`. Correlate the two and translation should announce itself.

## What it measures

Implemented in `reprojectionResiduals` (`registration.cpp`) as the Pearson
correlation between each kept residual and the geometric-mean log detection scale
of the two keypoints behind it. Geometric mean because the pair is symmetric;
log because scale space is multiplicative and a linear correlation on raw
`KeyPoint::size` would be decided by the handful of coarsest keypoints. Computed
over the same MAD-gated set as S1, so the mismatch tail cannot drive it. It costs
five running sums inside a loop that already exists — genuinely free, as §3.3
says.

Reported as `registration.residual_scale_correlation`, and surfaced by
`tools/replay` on every run.

## What it says

Four profiles, replayed against the native backend at ground-truth canvas size.
The lens offset is ground truth from `ground_truth.json`, not an estimate:

| profile | lens offset | nearest surface | S1 | correlation |
|---|---|---|---|---|
| `pristine` | 0 cm | 3 m | 0.17 px | **+0.377** |
| `nominal` | 0 cm | 3 m | 9.03 px | +0.004 |
| `harsh_imu` | 0 cm | 3 m | 15.20 px | +0.002 |
| `parallax_1m` | **10 cm** | **1 m** | 36.35 px | **−0.094** |

The profile built to contain parallax — 10 cm of entrance-pupil offset against a
surface 1 m away, which architecture §3's table puts at 5.7° or ~97 px at 6144
wide — has the **lowest** correlation of the four. The control group with no
translation whatsoever has the highest. The detector has no true-positive power
on this fixture set, and its largest false positive is `pristine`.

A conjunction with a residual gate (`correlation > 0.25 && S1 > 2 px`) does
suppress the `pristine` false positive, and that is what the first
implementation shipped with. It is not a fix: it makes the detector silent
everywhere rather than wrong somewhere, which is a worse failure because it looks
like it works.

## Why, most likely

The fixture, not the physics. `harness/scene.dart` textures the room with
fractal noise, which is scale-invariant by construction — the same power
spectrum at every spatial frequency. A wall at 1 m and a wall at 4 m therefore
present the *same* distribution of detection scales, so the depth proxy has
nothing to stand on. The `+0.377` on `pristine` is consistent with this: with
translation and pose error both zero, what is left is interpolation and
quantisation error, which really does grow with detail scale, and it dominates
because nothing else is there.

Real construction surfaces are not scale-invariant. Block courses, formwork
ply, service runs and scaffold tube all have characteristic physical sizes, and
those are exactly the scenes where a depth-to-scale proxy should work.

## What would settle it

One afternoon with a tablet, in the Phase 12 §4 corpus: the same scene captured
twice, once pivoted about the lens and once deliberately walked in a 30–40 cm
circle, both from the same station. Two bundles, one number each. If the walked
capture separates, the threshold can be calibrated on real texture and the §2
row becomes deliverable; if it does not, §3.3's proxy is wrong rather than
untested, and the honest answer is that this project cannot distinguish "you
walked" from "the room is small" — which is itself worth writing down, because
the remedy the user needs ("stand further back, pivot on the lens") is the same
either way.

Until then, `reprojection_above_target` names both candidate causes without
asserting which, and that is the whole of what the evidence supports.

## The rule this is an instance of

A fabricated cause is worse than a missing one. "You moved about 40 cm" is a
confident, checkable, falsifiable claim; the first time a manager who pivoted
correctly is told they walked, every other warning in the report loses its
authority, including the ones that are right. Phase 12 §2's two rules — name the
cause, never hide a compromise — do not license inventing a cause to fill a row
in a table.
