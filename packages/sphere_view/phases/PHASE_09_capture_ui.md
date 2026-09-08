# Phase 09 — Capture UI

**Goal:** the least interface that gets a construction manager through 29
positions correctly, one-handed, in gloves, in sunlight.

**Duration:** 3–4 days. **Depends on:** 08.

---

## 1. Design principle

The user asked for minimal UI, and minimal is also *correct* here. The user's
attention has to be on the physical world — where they are standing, what they are
about to bump into, whether the tablet is level. Every extra element on screen is
attention taken away from aiming.

So: **one thing to do at a time, one place to look.** Put the dot in the ring.
That is the entire interaction. Everything else is either feedback on that action
or gets out of the way.

Explicitly **not** included: a coverage sphere minimap, a thumbnail strip, a grid
overlay, an exposure histogram, filter options, a settings gear, a resolution
picker. Every one of those was considered and rejected — they belong in a
pre-capture screen or nowhere.

---

## 2. Layout

```
┌────────────────────────────────────────────────┐
│  ▂▂▂▂▂▂▂▂▂ ▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂     7/29       │  ← progress, 5 dp tall
│                                                │
│                                                │
│                      ●                         │  ← target dot (moves)
│                                                │
│                  ╭───────╮                     │
│                 │         │                    │  ← centre ring (fixed)
│                  ╰───────╯                     │
│                                                │
│                                                │
│                                                │
│              Turn right                        │  ← one line, only when useful
│                                                │
│  (✕)                            (◉)            │  ← exit          manual shutter
└────────────────────────────────────────────────┘
        full-bleed camera preview behind
```

That is six elements. No panels, no cards, no chrome.

### The ring and the dot

- **Centre ring**: fixed at centre. One circle, 84 dp, 3 dp stroke, in light grey
  with a dark outer stroke so it survives both a white wall and a dark ceiling.
- **Target dot**: an 18 dp filled circle inside a 36 dp ring, positioned by
  `GuidanceState.targetScreenOffset` (Phase 08 §3). It moves as the user turns,
  because it is projected through the real intrinsics — it sits where the target
  genuinely is in the scene. Every *other* remaining target is a 14 dp dot at its
  own true position.
- When the dot is inside the ring and the device is steady, a heavier white arc
  **fills clockwise from twelve o'clock over the ring's own grey track** across
  the 350 ms dwell, and the ring pulls in by 4 dp as it closes. The grey turning
  white *in place* is the whole feedback loop, and it is what makes the
  auto-capture feel intentional rather than arbitrary.
- The track deliberately stays grey while the arc runs. Whitening the whole ring
  on arrival was tried and is worse: it spends the contrast the arc needs, so the
  element that actually reports progress ends up white on white. Arrival is
  already reported twice — the arc starts, and the instruction line stops saying
  "Hold steady".
- This replaced a rounded **square** with the arc on a *second* circle 12 dp
  outside it. At arm's length that read as two unrelated marks: the thing that
  filled was not the thing you were putting the dot into.
- On capture: the ring fills with white and drains over 120 ms, plus a light
  haptic. No shutter sound by default (site environments are loud; the haptic is
  what registers).

### Off-screen targets

When the target is behind or far off-axis, replace the dot with an **arrow pinned
to the screen edge**, in the direction of the shortest rotation. A dot clamped to
the edge implies "nearly there" when the user needs to turn 150°, which is the
single most confusing thing a guided-capture UI can do.

### The instruction line

One short line, 16 sp, bottom-centre, appearing only when it adds information:

| Condition | Text |
|---|---|
| target off-axis, horizontal dominant | `Turn right` / `Turn left` |
| target off-axis, vertical dominant | `Tilt up` / `Tilt down` |
| aimed but moving | `Hold steady` |
| aimed and steady | *(nothing — the ring is filling, that is the feedback)* |
| ring transition | `Now tilt up` / `Now tilt down` |
| frame rejected as blurry | `Too blurry — hold still` |
| relaxed tolerance fired | `Close enough` |
| roll beyond ~12° | `Level the tablet` |

Show one at a time, pick by dominant axis, and **do not** cross-fade between
them — instant swaps read faster.

The roll hint matters on a tablet: a rolled frame is still stitchable (BA handles
it) but it wastes vertical FOV and costs coverage margin. Worth one nudge, not a
hard gate.

### Progress

