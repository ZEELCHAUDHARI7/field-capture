# Phase 08 — Plan builder, coverage validator, guidance, session orchestration

**Goal:** the brain of the capture side — decide where to shoot, prove the plan
covers the sphere, guide the user there, and decide when to fire.

**Duration:** 5–6 days. **Depends on:** 01, 06, 07.

---

## 1. `plan_builder.dart`

Implements §8 of [01_MATH_AND_CONVENTIONS.md](01_MATH_AND_CONVENTIONS.md).

```dart
CapturePlan buildPlan({
  required CameraIntrinsics intrinsics,
  double overlapFraction = 0.33,
  bool captureNadir = false,
});
```

Rules, in order:

1. `Δpitch = vfov · (1 − ω)`; rings at `φ = 0, ±Δpitch, ±2Δpitch, …` while
   `|φ| + vfov/2 < π/2`.
2. Per ring: `n(φ) = ceil(2π · cos φ / (hfov · (1 − ω)))`, then re-divide `2π/n`
   evenly so there is no residual gap at the wrap.
3. Stagger ring `k` by `k · Δyaw/2` so vertical seams in adjacent rings do not
   stack. A column of coincident seams is far more visible than staggered ones,
   and it costs nothing to avoid.
4. Single zenith at `+π/2`; single nadir at `−π/2` only if `captureNadir`.
5. **Order for the human, not for the maths.** Equator ring first (that is where
   the content the manager cares about is — if they abandon halfway, the useful
   part is done), then up, then zenith, then down, then nadir. Within a ring,
   always the same rotation direction. Each ring starts near the yaw where the
   previous ended, so the user never spins back.

Rule 5 is the difference between a plan that is technically optimal and one a
person can actually execute while holding a tablet on a live site.

---

## 2. `coverage_validator.dart` — the gate

Arithmetic is not proof. Rasterise and count.

```dart
CoverageReport validate(CapturePlan plan, CameraIntrinsics k);
```

1. Sample the sphere on an approximately equal-area lattice (Fibonacci lattice,
   ~40 000 points ≈ 1° spacing). **Not** a naive lat/lon grid — that
   over-samples the poles by a factor of 100 and would let an equatorial gap hide
   behind a passing polar score.
2. For each point, count how many planned frusta contain it: transform into each
   camera's frame, reject if behind, project through `K`, accept if inside the
   image rectangle **shrunk by the same border erosion Phase 04 §1 applies**.
   Validating against the un-eroded rectangle would certify coverage that the
   compositor then discards.
3. Report the three parts of S5 (Math §8) and the yaw/pitch of every gap:
   - **S5a** `fractionCoveredAtLeastOnce` — must be 1.0, less a nadir cap the
     plan has explicitly declared it is skipping;
   - **S5b** `minimumPairwiseOverlap` — ≥ 0.25, the weakest link among frame
     pairs that overlap at all. **This is the criterion that matters**: feature
     matching is pairwise, so what it needs is that neighbours share enough
     image, not that the sphere as a whole is redundant;
   - **S5c** `fractionCoveredAtLeastTwice` — ≥ 0.70, a floor against degenerate
     plans. Report the real number; do not tune the plan to raise it. It read
     ≥ 0.95 until Phase 02 measured it, which is algebraically a demand for
     ω = 0.487 against a 0.33 default — Math §8 has the derivation.

**Note the implementation already exists.** Phase 02 needed a real planner to
render against, so `lib/src/plan/plan_builder.dart` and `coverage_validator.dart`
are written, tested and measured. Audit them against this document rather than
rewriting: the rasteriser is equal-area (uniform in `sin φ`), the frustum test is
exact pinhole, and the polar-gap fallback widens the outermost rings when — and
only when — the lattice says a hole exists.

If `!isAcceptable`, either reduce `overlapFraction`'s denominator (more shots) or
refuse the session with a specific message. **Never open the camera on a plan
that cannot succeed** — that wastes 90 seconds of the user's time on site and
produces a bad panorama they will blame on the software.

Test: `overlapFraction = 0.05` must be rejected; the default must pass for every
intrinsics set in a fixture list covering the real device fleet from Spike B.

---

## 3. `guidance_engine.dart`

Pure function, no side effects, fully unit-testable:

```dart
GuidanceState evaluate({
  required DevicePose pose,
  required CaptureTarget target,
  required SphereCaptureConfig config,
});

class GuidanceState {
  final double angularErrorRadians;
  final Offset targetScreenOffset;   // where to draw the dot (see below)
  final GuidanceHint hint;           // turnRight | turnLeft | tiltUp | tiltDown | holdSteady | onTarget
  final bool withinAimTolerance;
  final bool steady;
  final double dwellProgress;        // 0..1
}
```

### Projecting the target dot to screen space

The reticle is fixed at screen centre; the **target dot moves**. To place it,
project the target direction through the live pose and the real intrinsics:

```
d_cam = R_worldToDevice · target.direction
if (d_cam.z >= 0) → target is behind; draw an off-screen arrow instead
u = -d_cam.x / d_cam.z · fx + cx
v =  d_cam.y / d_cam.z · fy + cy
```

Using the **measured** intrinsics means the dot sits exactly where the target
actually is in the preview, so "put the dot in the ring" is geometrically
truthful. This is why intrinsics discovery (Phase 06) has to come first — with a
guessed focal, the dot drifts relative to the scene and the interaction feels
broken in a way users cannot articulate.

