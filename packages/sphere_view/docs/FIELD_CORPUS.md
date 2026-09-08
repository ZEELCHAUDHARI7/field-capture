# Capturing the real-site corpus

Phase 12 §4. Seven scenes, one site visit, and from then on **every regression is
caught by CI rather than by a user**.

This is the document to have in hand on the day. It takes a morning.

---

## Why it is worth a site visit

The synthetic harness proves the maths. It renders a procedural room, samples it
through a known camera at known poses, and scores the stitch against the answers
— which is how the stitcher got from 35–85 px of misregistration to 0.17 px on
its control profile without anybody leaving a desk.

What it cannot prove is the product. Real surfaces are not fractal noise, real
windows are 14 stops rather than 12, real workers walk through the sphere, and a
real tablet's AE lock is not quite a lock. Until a real capture is in the gate,
"the stitcher meets its targets" is a claim about a room that does not exist.

And there is a second reason, which is the one that pays for the morning:
**every capture becomes a permanent fixture.** A bundle is a self-describing
directory (architecture §6.6), so a station shot once is replayable forever. Six
months from now, somebody changing the seam finder gets told by CI that
`tight_room_1m` got worse — rather than getting told by a site lead, three weeks
later, about a panorama they cannot reproduce.

---

## Before you go

- A tablet from the fleet that **passes the capability probe**. Ideally the
  low-end rugged Android, because a corpus captured on an iPad Pro is a corpus
  that flatters every device below it.
- A tablet clamp on a monopod. Two scenes need it.
- 4 GB free on the device. Seven stations at ~200 MB each.
- A tape measure, for the one scene defined by a distance.
- `docs/CAPTURE_TECHNIQUE.md`, read once.

Shoot every scene with the app's own prompts, completing every position, unless
the scene says otherwise. A partial capture is a legitimate panorama but it is not
a controlled fixture.

---

## The seven scenes

Names are exact: they are the directory names the harness reads, and each one
selects that scene's thresholds in `tools/harness/field_metrics.dart`. A bundle in
a directory named anything else is refused rather than scored against defaults
that describe no scene in particular.

### 1. `daylight_shell` — the easy case

**Stresses:** nothing. This is the one with no excuses.

Open structural shell, daylight, nothing closer than 4 m in any direction.
**Clamp it on the monopod.** This is the reference scene the device matrix quotes
S1–S6 on, and the one to re-shoot identically if it is ever lost, so favour a
location that will still exist next year — a permanent frame, a stair core, a
finished façade.

Its thresholds are the tightest in the corpus. §4's words are "must be excellent,
no excuses".

### 2. `window_interior` — HDR fusion

**Stresses:** Phase 05's whole bracket path. 12+ stops from a shadowed corner to
the sky.

An interior with unshaded window openings. **Shoot when the sun is not behind
them** — with the sun in frame the scene exceeds what three exposures can hold and
the fixture measures physics rather than code. Check the report afterwards: it
should say every position fused. A `brackets_rejected` warning means the tablet
moved during the bursts, and the fixture is about fusion rather than about
steadiness.

### 3. `bare_drywall_corridor` — low texture

**Stresses:** the SIFT thresholds and the `imu_only` fallback.

A corridor of taped drywall and poured slab, with no fittings, no signage and no
services in view. Find the blankest length of it you can.

**This scene is expected to fail its way, not to succeed.** The criterion is that
it degrades honestly: some frames fall back to their IMU prior, the report says
so, and a panorama comes out anyway. If it registers cleanly, the corridor was not
bare enough and the fixture is not testing the thing it exists for.

### 4. `mep_overhead` — repeated structure

**Stresses:** fine repeated detail, and zenith coverage.

Under exposed services or scaffolding, with the repetition overhead: identical
duct hangers, a run of identical brackets, a grid of scaffold tube. **Shoot every
zenith prompt** — the point is the direction where the matcher can lock onto the
wrong copy of an identical object, and that direction is up.

### 5. `tight_room_1m` — the parallax floor, and a question worth settling

**Stresses:** the physical limit nothing removes.

A room where the nearest wall is about **1 m** away — measure it. Shoot it
**twice**, from the same station:

