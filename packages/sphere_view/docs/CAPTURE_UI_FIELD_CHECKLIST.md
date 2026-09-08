# Capture UI — the two checks that cannot be automated

Phase 09 §6 ends with two items no test rig can perform:

> - legible in direct sunlight
> - operable with work gloves
>
> The sunlight and gloves items cannot be automated and must not be skipped —
> they are the two constraints most likely to make an otherwise-correct UI
> unusable.

Everything else in Phase 09 is asserted by `test/capture_hud_test.dart`,
`test/capture_hud_golden_test.dart`, `test/capture_view_test.dart` and
`test/bracketing_screens_test.dart`. **These are not**, and a green suite says
nothing about them. The golden tests over pure white and pure black prove the
overlay has *contrast against the extremes*; they cannot prove a person can read
it at arm's length at 100 000 lux, and no measurement in this repository can.

Run this on a real tablet, outdoors, in gloves, before Phase 09 is called done.

## Kit

- The target tablet (the rugged Android one and an iPad, if both are in the
  fleet), at **maximum brightness**, screen clean and dry.
- Ordinary site gloves — the ones the manager actually wears, not thin
  touchscreen gloves.
- Direct sun. An overcast day does not test this; neither does a window.
- Somewhere with a bright wall *and* a dark corner in the same sphere. A
  part-built interior is ideal, a stairwell will do.

## Sunlight — legibility

Stand so the sun is behind you and on the screen. For each item, the question is
**"can I act on this without stopping and shading the screen?"** Shading the
screen to read something is a fail, not a workaround.

| # | Check | Pass |
|---|---|---|
| 1 | The centre ring is findable without looking for it | ⬜ |
| 2 | The target dot is distinguishable from a bright reflection on the glass | ⬜ |
| 3 | **The grey track and the white filled arc are told apart at a glance** | ⬜ |
| 4 | The arc's fill is visible *while turning*, in peripheral vision | ⬜ |
| 5 | The instruction line is readable at arm's length, first glance | ⬜ |
| 6 | Captured and not-yet-captured progress segments are told apart at a glance | ⬜ |
| 7 | The `7/29` counter is readable | ⬜ |
| 8 | The edge arrow is visible against a blown-out sky in the preview | ⬜ |
| 9 | The 120 ms disc flash inside the ring registers as a capture, in sun | ⬜ |
| 10 | The smaller dots for later targets are findable without looking for them | ⬜ |
| 11 | Repeat 1–10 pointing at an unlit ceiling or a dark corner | ⬜ |

Item 3 is the one this design stakes everything on, and the one thing no test on
a desk can settle. The overlay's rule is "no mid-grey", and that ring's track is
its single exception (Phase 09 §4): it is grey because grey is what *unfilled*
means there, and the claim is that a white arc 2 dp wider and 0x40 brighter over
it is unmistakable at 100 000 lux. If it is not, the fix is a brighter or wider
arc, or a darker track — **not** whitening the whole ring on arrival, which was
tried and spends the contrast the arc needs.

Otherwise, if something fails the fix is almost always *more dark outline*, not
more white and not a translucent panel — §4 rules those out and the goldens will
catch a regression either way.

## World-locking — the thing a desk cannot check

The marks are re-projected from their own world directions on every frame, so if
the pose is right they are pinned in space. That is exactly the property no unit
test can confirm, because it is a claim about the sensor and the lens agreeing
with each other on real hardware.

| # | Check | Pass |
|---|---|---|
| 1 | Pan slowly right: the dots slide **left** across the screen, staying on the same spot in the room | ⬜ |
| 2 | Pan back: they return to where they were, not to a new place | ⬜ |
| 3 | The scene and the dots move together — no lag, no drift apart, no motion along different axes | ⬜ |
| 4 | Hold still for 30 s at one target: the dot does not creep | ⬜ |
| 5 | Turn a full 360°: the first dot is where you left it | ⬜ |

Checks 1 and 3 are the ones that catch a frame mismatch — a preview a quarter
turn out from the projection makes the scene slide *down* while the dots slide
left, and every other check can still pass. Check 4 catches gyro drift and check
5 catches it accumulating, which is also what S2 measures after the fact.

## Gloves — operability

Wearing the gloves throughout, with the tablet held one-handed the way it is
carried on a walk:

| # | Check | Pass |
|---|---|---|
| 12 | The exit button can be pressed without shifting grip | ⬜ |
| 13 | The manual shutter can be pressed without shifting grip | ⬜ |
| 14 | Both buttons are findable against a blown-out preview — the dark plate is doing its job | ⬜ |
| 15 | A gloved press is *visibly* registered before anything happens | ⬜ |
| 16 | Neither is ever pressed by accident while turning | ⬜ |
| 17 | "Keep going" and "Finish here" are both hittable first time | ⬜ |
| 18 | "Start" on the pre-capture screen is hittable first time | ⬜ |
| 19 | Nothing else on the capture screen responds to touch | ⬜ |

Item 15 is new and worth a moment: through a glove there is no tactile
confirmation that a press landed, so the plate deepens and the glyph shrinks
while the finger is down. If that is not visible in sun, the press is a guess.

Item 16 is the one worth being slow about. A mis-tapped exit is why the exit
button asks before ending a session with positions in hand — but the right fix
for a button that gets brushed is to move it, not to add a second question.

## The whole thing, once

| # | Check | Pass |
|---|---|---|
| 20 | A full 29-position capture, outdoors, gloves on, start to finish | ⬜ |
| 21 | It came in under 90 seconds (S7) | ⬜ |
| 22 | The instruction line never showed two things, and never lagged the turn | ⬜ |
| 23 | Interrupting it — a phone call — lost nothing, and resume worked | ⬜ |
| 24 | Nothing on screen invited a look away from where you were standing | ⬜ |
| 25 | The metering sweep ring read as "keep turning for this long", not as a stall | ⬜ |

## Recording the result

Write the outcome into `phases/README.md`'s status table with the device and the
date, the way the device runs for Phases 06 and 07 are recorded. A checklist that
was run and not written down is a checklist that will be run again.