When the target is behind the device, show a directional arrow at the screen edge
rather than a clamped dot. A dot pinned to the edge implies "nearly there" when
the user needs to turn 150°.

---

## 4. `shutter_gate.dart`

Fire when **all three** hold:

```
aim:     angularError < config.aimToleranceDegrees        (default 4°)
steady:  angularSpeed < config.steadinessThresholdRadPerSec  (default 0.12 rad/s ≈ 7°/s)
dwell:   both of the above continuously true for config.dwell  (default 350 ms)
```

Then, after capture:

```
sharpness: Laplacian variance of the 0 EV shot > config.minSharpness
           → else discard, keep the target, show "hold still"
```

The gates are much tighter than the current code (10° aim, 0.25 rad/s). The old
values were loose because the old pipeline had no way to fix residual error, so
loose gates were the only way to make progress at all. The new pipeline wants
good seeds and sharp frames, and BA cleans up what remains.

The steadiness gate is doing double duty: it prevents motion blur *and* it
prevents rolling-shutter skew, which cannot be corrected after the fact
(architecture §8).

### Adaptive relaxation

If a target is not satisfied within ~8 s, relax `aimTolerance` toward 7° in
steps, and say so ("close enough — capturing"). A gate the user cannot satisfy is
worse than a slightly worse seed; a stuck capture flow is the fastest way to lose
the user's trust in the feature.

Never relax the sharpness or steadiness gates — those produce genuinely
unusable frames, and a blurry frame damages the stitch rather than merely
degrading it.

---

## 5. `SphereCaptureSession` — the orchestrator

```dart
class SphereCaptureSession {
  static Future<SphereCaptureSession> create({SphereCaptureConfig config});

  Stream<SessionState> get states;
  CapturePlan get plan;

  Future<void> beginMetering();        // the pre-sweep
  Future<void> beginCapture();
  Future<void> captureManual();        // the manual shutter
  void retake(int targetIndex);
  Future<CaptureBundle> finish();      // works even if incomplete
  Future<void> abort();
}
```

State machine:

```
idle
 └─► probing        (enumerate cameras, read intrinsics)
      └─► planning  (build plan, validate coverage — may FAIL here)
           └─► metering     (2 s pre-sweep, then AE/AWB/AF hard lock)
                └─► capturing ⇄ retaking
                     └─► complete ──► finish() ──► CaptureBundle
     (any) ─► failed(reason)
```

Responsibilities:

- **wakelock** for the whole session (a 90 s capture must not sleep)
- **write frames to disk immediately**; never hold 87 JPEGs in memory
- **incremental `bundle.json`** after every position, so a crash or a phone call
  mid-session leaves a resumable bundle rather than nothing
- **resume**: `SphereCaptureSession.resume(directory)` reloads a partial bundle
  and continues from the first uncaptured target. On a live site, interruptions
  are the norm — losing 25 captured positions to a phone call is unacceptable
- **`finish()` on an incomplete plan** emits a valid bundle with honest coverage;
  the stitcher handles partial spheres (Phase 04 §6). Never block the user from
  keeping what they have.

---

## 6. Tests

Guidance and planning are pure, so test them properly:

- `plan_builder` for each fixture intrinsics set → coverage validator passes
- `overlapFraction = 0.05` → plan rejected
- worked example from §8 of the math doc reproduces exactly (11/8/8/1/1 = 29)
- ring staggering: no two rings share a yaw value
- ordering: equator first; within a ring, monotonic direction; ring transitions
  minimise yaw travel
- `guidance_engine`: target dead ahead → zero error, `onTarget`
- target 90° right → `turnRight`, dot off-screen, arrow shown
- target behind → arrow, not a clamped dot
- projected dot position verified against a hand-computed value for three poses
- `shutter_gate`: fires only when all three conditions hold; a 340 ms dwell does
  not fire, 360 ms does
- adaptive relaxation engages after 8 s and is reported
- sharpness rejection keeps the target pending
- session: simulated crash after 12 positions → `resume` continues at 13
- `finish()` at 60% → valid bundle, `coverageFraction ≈ 0.6`, warning present

---

## 7. Pitfalls

1. **Do not validate coverage against the un-eroded frame rectangle.** Phase 04
   erodes masks by ~1.5%; certifying coverage the compositor then throws away
   produces gaps that no test catches.
2. **Yaw wraps.** Every angular comparison goes through `wrapPi`. An unwrapped
   comparison silently breaks exactly at the ±180° meridian — the same place the
   wrap seam lives, so two independent bugs appear as one.
3. **Nadir/zenith yaw is meaningless.** At `|pitch| = π/2` the yaw component of
   the aim error is degenerate; use pure angular distance between directions, not
   separate yaw/pitch errors.
4. **The plan is only valid for one intrinsics set.** If the camera reconfigures
   (thermal downscale, interruption), rebuild and re-validate the plan.
5. **Do not reset the pose buffer between targets** (Phase 07 §6.5) — the
   steadiness gate needs continuous history.

---

## Exit criteria

- [ ] All fifteen tests in §6 pass
- [ ] Coverage validator rejects bad plans and accepts every real-device fixture
- [ ] Resume-after-crash verified with a simulated kill
- [ ] `finish()` on a partial sphere produces a stitchable bundle
- [ ] Full 29-position session completes in **≤ 90 s** on real hardware (S7)
