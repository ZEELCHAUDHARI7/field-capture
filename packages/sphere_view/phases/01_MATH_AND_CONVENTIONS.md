# Math & Conventions (NORMATIVE)

> Every phase, both languages, and the viewer cite this document. Do not
> redefine any frame or formula locally. Mismatched conventions between the
> planner, the tracker, the stitcher and the viewer are the single most common
> cause of mirrored, upside-down, or 90°-rotated panoramas — and the bugs are
> maddening to find because each component looks correct on its own.
>
> Everything in §1–§4 has been derived against OpenCV's actual
> `SphericalProjector` implementation, not assumed. §6 flags the two values that
> must be verified empirically rather than trusted.

---

## 1. Frames

All four frames are **right-handed**.

### 1.1 World frame `W` — our canonical frame

| Axis | Direction |
|---|---|
| `+Y_w` | **up** (anti-gravity, from the accelerometer) |
| `+Z_w` | the camera's horizontal heading **at session start** (this defines yaw = 0) |
| `+X_w` | `Y_w × Z_w` — which, for an observer looking along `+Z_w`, points to their **left** |

Yaw 0 is wherever the user was pointing when the session began. We deliberately
do **not** use the magnetometer: indoors, rebar, lift motors and steel studs bend
the magnetic heading by tens of degrees, and a "rotate to the target" gate that
needs ~5° accuracy would never fire. True north, if wanted, is recorded once as
`PoseHeadingDegrees` metadata (§5) — it never enters the geometry.

### 1.2 Device frame `D` — ARKit / OpenGL convention

`+X_d` right across the screen, `+Y_d` up the screen, **camera looks along `−Z_d`**.
This is what iOS `CMDeviceMotion` and ARKit report, and it is the frame the
existing Dart tracker already uses.

### 1.3 OpenCV camera frame `C`

`+X_c` right, `+Y_c` **down**, **`+Z_c` forward** (into the scene).

### 1.4 OpenCV panorama frame `P`

`+X_p` right, `+Y_p` **down**, `+Z_p` forward. This is the frame OpenCV's
`detail::CameraParams::R` rotates *into*.

---

## 2. Pose representation and the OpenCV conversion

The tracker produces a unit quaternion **`q` = device→world**, i.e. its matrix
`R_wd` maps a vector expressed in `D` to the same vector expressed in `W`.

OpenCV needs `R_pc` = camera→panorama. Deriving it:

```
C = N · D      with  N = diag( 1, −1, −1)      (180° about X;  N⁻¹ = N)
P = M · W      with  M = diag(−1, −1,  1)      (180° about Z;  M⁻¹ = M)
```

Both have `det = +1`, so both are proper rotations. Therefore:

```
                R_opencv  =  M · R_wd · N
                          =  diag(−1,−1,1) · R_device→world · diag(1,−1,−1)
```

**Verification** (do this in the unit test, `test/conventions_test.dart`):

- OpenCV camera forward is `(0,0,1)_c`. `N·(0,0,1) = (0,0,−1)_d` = the device's
  optical axis ✓. `R_wd · (0,0,−1)_d` = the world heading. `M ·` that lands in
  `P` ✓.
- OpenCV camera up is `(0,−1,0)_c`. `N·(0,−1,0) = (0,1,0)_d` = up the screen ✓.
  Held level, that is world up `(0,1,0)_w`, and `M·(0,1,0)_w = (0,−1,0)_p`, which
  in a Y-down frame is up ✓.

In code, `M · R · N` is just a sign flip — no matrix multiply needed:

```
R_opencv[i][j] = s_i · R_wd[i][j] · t_j ,   s = (−1,−1,+1) ,  t = (+1,−1,−1)
```

---

## 3. Equirectangular mapping

Output canvas is `W × H` with `H = W/2`. OpenCV's `SphericalWarper` is
constructed with

```
                        scale = W / (2π)
```

so that `u ∈ [−W/2, +W/2]` and `v ∈ [0, H]`. `SphericalProjector::mapForward`
computes, for a world/pano ray `(x_p, y_p, z_p)` normalised:

```
u = scale · atan2(x_p, z_p)
v = scale · (π − acos(ŷ_p))
```

Converting to our world frame (`x_p = −x_w`, `y_p = −y_w`, `z_p = z_w`) and to
pixel coordinates (`x_img = u + W/2`, `y_img = v`) gives the **only two mapping
formulas anyone should ever write**:

```
                x_img = W · ( ½  −  yaw   / (2π) )
                y_img = H · ( ½  −  pitch /  π   )
```