A 5 dp segmented bar at the top: one segment per target, filled as captured, plus
`7/29`. Ring boundaries get a 2 dp gap so the user can see structure ("I'm most of
the way through the middle row"). Tap the counter to reveal a list of positions
with retake buttons — hidden by default.

---

## 3. Screens either side

The capture screen stays minimal because two thin screens bracket it.

### 3.1 Pre-capture (before the camera opens)

```
        Stand where the pin is.
        Hold the tablet upright, arms in.
        Turn your body slowly — pivot, don't walk.

        ┌──────────────────────────┐
        │   [ diagram: pivot ]     │
        └──────────────────────────┘

        29 photos · about 90 seconds

        [        Start        ]
```

The pivot instruction is the parallax mitigation from architecture §3, and it is
the highest-value sentence in the whole feature. It is worth a small diagram: the
tablet rotating about a vertical axis through its own lens, with a crossed-out
version of swinging it around the body.

If a monopod clamp is available for the site, say so here.

### 3.2 Metering pre-sweep (2 s, inside the capture screen)

```
        Turn slowly all the way around once.
        Setting exposure…
        [ ●●●●●●●○○○ ]
```

This is the AE/AWB metering sweep (Phase 06 §2.3). Framing it as a required step
is better than hiding it — the user is turning anyway, and it sets the expectation
that this is a deliberate, measured process.

### 3.3 Review

Equirect preview (the fast 2048 preview from Phase 04 §7) in the viewer,
`coverageFraction`, and:

- `Retake position…` → back into capture for specific targets
- `Save` → runs the stitch
- If `!report.meetsQualityTargets`, show the specific warnings in plain language
  ("3 photos were too blurry to use", "you appear to have moved 40 cm during
  capture"). **Never** a generic "stitching may be imperfect".

---

## 4. Practical constraints

These are what "works on a construction site" actually means:

| Constraint | Requirement |
|---|---|
| Sunlight | maximum-contrast elements only; white with dark outer stroke. No thin type, no translucent panels. **One** grey, the centre ring's unfilled track — see below |
| Gloves | touch targets ≥ 56 dp. Only two are needed: exit and manual shutter |
| One-handed on a tablet | exit bottom-left, shutter bottom-right, both within thumb reach; nothing interactive in the top half |
| Screen off / lock | wakelock for the session (Phase 08 §5) |
| Orientation | **lock to portrait** during capture. The plan is computed for one intrinsics/orientation pair (Phase 08 §7.4); a mid-session rotation would invalidate it. Portrait also gives the larger vertical FOV, which means fewer rings |
| Interruption | on `AVCaptureSessionWasInterrupted` / Android lifecycle pause, freeze cleanly and offer resume — never lose captured positions |
| Dark interiors | no full-screen white flashes; the 120 ms flash inside the centre ring is enough |

The no-mid-grey rule earned its one exception, and the exception is narrow enough
to state exactly: the **centre ring's unfilled track**. The rule exists so that
nothing unfilled can be mistaken for filled, and on that ring the unfilled state
*is* the grey — what reads as filled is the white arc over it, brighter by 0x40
and wider by 2 dp, with the same dark outer stroke underneath as everything else.
It applies nowhere else. The progress bar's unshot segments are still drawn as
*absence* rather than as a shade, for exactly the reason the rule was written: a
mid-grey segment on a blown-out window reads as captured.

Orientation lock is a real decision, not a shortcut: portrait-only makes the plan
valid, the guidance geometry stable, and the ring count lower. Document it in the
public API.

---

## 5. Implementation notes

- `SphereCaptureView` is a thin `StatefulWidget` over
  `SphereCaptureSession.states`. **All logic lives in Phase 08** — this widget
  makes no decisions, so the interaction is unit-testable without a camera.
- Draw the centre ring, dot, arrow, and progress bar in a **single `CustomPainter`**
  fed by `GuidanceState`. Six elements is not worth a widget tree, and one painter
  guarantees they cannot disagree about frame timing.
- Repaint at preview frame rate; the painter must allocate nothing per frame
  (cache `Paint` objects, avoid `Path` construction in `paint`).
- Haptics via `HapticFeedback.lightImpact()` on capture,
  `mediumImpact()` on ring completion, `heavyImpact()` on session complete.

---

## 6. Tests

- widget test: each `GuidanceHint` renders the expected string; only one at a time
- widget test: dot position matches `targetScreenOffset` exactly
- widget test: target behind → arrow rendered, no dot
- widget test: dwell progress drives the ring's arc 0→1, and the unswept remainder
  stays grey at every dwell rather than going white with it
- widget test: capture flash + haptic fire exactly once per capture
- widget test: progress bar segment count equals `plan.targets.length`; ring gaps
  appear at ring boundaries
- golden tests: the centre ring over pure white and pure black backgrounds — legibility is
  a correctness property here, not a preference
- painter allocates nothing per frame (allocation-count test over 100 frames)
- accessibility: semantics labels on both buttons; instruction line announced on
  change
- manual checklist, on a real tablet outdoors: legible in direct sunlight;
  operable with work gloves

The sunlight and gloves items cannot be automated and must not be skipped — they
are the two constraints most likely to make an otherwise-correct UI unusable.

---

## Exit criteria

- [x] All nine automated tests pass — `test/capture_hud_test.dart`,
      `test/capture_hud_golden_test.dart`, `test/capture_view_test.dart`,
      `test/bracketing_screens_test.dart`
- [ ] **Manual sunlight + gloves checklist passed on a real tablet** —
      `docs/CAPTURE_UI_FIELD_CHECKLIST.md`. Not done; needs a tablet and direct
      sun, and must not be skipped
- [x] Zero per-frame allocations in the painter — asserted over 100 frames of
      moving dot, filling ring and fading flash
- [x] `SphereCaptureView` contains no capture logic — by review, plus a test
      that the file never mentions Phase 08's thresholds
- [x] Example app runs a full session end to end
- [x] Interruption mid-session preserves every captured position
