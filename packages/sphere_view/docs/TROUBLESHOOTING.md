# Troubleshooting

Symptom → cause → fix. Two ways in: by **what you can see** if you are looking at
a bad panorama, or by **warning code** if you have a report in front of you.

Every warning the pipeline can raise appears in the code table at the bottom.
`test/troubleshooting_doc_test.dart` fails if a code is added without a row here,
so the table is complete by construction rather than by diligence.

---

## By what you can see

### Edges are doubled or ghosted, worst on nearby things

The camera moved between shots instead of pivoting. This is parallax, it is the
one thing no stitcher can fix, and it is by far the most common cause of a
disappointing panorama.

**Fix:** `docs/CAPTURE_TECHNIQUE.md`. Turn the tablet about its own lens, stand
1.5 m or more from the nearest surface, and use a clamp on a monopod for stations
that matter. The measured cost of getting this wrong is in `docs/METRICS.md` — at
1 m, 10 cm of lens travel is 5.7° of disparity, which is ~97 px of doubling on a
6144-wide panorama.

Codes you may see with it: `reprojection_above_target`,
`inconsistent_inliers_discarded`.

### A band of different brightness across a wall or the sky

Either the exposure lock did not hold (a camera fault, `gain_ratio_too_large`) or
the lighting genuinely changed during the capture — someone hit a light switch,
or a cloud moved (`gain_ratio_above_target`).

**Fix:** nothing on site for the first, which is worth reporting with the tablet's
model name. For the second, do not switch lights during a station.

### Soft or blurred patches, sharp elsewhere

Those positions were shot while still moving, and the sharpness gate rejected them
(`positions_dropped`), or the bracket could not be combined
(`bracket_refused`, `brackets_rejected`).

**Fix:** pause on each prompt until the shutter fires, and half a second after.
Re-shoot the station, or use the review screen's retake for the named positions.

### Whole areas look approximately right but do not line up

Those directions had too little detail to match — bare drywall, a poured slab, a
plain ceiling — so they are positioned from the tablet's motion sensors instead
(`imu_only_frames`, `mostly_imu_only`, `bundle_adjustment_partial_failure`).

**Fix:** shoot from a spot that has some structure in view: a doorway, a service
run, scaffolding, a marked line. This is a property of the scene, not of the
software, and it is the case the pipeline degrades on rather than fails on.

### Windows are pure white, or shadows pure black

Either the tablet cannot bracket at all (`bracketing_unavailable` — a `LEGACY`
camera, no fix on that hardware), or the scene exceeds ~12 stops even with three
exposures.

**Fix:** shoot when the sun is not directly behind the window. If the tablet
cannot bracket, the panorama is still geometrically correct and this limit should
be recorded against the station rather than re-shot repeatedly.

### A visible vertical join at the back of the panorama

The ring did not close. Usually the field-of-view estimate on this device
(`loop_closure_above_target`), sometimes a capture that was stopped before the
ring completed (`wrap_pad_unreached`).

**Fix:** for the second, finish every prompt. For the first, nothing on site; it
is a device characteristic and the residual is reported.

### The horizon is tilted

The tablet was leaned or tilted while turning, beyond what levelling against
gravity could recover (`residual_tilt_above_target`).

**Fix:** hold the tablet upright; turn with your feet rather than by rolling your
wrists.

### Part of the sphere is smeared or obviously invented

That direction was never photographed and was filled in from its surroundings
(`coverage_incomplete`, `positions_not_captured`).

**Fix:** resume the station and finish the prompts. The fill is deliberately
smooth rather than fake detail, so it is honest but it is not evidence.

### The panorama is smaller than expected

The device was short of memory, before the stitch (`tier_downgraded_before_start`)
or during it (`tier_downgraded_after_oom`), or it would not report its memory at
all (`memory_probe_unavailable`).

**Fix:** close other apps before stitching. On a 3 GB tablet the `low` tier is
normal and correct, not a fault.

