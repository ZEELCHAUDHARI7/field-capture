# `tools/` — the synthetic harness and the offline runner

Both land in **Phase 02**, which comes *before* the stitcher on purpose: you
cannot tune a stitcher by walking to a construction site. Each real-world
iteration is thirty minutes and gives you an opinion ("looks a bit ghosty");
each synthetic one is seconds and gives you SSIM, loop closure and reprojection
RMS.

```
tools/
├── synth.dart                the forward renderer:  profile -> CaptureBundle
├── replay.dart               the offline runner:    bundle  -> metrics
├── ci/quality_gate.sh        every profile, one table, fail on regression
├── build_native.sh           OpenCV + sphere_stitch for THIS Mac, and the C++ tests
├── build_native_mobile.sh    OpenCV + sphere_stitch for Android and iOS
└── harness/                  the shared library all three are built from
```

The two build scripts share their OpenCV configuration with each other and with
Spike A — one `config.sh`, one module list, one set of flags — which is what
makes "the harness runs the same library the device runs" true rather than
aspirational. See [`docs/BUILDING_NATIVE.md`](../docs/BUILDING_NATIVE.md).

---

## `synth.dart`

```
dart run tools/synth.dart --list
dart run tools/synth.dart --profile nominal --out build/bundles/nominal
dart run tools/synth.dart --all --out build/bundles
```

Renders a `CaptureBundle` indistinguishable in structure from one a device
produces, by sampling a known ground truth through a known camera at known
poses — then writing down a deliberately *worse* version of what it knew. The
true rotation, the true focal and the true lens go into a separate
`ground_truth.json`; `bundle.json` gets an IMU pose a couple of degrees out, a
focal 3% off, and no distortion model at all, because that is what R2 found the
fleet actually reports.

The eleven steps of the phase doc's §1 are in `harness/frame_renderer.dart`,
which also explains the two places their order is deliberately not the doc's.

### Two deviations from the phase doc, and why

**There is no `--input ground_truth_8k.jpg`.** The ground truth is *generated*,
by `harness/scene.dart`, from a textured box room. That began as a way to keep
the repo small and turned out to matter more: the box has **analytic depth**, so
the parallax profiles get honest disparity from a genuinely displaced viewpoint
rather than from a hand-painted depth guess; and its texture richness is a
single dial, which is what lets `low_texture` differ from `nominal` in exactly
one property with nothing else moving. Adding `--input` back is a small change
and nothing here assumes it will not happen.

**The fixtures are committed as code, not as directories of images.** The phase
doc asks for each profile to be "a fixture directory committed to the repo".
Nine bundles is **401 MB** of PNG — 126 frames per profile at 480×640 — which is
not a repo anyone wants to clone. What is committed instead is everything needed
to recreate them exactly: the profile definitions, the procedural scene, and the
seeds. Every stochastic quantity traces back to a hash of the profile name and
the frame index, so:

```
dart run tools/synth.dart --profile low_texture --out /tmp/a
dart run tools/synth.dart --profile low_texture --out /tmp/b
diff -r /tmp/a /tmp/b        # byte-for-byte identical
```

This is *stronger* than committing the images, because a committed image can
drift from the generator that made it and nobody notices until the numbers move.

---

## `replay.dart`

```
dart run tools/replay.dart --bundle build/bundles/nominal
dart run tools/replay.dart --bundle build/bundles/nominal --backend reference-dart
dart run tools/replay.dart --bundle build/bundles/nominal --report json
```

Stitches a bundle and scores the result against the ground truth it was never
given. Prints the metrics table, and writes three images next to the bundle:

| file | what it is for |
|---|---|
| `stitched.png` | the panorama |
| `diff_amplified.png` | `abs(stitched − truth)` at 4×, seam paths overlaid |
| `labels.png` | which frame won each pixel |

The diff is the triage tool. Error concentrated **on the seam lines** is
registration or blending; error spread across each frame's **interior** is
intrinsics or distortion; error in broad flat **patches** is gain. Three
different bugs that all read as "the number went up" in the table.

### Backends

| `--backend` | what it is |
|---|---|
| `legacy-dart` *(default)* | the pre-Phase-02 stitcher: IMU-only poses, a hard-coded 52° HFOV, no undistortion, no gain compensation, feather averaging. **Expected to FAIL.** It is the control group |
| `reference-dart` | the same naive reprojection but with the bundle's real intrinsics. The geometric reference |
| `native` | the desktop build of `src/sphere_stitch` — the same library the device runs. Lands in Phases 03–05; until then it prints what to build and exits |

Two Dart backends rather than one because architecture §2 lists the wrong focal
and the averaging as *independent* defects, and a single control group leaves
them tangled. Running both separates them: on `pristine`, `legacy-dart` scores
PSNR 24.8 dB and `reference-dart` scores 43.1 dB — so 18 dB of the old
stitcher's failure was the hard-coded field of view, on its own.

---

## `ci/quality_gate.sh`