with the inverse:

```
                yaw   =  π  · ( 1 − 2·x_img / W )
                pitch = (π/2)· ( 1 − 2·y_img / H )
```

where, for a unit world-space direction `d`:

```
                yaw   = atan2(d.x, d.z)      ∈ (−π, π]
                pitch = asin(d.y)            ∈ [−π/2, π/2]
```

### Consequences — memorise these, they are the sanity checks

| Property | Value |
|---|---|
| Image **centre** `x = W/2` | yaw 0 = **session-start heading** |
| Image left edge `x = 0` | yaw `+π` (behind you) |
| Image right edge `x = W` | yaw `−π` (behind you — same meridian) |
| Turning **right** (yaw decreasing) | content moves **right** in the image ✓ not mirrored |
| Top row `y = 0` | pitch `+π/2` = zenith |
| Bottom row `y = H` | pitch `−π/2` = nadir |

Because the image centre is the session-start heading, **no yaw offset is
applied anywhere in the pipeline.** The existing Dart stitcher instead placed
yaw `+π` at `x = 0`; the formulas above are algebraically the same mapping, just
re-centred, and this re-centring is what makes the OpenCV path zero-conversion.

---

## 4. Camera intrinsics

Pinhole model in OpenCV pixel coordinates (origin at the **top-left** of the
output image, `x` right, `y` down):

```
        ⎡ fx   0   cx ⎤
    K = ⎢  0  fy   cy ⎥        HFOV = 2·atan( W_px / (2·fx) )
        ⎣  0   0    1 ⎦        VFOV = 2·atan( H_px / (2·fy) )
```

### 4.1 Android — `CameraCharacteristics`

Per the **R2 finding**, `LENS_INTRINSIC_CALIBRATION` is gated by no capability
flag and is documented as simply "may be null on some devices" — reported null
even on Pixel hardware. So **derive from physics as the primary path** and treat
`LENS_INTRINSIC_CALIBRATION` as an optional override when non-null. This is the
reverse of the usual instinct, and it is what the evidence supports.

Anchor **every** coordinate — crop region, principal point, distortion
coefficients — to `SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE`, and always
request `DISTORTION_CORRECTION_MODE_OFF`. That keeps the whole geometry pipeline in
one frame and sidesteps the HAL's own correction, which AOSP's docs concede is
imprecise ("rectangles do not generally map to rectangles when corrected"). On
devices that only list `OFF` — likely most of our fleet — the two array sizes are
identical and the distinction is moot.

```
pixelPitch_x  = SENSOR_INFO_PHYSICAL_SIZE.width / pixelArraySize.width
fx_sensor     = LENS_INFO_AVAILABLE_FOCAL_LENGTHS[i] / pixelPitch_x
cx_sensor     = centre of preCorrectionActiveArraySize   (or LENS_INTRINSIC_CALIBRATION)

cx_crop       = cx_sensor − cropRect.left                 (fx unchanged by cropping)

# streamSourceRect = the aspect-fit sub-rect of the crop region, per
# SCALER_CROP_REGION's own letterbox/pillarbox rule
scaleX        = outputWidth_px / streamSourceRect.width
fx_out        = fx_crop · scaleX
cx_out        = (cx_crop − streamSourceRect.left) · scaleX
```

The crop/aspect-fit term matters: a 4:3 output from a 4:3 array is a pure scale,
but a 16:9 stream is a **crop**, and ignoring it gives a wrong focal and a
panorama that does not close. Always compute from the *actual* stream.

**Worked example** (R2): focal 4.25 mm, sensor 5.76×4.32 mm, array 4032×3024, full
crop, 1920×1080 output. `pixelPitch = 0.0014286 mm/px` → `fx_sensor = 2975.0`. The
16:9 stream letterboxes the 4:3 crop → `streamSourceRect = (0, 378, 4032, 2268)`,
`scale = 0.47619` → **`fx = fy = 1416.7`, `cx = 960.0`, `cy = 540.0`**. `cx/cy`
landing exactly at image centre is the sanity check for a centred crop.

Fallback if focal or physical size is missing:
`fx = W_px · FocalLengthIn35mmFilm / 36.0` from EXIF.

**Distortion: `LENS_DISTORTION`** (API 28+), 5 elements. **R2 resolved this** —
AOSP states explicitly that it *is* the Brown–Conrady model, and term-by-term
comparison against OpenCV's shows a 1:1 correspondence. Android orders
`[R,R,R,T,T]`; OpenCV orders `[R,R,T,T,R]`. So it is a pure **reorder**, no value
transform:

