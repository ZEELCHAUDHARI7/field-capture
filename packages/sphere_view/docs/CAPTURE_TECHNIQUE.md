# How to shoot a good 360 on site

One page. If you read nothing else, read the box.

> **Pivot, don't walk.** Turn the tablet about its own camera lens — as if the
> lens were a nail through the tablet into the floor. Do not swing it round your
> body. Stand at least 1.5 m from the nearest wall. Hold still for a moment after
> each shot fires.

Everything below is why, and what to do in the awkward cases.

---

## The one thing that cannot be fixed later

A 360 works by taking photos from **one point** and joining them. The software
can correct a crooked tablet, uneven lighting, a wrong lens spec, and a shaky
hand. It cannot correct photos taken from *different points*, because there is no
single answer: line up the doorframe 1 m away and the wall 10 m behind it goes
double, and the other way round.

So the only thing that matters more than anything else is that the lens stays
still while you turn.

```
        GOOD — pivot on the lens              BAD — swing round your body
                                          
              ╔═══╗                                    ╔═══╗
              ║ ◉ ║  ← lens stays here                 ║ ◉ ║
              ╚═══╝                                    ╚═══╝
                │                                        ╱
             ↻  •  ↺   turn the tablet                 ╱   the lens travels
                │      around this point             ╱     30-50 cm
                                                   ●  ← you turn here
         lens moves < 3 cm                       lens moves 30-50 cm
```

The tablet turns; you turn *with* it, shuffling your feet, keeping the lens over
the same spot on the floor. It feels slightly awkward. It is the whole job.

**How much it costs to get this wrong** (measured, see `METRICS.md`):

| how you held it | lens travel | wall at 1 m | wall at 3 m |
|---|---|---|---|
| clamped on a monopod | ~0 cm | perfect | perfect |
| pivoted on the lens, carefully | 3 cm | slight softness at joins | invisible |
| pivoted roughly | 10 cm | visible doubling on near edges | slight softness |
| swung round your body | 25–40 cm | unusable near anything close | visible doubling |

A ~₹500 tablet clamp on a monopod makes this exactly zero and is worth carrying
for stations that matter — a defect you will be arguing about later, a handover
record, anything going into a report.

---

## The five habits

1. **Stand back.** 1.5 m from the nearest surface, more if you can. Parallax
   scales with `1 ÷ distance`, so stepping back a metre in a small room does more
   than any setting.
2. **Feet, not arms.** Arms in, elbows at your sides, tablet close to your chest.
   Turn by shuffling your feet. An outstretched arm *is* the 40 cm swing.
3. **Pause on each prompt.** The dot turns into a ring, the ring fills, the
   shutter fires. Half a second of stillness after it fires as well — the tablet
   takes three exposures in a burst, and moving between them costs the bright
   windows and the dark corners.
4. **Finish the ring.** Every prompt, including the ones pointing at the ceiling.
   A skipped position is not a small hole: it breaks the chain the software uses
   to work out where everything else was, and the damage spreads either side of
   it.
5. **Upright.** Do not lean or tilt the tablet as you turn. The app levels the
   horizon from the tablet's own sensors, and a lean it cannot see becomes a
   tilted panorama.

---

## Where to stand

- **Off to the side, not in the middle of the traffic.** Somebody walking through
  while you shoot appears once, twice, or cut in half. The software suppresses
  what it can inside one position; it cannot fix a worker who walks across three.
- **Not in a corner.** Two walls at 1 m is the hardest case there is. One step
  out is worth more than anything the software does.
- **Where there is something to look at.** Bare drywall and a poured slab give
  the software nothing to lock onto, and it falls back to the tablet's motion
  sensors, which are degrees-accurate rather than pixel-accurate. If the view is
  all blank wall, angle the station so a doorway, a service run, scaffolding or a
  marked line is in frame somewhere.
- **Facing the thing you care about.** The first photo sets the direction the
  panorama opens in.

---

## Lighting

- **Do not fight a window.** The app takes three exposures at each position and
  combines them, which handles about 12 stops — enough for a room with a window,
  not enough for a room with the sun in it. If the panorama must show what is
  outside the window, shoot at a time when the sun is not behind it.
- **Do not switch lights during a capture.** The exposure is locked for the whole
  station on purpose, so a light coming on halfway shows as a band.
- **Dusk and temporary lighting work**, and they are noisier. Hold steadier: the
  shutter is slower, so the same wobble smears further.

---

## When the tablet says something

Read it — every message names what happened and what to do differently, and
`TROUBLESHOOTING.md` has the full list keyed to what you saw. The two you will
meet most:

- *"…too little detail to align precisely (bare walls)"* — the surfaces were
  blank. Re-shoot with some structure in view, or accept it and note that those
  directions are approximate.
- *"You stopped at 18 of 29 photos"* — the panorama is real where you shot and
  filled in where you did not. Resume the station and finish the prompts.

If a tablet tells you it cannot do this at all, it is missing a gyroscope. No
setting fixes that; use a different tablet.

---

## The 30-second version, for a toolbox talk

> Stand back a metre and a half. Arms in. Turn the tablet on its own lens, feet
> shuffling, not arm swinging. Pause when it asks, and half a second after the
> click. Do every prompt including the ceiling. Don't lean.

---

*Why any of this is true, with the measurements: `docs/METRICS.md` and
`phases/00_ARCHITECTURE.md` §3.*