- `tight_room_1m` — clamped on the monopod, so the lens travel is ~0.
- `tight_room_1m_handheld` — handheld, pivoting as carefully as a real operator
  manages.

The pair is the only measurement of the parallax floor on **real texture**; the
synthetic sweep in `docs/METRICS.md` is on fractal noise, which is
scale-invariant and therefore the one thing that cannot answer this.

It is also the experiment that settles an open question. Architecture §3.3 claims
the correlation between residual and feature scale is a free translation
detector — "you walked instead of pivoting". Implemented and measured, it does not
separate on synthetic fixtures, plausibly *because* the fixture is
scale-invariant (`phases/findings/translation_signature.md`). This pair, on block
courses and formwork, is one afternoon's evidence either way. Compare
`registration.residual_scale_correlation` between the two bundles.

### 6. `active_workers` — moving subjects

**Stresses:** ghost suppression, and the limit past it.

An area with people working in it. **Do not ask them to stand still.** The point
is a worker who walks through the sphere and appears once, twice or half-cut.
Ghost suppression limits the damage inside one bracket; nothing fixes a person who
moves between positions, and the criterion is that the damage stays local rather
than smearing the panorama.

Ask permission, and do not photograph anybody who would rather not be.

### 7. `dusk_temporary_light` — noise and the sharpness gate

**Stresses:** read noise, exposure, and the blur rejection.

Dusk, or festoon and task lighting only. The shutter is slow here, so expect the
sharpness gate to reject positions — that is the scene working as intended, and
`positions_dropped` in the report is data rather than a fault. Hold steadier than
usual and use the retake prompts.

---

## After the visit

```sh
# 1. pull each bundle off the device (Android)
adb exec-out run-as com.asite.sphere_view_example \
  tar c -C files/panoramas daylight_shell > corpus/daylight_shell.tar
gzip corpus/daylight_shell.tar

# 2. sanity-check that it replays at all, and read the numbers
dart run tools/replay.dart --bundle corpus/daylight_shell --backend native

# 3. record its checksum, so a download can be proved to be this capture
dart run tools/corpus_manifest.dart --add corpus/daylight_shell.tar.gz

# 4. record the baseline it will be judged against from now on
tools/ci/quality_gate.sh --record \
  --note "field corpus captured 2026-xx-xx at <site>, <tablet>"

# 5. upload the archives to wherever SPHERE_VIEW_CORPUS_URL points, and commit
#    the manifest and the baselines — but NOT the archives
```

Two rules about step 4, both inherited from the synthetic side and both the
reason the gate is worth having:

- **Look at each panorama before recording its baseline.** A baseline records
  where the pipeline *is*, including where it is bad — that is the design — but
  recording a number nobody looked at bakes in a defect as the expected result.
  A recorded FAIL with a reason attached is fine. A recorded FAIL nobody
  understands is a regression that already happened.
- **The note is not optional.** Which site, which tablet, what the weather was
  doing. In a year the numbers will be questioned and nothing else will answer.

---

## What "in the gate" then means

`tools/ci/quality_gate.sh` replays the corpus alongside the nine synthetic
profiles and compares against `phases/baselines/field/`. Three things about the
field half differ, and each is deliberate:

- **Four criteria are not measured.** S1, S2, S6 and the residual tilt are all
  defined against a reference, and there is none. The stitcher's own figures
  appear as `s1_reported`, `s2_reported` and `tilt_reported`, labelled
  "(self)" — a bound on *movement*, not a statement of accuracy. Bundle
  adjustment's residual measures self-consistency, and a solution can be
  smoothly, confidently, self-consistently wrong.
- **S3 is a different measurement.** The synthetic seam score subtracts the
  gradient the ground truth has at the same place, so a real edge in the scene
  cannot be scored as a seam. Reference-free, it cannot, so `s3_field` is noisier
  and biased upward — and carries its own id and its own baseline, because
  comparing it against `s3` would be comparing two different things.
- **An absent corpus is reported, not skipped.** On a fresh clone the bundles are
  not there, and the gate says so on every run, in its output and in its
  markdown. A regression detector with no fixtures catches nothing, and the way
  that failure happens is silence.
