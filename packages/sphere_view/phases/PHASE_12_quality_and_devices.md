# Phase 12 — Quality gates, failure UX, device matrix, performance

**Goal:** make it hold up on real devices, on a real site, and stay that way.

**Duration:** 5–7 days. **Depends on:** everything.

This is where a working prototype becomes something you can hand to a site team.
Most of the work is measurement and honesty rather than new features.

---

## 1. The device matrix

Every combination that ships must be tested end to end. Fill this in with the
actual fleet before starting:

| Device | OS | RAM | Tier | Bracketing | Intrinsics source | Gyro | Status |
|---|---|---|---|---|---|---|---|
| iPad (10th/11th gen) | | | | | | | |
| iPad Pro (M-series) | | | | | | | |
| Samsung Galaxy Tab A-series | | | | | | | |
| Samsung Galaxy Tab S-series | | | | | | | |
| rugged Android tablet (site model) | | | | | | | |
| mid-range Android phone (fallback) | | | | | | | |

Per device record: full session time (S7), stitch time (S8), peak RSS (S9), all
quality metrics (S1–S6) on a fixed reference scene, thermal state at completion,
and battery drain per station.

**The low-end rugged Android tablet is the device that matters.** iPads will be
fine. The 3 GB tablet with a `LEGACY` camera and possibly no gyroscope is what
determines whether the feature ships. Test it first, not last.

### Capability gating

Build a single capability probe that runs before the feature is offered:

```dart
enum SphereCapability { full, noBracketing, noDistortionModel, unsupportedNoGyro }
```

- **no gyroscope** → `unsupportedNoGyro`. Hide the feature entirely and say why.
  There is no useful degraded mode; the pipeline needs orientation.
- **`LEGACY` camera / no bracketing** → `noBracketing`, fall back to
  `ExposureStrategy.locked()`. Works, lower dynamic range, recorded in the report.
- **no distortion model** → `noDistortionModel`. Works; BA absorbs some of it.
  Expect slightly worse S1/S3.
- **< 3 GB RAM** → `low` tier, 4096×2048.

Gate at the *feature entry point*, not mid-flow. Discovering on site that your
tablet cannot do this is acceptable; discovering it after 25 captures is not.

---

## 2. Failure UX — plain language, specific cause

Every warning in `StitchReport.warnings` needs a human sentence. The mapping is
product work, not engineering work, and it is what stops the feature from feeling
unreliable.

| Report condition | What the user sees |
|---|---|
| `droppedPositionIndices` non-empty | "3 photos were too blurry to use. The panorama has soft patches near the ceiling." + retake option |
| high BA residual + AR translation (P14) | "You moved about 40 cm while capturing. Stand still and pivot in place for the best result." |
| `imu_only` frames | "Some surfaces had too little detail to align precisely (bare walls). Those areas may be slightly offset." |
| `coverageFraction < 0.95` | "You stopped at 18 of 29 photos. The panorama is missing the area above you." |
| `maxGainRatio > 1.15` | "Lighting changed during capture." *(also file a bug — AE lock should have prevented this)* |
| tier downgrade | "Reduced to standard resolution — this device ran low on memory." |
| thermal pause | "Paused — the tablet is hot. It will finish automatically once it cools." |
| S3 above target | "Some seams may be visible where objects were very close to you." |

Two rules:

1. **Name the cause and what to do differently.** "Stitching may be imperfect"
   teaches nothing and reads as a shrug.
2. **Never hide a compromise.** The architecture's core principle. A manager who
   discovers later that a panorama was silently degraded stops trusting all of
   them.

---

## 3. Performance work

Measure before optimising. Expected distribution for 29 positions at `mid` tier:

```
HDR fusion       25-45 s   ← the largest single cost
features (SIFT)   8-12 s
matching          3-6 s
bundle adjust     1-3 s
warp              5-8 s
gain comp         1-2 s
seam (graph-cut)  6-12 s
blend (strips)    8-15 s
encode            1-2 s
                 ─────────
                 58-105 s
```

The likely wins, in order of value:

1. **Downscale before HDR fusion** (Phase 05 §5). At `mid` tier a 12 MP frame is
   more resolution than a 6144-wide output can use. This can halve the largest
   stage at no measurable quality cost — verify with S6, then set per tier.
2. **Parallelise JPEG decode** across cores. 87 decodes is embarrassingly
   parallel and otherwise serialises the pipeline's start.
3. **Seam finding at reduced scale** (Phase 04 §4). Already specified; confirm the
   S3 cost is negligible.
4. **Feature detection in parallel** across frames — independent per frame,
   trivially parallel via `cv::parallel_for_`.
5. **Skip undistortion when the model is null** — no-op remap wastes a full pass
   over every frame.

Do **not** pursue GPU/OpenCL acceleration. Support is inconsistent across the
tablet fleet, and it would create a second code path that needs its own quality
validation — a large maintenance cost for a stitch that already fits in the
background queue.

### Battery and thermal

A station costs a 90 s capture plus a 60 s stitch. Measure drain per station and
publish the number; a site walk might be 30 stations. If drain is too high, the
background queue (Phase 10 §5) can wait for charging — the manager does not need
the panorama immediately.