### It opens as a flat wide photo in other apps

The 360 metadata could not be written (`metadata_not_written`).

**Fix:** re-save from the app. If it recurs, report it — the image is fine, the
tag is not.

### It opens facing the wrong way

The heading came from the compass, which steel and rebar bend by tens of degrees
indoors (`heading_from_magnetometer`).

**Fix:** capture from a marked point on the plan, so the heading comes from the
drawing rather than from the magnetometer.

### The tablet paused mid-stitch

It got too hot (`thermal_pause`). Nothing is lost; it resumes on its own.

**Fix:** out of direct sun, off charge. If it happens at every station, the walk
is too fast for the hardware — the background queue will catch up while you move.

### The feature is not offered at all

The tablet has no gyroscope. There is no degraded mode: without one there is no
way to know which way the tablet is pointing.

**Fix:** use a different tablet. The requirement is in the README's device
requirements.

---

## By warning code

| code | what it means | what to do |
|---|---|---|
| `frames_downscaled` | Frames carried more resolution than the output can hold, so they were decoded smaller. | Nothing. This is the pipeline being fast on purpose. |
| `bracket_refused` | One position's three exposures did not line up; the middle one was used alone. | Hold still longer after the shutter. Re-shoot that position if the window there matters. |
| `bracket_compromised` | One position was combined with a compromise — a dropped exposure, a substituted ratio, a suppressed ghost. | Pause half a second longer before moving on. |
| `brackets_rejected` | Several positions fell back to one exposure. | As above, at more positions; if it is most of them, the tablet is moving during the burst. |
| `exposure_metadata_disagrees` | The camera reported exposures it did not take. | Report with the model name. The panorama used the measured values and is correct. |
| `no_distortion_model` | The device publishes no lens distortion. | Nothing on this device. Expect slightly less exact joins near frame edges. |
| `distortion_lut_unfittable` | The device published lens data the stitcher could not use. | Report with the model name — one for the developers. |
| `distortion_estimated` | The device publishes no lens data, so the lens was measured from the photographs. | Nothing. This is better than the alternative — the joins are more exact than they would be without it. |
| `weak_intrinsics` | No measured lens calibration; the field of view was derived from the physical spec. | Nothing on this device. |
| `imu_only_frames` | Some positions had too little detail to align and are placed from motion sensors. | Include some structure in frame. |
| `mostly_imu_only` | Most of the capture is placed from motion sensors. | Re-shoot from a station with structure in view; treat this one as approximate. |
| `nothing_registered` | No photo could be matched to any other. | Re-shoot standing still, pivoting on the spot, with something detailed in view. |
| `match_graph_split` | The photos formed separate groups that could not be joined to each other. | Complete every prompt; a coverage gap is the usual cause. |
| `bundle_adjustment_partial_failure` | One group could not be solved precisely and kept its sensor position. | Re-shoot that part of the ring, pausing at each prompt. |
| `bundle_adjustment_failed` | The precise alignment step failed everywhere. | Re-shoot pivoting on the spot with more overlap. Treat the output as a record, not a measurement. |
| `imu_only_dominates_residual` | The headline accuracy figure is dragged down by the positions that never matched. | Check the unmatched directions before measuring off the panorama. |
| `inconsistent_inliers_discarded` | Matches disagreed with the overall solution — repeated structure aliasing. | Check joins near repetitive surfaces; the accuracy figure is optimistic there. |
| `focal_refinement_rejected` | The stitcher tried to change the lens's field of view by more than 20% and was overruled — that is the solver trading focal length against camera angle, not a correction. | Nothing: the tablet's own figure was used and the panorama is at the right scale. This is the stitcher catching itself. |
| `solution_collapsed` | The alignment placed every photo into a small part of the scene when the tablet swept much more, so it had agreed with itself rather than with reality. Discarded for the motion sensors. | Re-shoot with more overlap, pausing at each prompt. Joins will be soft until you do. |
| `frame_warped_off_canvas` | A photo ended up outside the panorama entirely. | Report it — this should be impossible. |
| `wrap_pad_unreached` | Nothing crossed the back of the panorama, so it does not close. | Complete the ring, unless the capture was deliberately partial. |
| `gain_compensation_failed` | Brightness could not be evened out between photos. | Report it. Expect banding on wide surfaces. |
| `gain_ratio_too_large` | Photos differ in brightness by more than lens shading explains — the exposure lock did not hold. | Report with the model name; this is a camera fault. |
| `seam_finding_failed` | The stitcher could not choose where to cut and blended the whole overlap. | Report it. Nearby objects may look doubled. |
| `strip_blend_mismatch` | The memory-saving strip blend did not join exactly. | Report it — the strip padding is too small for the band count. |
| `nothing_covered` | No usable photos reached the panorama. | Re-shoot; nothing was recoverable. |
| `preview_not_written` | The small preview could not be saved. | Nothing; the panorama is unaffected. |
| `debug_map_not_written` | A diagnostic file could not be written. | Nothing; it only makes a later investigation harder. |
| `plan_cannot_register` | The plan's overlap was below what feature matching needs; refused before shooting. | Re-shoot at the app's own prompts, which produce the right overlap. |
| `registration_only_run` | A diagnostic run that stopped after alignment. | Not a panorama to keep. |
| `reprojection_above_target` | S1: the photos line up to more than 1 px. | Stand further back; pivot on the lens. |
| `loop_closure_above_target` | S2: the ring did not close within 0.25°. | Nothing on site — a device field-of-view characteristic. |
| `gain_ratio_above_target` | S4: brightness varies more than 3% between photos. | Do not switch lights during a station. |
| `residual_tilt_above_target` | The horizon is off level. | Hold the tablet upright while turning. |
| `coverage_incomplete` | S5: less than the whole sphere is real photography. | Complete every prompt. |
| `positions_dropped` | Photos too blurry or too poorly overlapped to use at all. | Retake those positions from the review screen. |
| `tier_downgraded_before_start` | The output was made smaller because the app was short of memory. | Close other apps before stitching. |
| `tier_downgraded_after_oom` | The stitch ran out of memory and was retried one size down. | Close other apps before stitching. |
| `memory_probe_unavailable` | The device would not say how much memory it has. | Report with the model name. The smallest size was used to be safe. |
| `metadata_not_written` | The 360 tag could not be written. | Re-save from the app. |
| `heading_from_magnetometer` | North came from the compass, which is unreliable indoors. | Capture from a marked point on the plan. |
| `thermal_pause` | Too hot to keep stitching; it resumes by itself. | Out of direct sun, off charge. |
| `bracketing_unavailable` | The camera cannot take three exposures. | No fix on this hardware. Geometry is unaffected. |
| `positions_not_captured` | Fewer photos were taken than the plan called for. | Resume the station and finish the prompts. |
| `unrecognised` | A warning this build of the app does not know, from a newer stitching library. | Report it — the app and its native library are out of step. |

---

## For developers

- The user-facing sentence for every code is in
  `lib/src/api/models/stitch_warning.dart`, in one `switch`. Adding a code
  without a sentence does not compile; adding one without a row here fails
  `troubleshooting_doc_test.dart`.
- The technical detail the detecting stage wrote travels alongside as
  `StitchWarning.detail` — that is the line to quote in a bug report.
- `StitchReport` also carries per-stage diagnostics the typed model does not
  model (`registration`, `compositing`, `hdr` blocks in the raw JSON). Those are
  where a "why is S1 9 px" question gets answered: candidate pairs, inlier
  counts, `imu_only_frames`, seam scale, strip count.
- A bundle is a directory (`phases/00_ARCHITECTURE.md` §6.6). To reproduce a
  field failure, copy it off the device and
  `dart run tools/replay.dart --bundle <dir> --backend native`.