```
distCoeffs = { kappa_1, kappa_2, kappa_4, kappa_5, kappa_3 }
//             k1        k2        p1        p2        k3
```

Android's equation is also the undistorted→distorted backward mapping, which is
the same convention `cv::undistort` / `cv::initUndistortRectifyMap` use
internally — so the reordered coefficients drop straight in with no further math.

### 4.2 iOS — `AVFoundation`, in priority order

Per the **R2 finding**, full `AVCameraCalibrationData` requires a *multi-camera
virtual device*, which excludes base iPad, iPad Air and iPad mini outright — so on
most of our fleet, path 1 is simply unavailable and path 3 is the realistic
primary. Design for that, do not treat it as a degraded case.

1. **`AVCameraCalibrationData.intrinsicMatrix`** — a true 3×3, valid for
   `intrinsicMatrixReferenceDimensions`; rescale to the real output size. Requires
   a dual/multi-camera device **plus** GDC and content-aware correction disabled
   (an Apple engineer confirmed calibration delivery is unsupported with GDC on).
   Also gives `lensDistortionLookupTable`.
2. **`AVCaptureConnection.cameraIntrinsicMatrix`** via
   `AVCaptureVideoDataOutput` (**not** photo output). Its docs impose no
   multi-camera requirement, but 2017–18 forum reports directly conflict on
   whether it works on iPad at all. **Unconfirmed — Phase 00 Spike B must settle
   it on the actual devices.**
3. **`AVCaptureDevice.Format.videoFieldOfView`** — **confirmed HORIZONTAL** FOV in
   degrees (R2). Then `fx = (W_px/2) / tan(FOV/2)`.
   Use `videoFieldOfView` with GDC explicitly **disabled** — not
   `geometricDistortionCorrectedVideoFieldOfView`, which describes the post-GDC
   frame and only applies while GDC is on.
4. **EXIF fallback**, as above.

**Distortion on iOS is radial-only.** `lensDistortionLookupTable` is a 1D array of
magnification factors along the radius from `lensDistortionCenter`, with no
tangential component. To get Brown–Conrady coefficients, least-squares fit
`r'/r = 1 + k1·r² + k2·r⁴ + k3·r⁶` over sampled radii and **force `p1 = p2 = 0`** —
Apple's model gives no basis for tangential terms, so fitting them would be
fitting noise.

**Mandatory on every capture**, whichever path is used: set
`isGeometricDistortionCorrectionEnabled`,
`isContentAwareDistortionCorrectionSupported`/`Enabled`, and
`isAutoContentAwareDistortionCorrectionEnabled` all to false. Apple's own docs say
content-aware correction is applied "at its discretion" — i.e. variably,
per-frame, content-dependent — which invalidates any fixed intrinsics model.

### 4.3 The safety net: bundle adjustment refines focal anyway

`detail::BundleAdjusterRay` with a refinement mask that enables `fx` will
recover the true focal from the imagery itself. So an initial focal that is
5–10% off still converges. This is why the fallback chain is acceptable — but a
good initial value keeps BA in the right basin, so it is still worth getting
right.

---

## 5. Output metadata (XMP GPano)

Written so the result is recognised as a photo sphere by Google Photos,
Facebook, and every standard viewer. Namespace
`http://ns.google.com/photos/1.0/panorama/`.

| Property | Value |
|---|---|
| `ProjectionType` | `equirectangular` |
| `UsePanoramaViewer` | `True` |
| `FullPanoWidthPixels` / `FullPanoHeightPixels` | `W` / `H` |
| `CroppedAreaImageWidthPixels` / `...Height...` | `W` / `H` (we always emit full) |
| `CroppedAreaLeftPixels` / `...TopPixels` | `0` / `0` |
| `PoseHeadingDegrees` | compass heading of the **image centre**, i.e. of yaw 0 |
| `PosePitchDegrees` / `PoseRollDegrees` | `0` / `0` — gravity is already levelled by §7 |