```
tools/ci/quality_gate.sh                        # check against the baselines
tools/ci/quality_gate.sh --skip-synth           # reuse the bundles on disk
tools/ci/quality_gate.sh --record --note "..."  # re-record them, deliberately
```

Renders every profile, replays each one, writes `build/quality_gate.md`, and
exits non-zero on a **regression against `phases/baselines/`** — which is not
the same thing as a profile failing its targets.

That distinction is the whole design. Every baseline recorded today is a `FAIL`,
because the stitcher that produced it is deliberately bad and the real one does
not exist yet. A gate that went red on that would be red every day until Phase 04
lands, and a gate that is always red is a gate nobody reads. So the baseline
records what each number *is*, the gate checks it has not got worse, and the
table prints the target verdict alongside so the gap stays visible.

Baselines are never updated automatically. Moving one is a deliberate act, in
its own commit, with the reason in the message — that is the only thing standing
between "we improved the stitcher" and "we got used to the number going up".

Whole run from scratch: **94 s** on a laptop, against the 300 s the exit criteria
allow.

---

## `harness/`

| file | what it holds |
|---|---|
| `float_image.dart` | the float raster everything passes around, with equirect wrap sampling |
| `rng.dart` | seeded randomness and value noise — the reason bundles are reproducible |
| `camera_model.dart` | Brown–Conrady both ways, and the equirect canvas |
| `scene.dart` | the procedural box room: image, true depth, EV offsets |
| `profiles.dart` | the nine profiles, each declaring only its own deviations |
| `frame_renderer.dart` | the eleven steps |
| `synth_runner.dart` | profile → bundle on disk, and the truth/lie split |
| `ground_truth.dart` | the answers, in a file the stitcher never sees |
| `stitcher_backend.dart` | what a stitcher is handed and must hand back |
| `legacy_dart_stitcher.dart` | the control group and the reference |
| `metrics.dart` | all eight metrics |
| `rotation_fit.dart` | Horn's method — how S2 and residual tilt are computed |
| `diff_image.dart` | the amplified diff and the label map |
| `report.dart` | the table, the markdown and the baseline JSON |

Nothing in `harness/` imports Flutter, and neither do the models it depends on
in `lib/src/api/models/`. That is not incidental: these are plain `dart run`
CLIs with no Flutter engine, and a model that reached for `dart:ui` would
quietly make the whole replay path — and with it the regression corpus —
impossible. `ImageSize` exists for exactly that reason.

---

## Phase 12 additions

```
tools/
├── perf_profile.dart      where the stitch minute goes, stage by stage
├── parallax_sweep.dart    the floor architecture §3 predicts, measured
├── device_matrix.dart     merge per-device rows into docs/DEVICE_MATRIX.md
├── corpus_manifest.dart   the committed half of the real-site corpus
└── fetch_corpus.sh        download and verify the corpus bundles
```

### `perf_profile.dart`

```
dart run tools/perf_profile.dart --tier mid --repeat 3
```

Phase 12 §3 opens with "measure before optimising", and this is the measurement.
Its most important column is `faithful?`: the corpus renders 480×640 frames
against a device's 12 MP, so every stage whose cost is *per input pixel* is
understated here — and worse than proportionally, because Phase 05 §5's downscale
never engages at 0.58× oversampling whereas at 12 MP it fires at 3.55× and changes
the shape of the stage. Those stages are measured at capture resolution by
`sphere_stitch_test` instead. What the corpus *does* measure faithfully is
everything driven by the output canvas and the position count, which is over half
the pipeline.

### `parallax_sweep.dart`

```
dart run tools/parallax_sweep.dart
```

Sweeps entrance-pupil offset against nearest-surface distance with **every other
error source switched off**, so the difference between rows is the parallax and
nothing else. That is what makes it a measurement rather than eight numbers: the
question is a difference, and a difference between two figures each carrying 9 px
of unrelated error measures nothing. The absolute values are therefore optimistic
and the *shape* is what transfers — which is the shape `docs/CAPTURE_TECHNIQUE.md`
is derived from.

Reports the prediction in two pixel units, deliberately. `S1` is in frame pixels
at registration scale and the panorama is in canvas pixels; on this fixture the
two happen to be within 20% of each other, so a single "predicted px" column would
invite the wrong comparison and make it look like a clean confirmation of the
model.

### The corpus tools

A real capture **cannot be regenerated**. A synthetic fixture traces back to a
profile name and a seed; a station in a building traces back to an afternoon. So
the checksum in `phases/corpus/manifest.json` is not bureaucracy — it is the only
way to know that the pixels a baseline was recorded against are the pixels being
scored. `fetch_corpus.sh` refuses a bundle that does not match, and refuses one
carrying a `ground_truth.json`, since a stray one would put a field capture on the
synthetic metrics path and score it against a reference that describes a different
building.

`dart run tools/corpus_manifest.dart --check` lists which of the seven scenes are
still owed.