---

## 4. Real-site validation

The synthetic harness proves the maths. Only a site proves the product. Capture a
reference set at a real location, covering:

| Scene | What it stresses |
|---|---|
| open shell, daylight | the easy case — must be excellent, no excuses |
| interior with window openings | HDR fusion (Phase 05) |
| bare drywall / poured slab corridor | low texture, SIFT thresholds, `imu_only` handling |
| scaffolding, exposed MEP overhead | fine repeated structure, zenith coverage |
| tight room, walls at ~1 m | parallax — the honest floor |
| active area with moving workers | ghost suppression (Phase 05 §3.3) |
| dusk / temporary lighting | noise, exposure, sharpness gate |

**Every capture becomes a permanent fixture.** A `CaptureBundle` is a directory
(Phase 01 §3.4), so add it to the replay corpus with its measured baseline. This is
how the quality gate stops being a synthetic-only claim, and it means a regression
six months from now is caught by CI rather than by a user.

Commit the bundles outside git (they are large) with a download script, and commit
the baselines.

---

## 5. Tests

- capability probe returns the right value for each synthetic capability set
- every `warnings` code maps to a user-facing string (assert exhaustively over the
  enum, so a new warning cannot ship without a message)
- device matrix: full session + stitch on every listed device, all metrics recorded
- real-site corpus runs in the quality gate with committed baselines
- stitch under thermal pressure pauses and resumes without corrupting output
- 3 GB device at `low` tier completes without OOM, 20 consecutive runs
- battery drain per station measured and documented
- 30-station session (simulated) does not exhaust storage; queue drains correctly

---

## 6. Documentation deliverables

- **README** — the real API, the pivot-don't-walk technique, device requirements,
  known limits (parallax, nadir)
- **`docs/CAPTURE_TECHNIQUE.md`** — one page a site team can actually read, with
  the pivot diagram. This has more effect on output quality than most of the
  algorithm work
- **`docs/TROUBLESHOOTING.md`** — symptom → cause → fix, keyed to warning codes
- **`docs/METRICS.md`** — what S1–S10 mean and how to read a `StitchReport`
- **`CHANGELOG.md`** — with the quality baselines each release was measured at

---

## Exit criteria

- [ ] **Device matrix filled in, all rows passing, low-end Android verified
      first** — harness done (`example/integration_test/device_matrix_test.dart`,
      `tools/device_matrix.dart`), matrix **0 of 6 rows**. Needs hardware; one run
      per device fills a row, and the merge tool exits non-zero until every row
      is in.
- [x] **Every warning code has a plain-language message (exhaustive test)** —
      `StitchWarningCode`, one message table, and three independent guards: an
      exhaustive `switch` (compile), `-Werror=switch` in C++ (build), and
      `warning_messages_test.dart` reading `sv_warnings.h` (test). Every sentence
      must name a cause and an action, asserted mechanically.
- [ ] **Real-site corpus in the quality gate with committed baselines** —
      mechanism done and wired in; **0 of 7 scenes captured**. The gate reports
      the corpus absent on every run rather than passing without it.
      `docs/FIELD_CORPUS.md` is the protocol.
- [ ] **S7 ≤ 90 s, S8 ≤ 60 s, S9 < 700 MB on every device** — unmeasured on
      hardware. Measured on the desktop host and in C++ at capture resolution
      (717 ms per 12 MP fused position → ~21 s for 29), which bounds the
      implementation but not the device.
- [ ] **S1–S6 met on the daylight-shell reference scene** — the scene does not
      exist yet. S1–S6 are measured every gate run on nine synthetic profiles, and
      the device matrix measures them per device on a fixed synthetic scene.
- [x] **Parallax floor measured and documented rather than hidden** —
      `tools/parallax_sweep.dart`; measured S1 is 0.68–0.75× §3's analytic
      prediction across a 30× range of `r/d`, published in `docs/METRICS.md` and
      turned into a table a site team can act on in
      `docs/CAPTURE_TECHNIQUE.md`.
- [x] **All four docs written** — `CAPTURE_TECHNIQUE.md`, `TROUBLESHOOTING.md`,
      `METRICS.md`, README, plus `DEVICE_MATRIX.md` and `FIELD_CORPUS.md`.
      `troubleshooting_doc_test.dart` keeps them from drifting.
- [ ] **20 consecutive `low`-tier runs without OOM** — the soak is written, with a
      leak check on the peak-memory trend (last five runs against the first five);
      it needs a device.

### Also found while doing this

- A single-exposure position was passed through at full size while the intrinsics
  were scaled by `frameScale` — a clean focal error on the whole of the fleet's
  low end, invisible to the harness. Fixed, with a 12 MP test that pins it.
- Architecture §3.3's translation signature was implemented, measured, and does
  **not** separate a walked capture from a pivoted one on synthetic fixtures. Not
  shipped as a warning; see `findings/translation_signature.md`.
- Four of §3's five performance wins were already implemented. The measurement
  found registration's own decode and SIFT loops serial instead; both are now
  parallel, bounded to four workers for memory reasons.