`PoseHeadingDegrees` is the *only* place the magnetometer is used, and it is
purely cosmetic (it sets the viewer's opening direction). For the site-walk
feature the better source is the plan itself: the manager taps their facing
direction on the drawing, which we convert to a heading. Prefer that when
available.

---

## 6. Values that must be measured, never assumed

Both of the original entries here were **closed by research R2**:

| Value | Status |
|---|---|
| `AVCaptureDeviceFormat.videoFieldOfView` — horizontal or diagonal? | ✅ **HORIZONTAL**, confirmed. Use with GDC disabled |
| Android `LENS_DISTORTION` order vs OpenCV `(k1,k2,p1,p2,k3)` | ✅ **Pure reorder** `{κ1,κ2,κ4,κ5,κ3}`, genuinely Brown–Conrady per AOSP. No value transform |

What remains open, for **Phase 00 Spike B** on real hardware:

| Value | Why it is dangerous | How to settle it |
|---|---|---|
| Does `AVCaptureConnection.cameraIntrinsicMatrix` work on our iPads? | it is the *only* measured-intrinsics path available on single-lens iPads; forum evidence directly conflicts and one report says it fails on iPad Pro | enable it on `AVCaptureVideoDataOutput` and check whether the sample-buffer attachment actually arrives, per device |
| Do any current iPads still have a dual/multi-camera rear system? | if none do, `AVCameraCalibrationData` is dead on our whole fleet and path 1 can be deleted | inspect the actual target lineup |
| Real null-rate of `LENS_INTRINSIC_CALIBRATION` / `LENS_DISTORTION` on our Android tablets | determines whether the distortion model is ever available in the field | capability dump across the fleet |
| Is `DISTORTION_CORRECTION_MODE` non-`OFF` supported anywhere on our fleet? | decides whether the pre-correction vs active array distinction matters at all | capability dump |

**Consequence for the design:** intrinsics quality is a **gradient**, not a
constant — calibrated dual-cam device > intrinsic-matrix-only > FOV-derived-only.
Registration (Phase 03) must tolerate the whole range rather than assume one
reliable source, and `IntrinsicsSource` must be carried into `StitchReport` so a
soft panorama can be traced to a weak intrinsics path.

---

## 7. Levelling: fixing bundle adjustment's gauge freedom

A rotation-only bundle adjustment has an exact **3-DOF gauge freedom** — rotate
every camera by the same `R_g` and the reprojection error is unchanged. Stock
OpenCV resolves this with `detail::waveCorrect`, a heuristic that assumes the
capture was a roughly horizontal sweep. It is unreliable for a full sphere and
it is the reason many hand-rolled 360 stitchers come out tilted.

We have better information: the accelerometer measured gravity at every shutter.
So:

1. Run BA freely; get `R_i^BA` for each frame.
2. For each frame, the IMU says world up is `u_i^IMU`; the BA solution says it
   is `u_i^BA = R_i^BA · (camera-frame up)`.
3. Solve for the single `R_g` minimising `Σ_i ‖ R_g·u_i^BA − u_i^IMU ‖²`
   (Procrustes / Kabsch on the two 3×N sets, or quaternion averaging).
4. Apply `R_i ← R_g · R_i^BA` to every frame.

This pins **both** the gravity axis and the heading in one step, using measured
data instead of a guess. `waveCorrect` is never called.

Acceptance: on the synthetic rig, residual tilt after step 4 must be **< 0.2°**.

---

## 8. Shot-plan geometry

For a camera with horizontal FOV `h` and vertical FOV `v` (radians), and a
target overlap fraction `ω` (default `0.33`):

**Yaw step within a ring at pitch `φ`.** A frame at pitch `φ` spans more *yaw*
degrees than at the equator, because the yaw circle is shorter there by
`cos φ`:

```
        Δyaw(φ) = h · (1 − ω) / cos φ
        n(φ)    = ceil( 2π / Δyaw(φ) )
        Δyaw    = 2π / n(φ)                 ← re-divide evenly, no gap at wrap
```

**Ring pitches.** Rings must overlap vertically by `ω` as well:

```
        Δpitch = v · (1 − ω)
```

Rings are placed at `φ = 0, ±Δpitch, ±2Δpitch, …` while
`|φ| + v/2 < π/2`, then a **single** zenith shot at `+π/2` and (optionally) a
single nadir shot at `−π/2`. A single polar shot covers all yaw near the pole,
down to a cap of angular radius `min(h,v)/2`, so the outermost ring must reach
within that of the pole.

**Consecutive rings are staggered by `Δyaw/2`** so that vertical seams in
adjacent rings do not line up — a stack of coincident seams is far more visible
than staggered ones.

### Two shots at each pole, not one

An earlier version of this section said "a **single** zenith shot". The
rasteriser disproved it: the caps above ±70° are ~6% of the sphere's area, and a
lone polar frame covers them exactly once, which pins double coverage near 90%
however tight the rings get. It is also the worst place to have no redundancy —
polar frames are where equirect warping is most extreme and where a frame's own
edge quality is poorest.

Fix: **two frames per pole, the second rolled 90° about the optical axis.** One
extra shutter per pole, their intersection is a double-covered cap of radius
`min(h,v)/2`, and the roll gives the matcher a genuinely different view rather
than a duplicate.

### What "enough overlap" actually means — S5, corrected

The original S5 read *"100% covered ≥1×, ≥95% covered ≥2×"*. **The second half
was wrong**, and it is worth showing why so nobody restores it.

In one dimension, frames of angular width `w` at spacing `s = w(1−ω)` overlap
over `wω` of every `s`, so:

```
        fraction covered twice  =  wω / s  =  ω / (1 − ω)
```

Setting that to 0.95 gives **ω = 0.487**. So "95% of the sphere covered twice" is
algebraically a demand for ~49% overlap — while this very section defaults to
`ω = 0.33`. The two statements contradicted each other, which is the tell that
the 95% was never derived from anything; it was a plausible-sounding redundancy
target.

Measured on the rasteriser, across three realistic main-camera intrinsics
(full sphere, nadir captured):

| ω | positions | ≥1× | ≥2× |
|---|---|---|---|
| 0.25 | 26–31 | 100% | 60–67% |
| **0.33** | **28–34** | **100%** | **80–83%** |
| 0.45 | 34–43 | 100% | 98–99% |

Buying 95% costs **+6 to +9 positions (~+25%)**, which pushes a bracketed session
to ~88 s against S7's 90 s budget and adds ~30% more frames to every stitch stage
against S8's. It buys nothing the pipeline needs:

- **Matching** needs pairwise overlap, not sphere-wide double coverage. `ω = 0.33`
  gives every adjacent pair a third of a frame in common — above the 20–30%
  that Hugin, PTGui and Street View all work at.
- **Seam routing and multi-band blending** happen *inside* the overlap band. At
  `ω = 0.33` that band is `0.33 × 50° ≈ 16.5°` ≈ **280 px** at 6144 wide; a
  5-band blend needs ~32 px. Comfortable.
- **Redundancy against a dropped frame** is handled where frames get dropped:
  Phase 08 keeps a blurry target pending and re-shoots it, and Phase 03 never
  discards a frame — an unmatchable one falls back to its IMU prior and is
  flagged `imu_only`.

**S5, as it now stands:**

| | Criterion | Gate |
|---|---|---|
| **S5a** | 100% of the sphere covered **≥1×**, excluding a nadir cap the plan has explicitly declared it is skipping | **hard** — holes are real defects |
| **S5b** | every adjacent frame pair shares **≥25%** of frame area | **hard** — this is what matching needs, and it is per-pair, not a sphere fraction |
| **S5c** | fraction covered **≥2×** ≥ **70%** | **sanity floor** — catches degenerate plans; `ω = 0.33` gives ~80%. Report the real number; do not tune to it |

`coverage_validator` remains the gate. The arithmetic above proposes; the
lattice disposes.

**Worked example, main camera on a tablet** (`h = 50°`, `v = 69°`, `ω = 0.33`),
matching what the rasteriser actually produces:

```
  Δpitch = 69 · 0.67 = 46.2°
  ring  φ=  0° :  Δyaw = 33.5°/1.000 → n = 11
  ring  φ=+46°:  Δyaw = 33.5°/0.695 → n =  8      (46+34.5 = 80.5 < 90 ✓)
  ring  φ=−46°:  Δyaw = 33.5°/0.695 → n =  8
  zenith φ=+90°: 2        (second rolled 90°)
  nadir  φ=−90°: 2        (optional; off by default)
  ─────────────────────────────────────────
  29 positions nadir-skipped / 31 with nadir
  × 3 bracketed exposures = 87–93 frames, ~70 s
  measured: 100% ≥1×, 80.7% ≥2×  → S5a ✓  S5b ✓  S5c ✓
```

Compare with the old hard-coded plan (21 shots, 52° assumed HFOV, 8 per ring):
**~15% overlap**, below what feature matching needs. The plan must be computed
from measured intrinsics, never hard-coded.

**`coverage_validator` is the gate**, not this arithmetic. It rasterises the
sphere on an equal-area lattice (uniform in `sin φ`, so the reported figure is a
fraction of *area* — a lat/lon grid oversamples the poles ~100× and would let an
equatorial hole hide behind a passing polar score), projects each cell centre
through the exact pinhole frustum, and asserts S5a/b/c above. Frames are tested
against the image rectangle **shrunk by the same border erosion Phase 04 §1
applies**, so the validator never certifies coverage the compositor then
discards. Any plan that fails is rejected before the camera opens.
