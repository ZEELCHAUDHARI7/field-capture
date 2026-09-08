# sphere_view — implementation plan

Capture a true 360°×180° spherical panorama from a handheld phone or tablet, and
stitch it into one equirectangular image good enough that a construction manager
can read a defect off it.

**Driving use case:** a construction site walk. The manager draws a walking path on
a plan and captures a 360 at each waypoint. That is what sets the requirements —
main-camera-only tablets, high-dynamic-range interiors, low-texture surfaces, and a
manager who cannot stand still for long.

**Scope:** a standalone, reusable Flutter package. Host-app integration is
deliberately out of scope; the example app is the demo, and `docs/INTEGRATION.md`
(Phase 13) is what a consuming app reads.

---

## Read in this order

| # | Document | What it is |
|---|---|---|
| 1 | [00_ARCHITECTURE.md](00_ARCHITECTURE.md) | Success criteria, why the current code cannot work, the full pipeline, key decisions, memory budget. **Start here.** |
| 2 | [01_MATH_AND_CONVENTIONS.md](01_MATH_AND_CONVENTIONS.md) | **Normative.** Coordinate frames, the OpenCV conversion, equirect mapping, intrinsics, shot-plan geometry. Every phase cites this. |
| 3 | [RESEARCH_QUESTIONS.md](RESEARCH_QUESTIONS.md) | Five open questions with ready-to-paste deep-research prompts. R1 blocks the native work. |
| 4 | The phase documents below | One per session-sized chunk of work |
| 5 | [../PROMPTS.md](../PROMPTS.md) | The prompts to paste into a fresh Opus 5 session, one per phase |

---

## Phases

| # | Phase | Days | Depends on | Why it matters |
|---|---|---|---|---|
| 00 | [Spikes](PHASE_00_spikes.md) | 2–4 | — | Three things that could invalidate the architecture. Do first. |
| 01 | [Skeleton & data model](PHASE_01_skeleton.md) | 2–3 | — | The type surface everything else is built on |
| 02 | [Synthetic rig & replay](PHASE_02_synthetic_rig.md) | 4–5 | 01 | **Highest leverage in the project.** Iterate the stitcher in seconds, with numbers |
| 03 | [Native registration](PHASE_03_registration.md) | 5–7 | 00, 01, 02 | Decides whether the pano *can* be seamless |
| 04 | [Native compositing](PHASE_04_compositing.md) | 6–8 | 02, 03 | Decides whether it *looks* seamless. Wrap seam + memory ceiling live here |
| 05 | [HDR exposure fusion](PHASE_05_hdr_fusion.md) | 3–4 | 00, 02, 03 | Dark interiors with blown windows — the actual site condition. **Done** |
| 06 | [Platform camera](PHASE_06_platform_camera.md) | 7–9 | 00, 01 | Real intrinsics, hard AE/AWB/AF lock, bracketed burst, frame timestamps |
| 07 | [Platform pose](PHASE_07_platform_pose.md) | 3–4 | 01, 06 | Small phase, outsized consequences: shutter-time pose |
| 08 | [Capture orchestration](PHASE_08_capture_orchestration.md) | 5–6 | 01, 06, 07 | Plan, prove coverage, guide, decide when to fire |
| 09 | [Capture UI](PHASE_09_capture_ui.md) | 3–4 | 08 | Six elements. Put the dot in the ring |
| 10 | [Isolate pipeline](PHASE_10_isolate_pipeline.md) | 3–4 | 03, 04, 05 | 60 s stitch without dropping a UI frame; real cancellation |
| 11 | [Metadata & viewer](PHASE_11_metadata_and_viewer.md) | 3–4 | 04, 10 | XMP GPano — makes the output useful outside our app |
| 12 | [Quality & devices](PHASE_12_quality_and_devices.md) | 5–7 | all | Where a prototype becomes shippable |
| 13 | [Example demo app](PHASE_13_example_demo.md) | 2–3 | all | Demonstrates the package end to end; release readiness |

**Total: roughly 51–66 working days.**

Scope was cut deliberately to build faster:

- **App integration is out.** `sphere_view` is a standalone package; the example app
  is the demo. Integration knowledge lives in `docs/INTEGRATION.md` (Phase 13 §3)
  rather than in code.
- **The AR pose source is out.** Its only unique value was walk detection, and
  bundle adjustment already handles rotation accuracy. If walk detection is wanted
  later, the cheap route is optical-flow divergence on the preview stream plus the
  post-hoc BA residual signature — no AR dependency, works on every device.

### Parallelism

```
00 spikes ─────────┐
                   ├──► 03 registration ──► 04 compositing ──┐
01 skeleton ──┬────┤                                          ├──► 10 isolate ──► 11 meta+viewer ──┐
              │    └──► 05 HDR fusion ────────────────────────┘                                     ├──► 12 quality ──► 13 demo
              └──► 02 synthetic rig                                                                 │
              └──► 06 camera ──► 07 pose ──► 08 orchestration ──► 09 UI ──────────────────────────┘
```

The native track (00/03/04/05) and the platform track (06/07/08/09) are largely
independent after Phase 01, joined by Phase 02's harness. If two people are
working, split there.

### The fastest sane order

Get the **stitcher proven on desktop before touching the camera.** Phases 01 → 02 →
03 → 04 need no device and no camera plugin — the synthetic harness feeds them. That
way you know the pipeline hits its quality targets *before* spending 9 days on
Phase 06. If the stitcher cannot hit them, you would much rather find out in week 3
than week 8.

Run Phase 00 Spike A (the OpenCV build) in parallel from day one — it is the
long-lead item, and it is infrastructure work that can churn while Dart gets written.

---

## Decision log

Decisions already made, with where they are justified. Revisit deliberately, not
by drift.

| Decision | Rationale |
|---|---|
| **Native OpenCV `detail::` pipeline**, not pure Dart, not high-level `cv::Stitcher` | Only path to seam-free output. `detail::` because the high-level API cannot take IMU priors, fails all-or-nothing, and cannot cleanly emit full 360×180. Arch §2, §5 |
| **IMU is a prior, not a measurement** | Current code trusts it (35–85 px error); stock OpenCV ignores it (fails on bare drywall). Use it to gate matching, seed BA, and fix gravity. Arch §6.1 |
| **Platform AHRS** (`GAME_ROTATION_VECTOR` / `CMDeviceMotion`), not the hand-rolled filter, not the magnetometer | OS Kalman filters correct gyro bias and scale; no magnetometer means indoor rebar doesn't break it. Phase 07 §1 |
| **The platform→world conversion is settled by its determinant, and only by that** | Every valid `A` differs from every other by a rotation about the vertical — which the session-start yaw datum absorbs exactly — or by a reflection, which mirrors the panorama. So there is exactly one thing to prove, and the §5 test proves it. Phase 07 §2 |
| **Main camera only**, plan derived from **measured** intrinsics | iPads and most Android tablets have only a main camera. The current hard-coded 52° HFOV is wrong on nearly every device. Math §8 |
| **3-shot HDR bracket** via hardware burst, **Mertens fusion** | Site interiors span 12–16 EV. Mertens needs no camera-response calibration and outputs LDR directly. Phase 05 §2 |
| **Mertens `exposure_weight` is 0.35, not 0** | §2 predicted the well-exposedness term would only flatten and said to measure. Measured, it is also how deep shadows become legible: at 0 the shadow region scores *worse than the single-exposure control*, and S1 collapses to 31 px because read noise has excellent contrast. Phase 05, `HdrFuseOptions` |
| **Bounded correlation search + ECC for alignment; no `AlignMTB`** | ECC's basin is a couple of pixels and §3.2's limit is 45 px at 12 MP, so ECC alone cannot reach it. Measured worst case 0.07 px against MTB's 2.2 px, and 1.5 px against MTB's 89 px on real brackets. Phase 05 §3.1 |
| **Alignment on log-luminance, not gradient magnitude** | On the log image an exposure change is a constant offset, which both estimators are exactly invariant to; the gradient throws away every flat-but-shaded region and concentrates on clipping boundaries, which move between exposures. Phase 05 §3.1 |
| **Kabsch levelling against measured gravity**, never `waveCorrect` | BA has a 3-DOF gauge freedom; we have measured gravity, so fix it with data not a heuristic. Math §7 |
| **Padded strip blending** + **256 px wrap padding** | 8192×4096 multi-band needs ~600 MB; strips cut that by N with bit-identical output. Wrap padding is the only thing that closes the ±180° seam. Arch §7, Phase 04 §2, §5 |
| **Progress via shared memory**, not `NativeCallable` | No isolate-lifetime hazards; cancellation actually works. Arch §6.3 |
| **Graph-cut seam finding runs pair by pair, not in one `find` call** | One call is 542 ms with no poll point, which blows the 500 ms cancel bound on the *fast* machine. The decomposition reproduces `PairwiseSeamFinder::run` exactly and is asserted bit-identical; the longest uninterruptible unit drops to 25 ms. Phase 10 §3 |
| **JSON at the FFI boundary** | ABI doesn't break every time a field is added. Arch §6.4 |
| **Output size is a device tier**, not a user setting | Memory-bound, not optics-bound. Deterministic per device. Arch §6.5 |
| **Synthetic harness before the stitcher** | You cannot tune a stitcher by walking to a site. Phase 02 |
| **`CaptureBundle` is a self-describing directory** | Offline replay, permanent regression tests, resume-after-crash — all fall out of this. Arch §6.6 |
| **Portrait-locked capture** | The plan is valid for one intrinsics/orientation pair; portrait also gives larger VFOV → fewer rings. Phase 09 §4 |
| **Background stitch queue** | The manager keeps walking. 30 stations × 60 s of standing still is unacceptable. Phase 10 §5 |
| **Never silently degrade** | Every compromise lands in `StitchReport` and gets a plain-language message. Arch §8, Phase 12 §2 |
| **S5 is S5a/b/c — pairwise overlap, not 95% double coverage** | The double-covered fraction is `ω/(1−ω)`, so 95% *is* ω = 0.487, against a 0.33 default. Matching needs pairwise overlap; seams and blending need band width, not sphere-wide redundancy. Corrected after Phase 02 measured it. Math §8 |
| **The harness plans what the device plans** (`ω = 0.33`) | Validating at 45% overlap and shipping at 33% would flatter every registration and seam metric, and the gap would only surface on a real site. `tools/harness/profiles.dart` |
| **Standalone package, no app dependency** | Keeps it testable by the harness alone; the example app is the demo. Phase 13 |
| **No AR pose source** | Its only unique value was walk detection, not accuracy — BA already handles accuracy. Dropped for speed |

### Settled by research (R1–R3, `findings/`)

| Decision | Evidence |
|---|---|
| **Build OpenCV from source**, minimal module list, own `extern "C"` FFI shim | R1 + Spike A (measured). Every off-the-shelf channel fails: prebuilts are all-module "world" builds, CocoaPods died at 4.3.0, no official SPM, and `dartcv4` exposes **zero** `cv::detail::` and cannot force a 360×180 canvas — an API gap, not a size gap |
| Module list: `core, imgproc, imgcodecs, flann, features2d, calib3d, photo, video, stitching` | R1. `videoio`, `objdetect`, `dnn`, `gapi`, `highgui`, `ml` confirmed excludable |
| **Graph-cut needs no external max-flow library** | R1. OpenCV ships its own `GCGraph`. This closed the project's largest risk — the "reimplement the algorithms" fallback is gone |
| Licensing clean, Apache 2.0 throughout | R1. SIFT is patent-clear in main-repo `features2d`; the seam finder is an in-house Apache-2.0 reimplementation, not the GPL reference |
| **Android `LENS_DISTORTION` → OpenCV is a pure reorder** `{κ1,κ2,κ4,κ5,κ3}` | R2, against AOSP verbatim. It genuinely *is* Brown–Conrady; no value transform |
| **`videoFieldOfView` is horizontal** | R2 |
| **Intrinsics quality is a gradient, not a constant** | R2. Calibrated intrinsics need a multi-camera device — excludes base iPad / Air / mini outright. Registration must tolerate the whole range. Phase 03 §2 |
| Camera2, not CameraX; and **no native HDR shortcut** | R3. CameraX 1.5 still has no bracketing; `ExtensionMode.HDR` returns one pre-fused frame with no per-frame control |
| **The 600 ms burst budget is unverified by anything** | R3. No source anywhere publishes a measured number. Highest-priority Phase 00 measurement — harness built, **still needs a device run** |

---

## The honest limits

Stated up front so nobody spends a week trying to code around physics:

1. **Parallax.** Handheld, the lens traces a circle instead of staying at one
   point. For a wall at 1 m with a 10 cm lens offset, that is ~97 px of
   irreducible disparity at 6144 wide. Graph-cut *hides* it; nothing removes it.
   Mitigation is capture technique — pivot about the lens, stand ≥1.5 m off, or
   clamp the tablet to a monopod. Arch §3.
2. **Nadir.** Points at the user's feet. Off by default; push–pull filled or
   badge-patched. Phase 04 §6.
3. **Moving subjects.** A worker who walks through the sphere appears once, twice,
   or half-cut. Ghost suppression limits the damage within a bracket; nothing fixes
   it across positions.
4. **Devices without a gyroscope** cannot be supported at all. Detected and
   refused at the feature entry point. Phase 12 §1.

---

## What "perfect" means here

Ten measurable criteria (Arch §1), checked automatically by the Phase 02 harness
and reported at runtime in `StitchReport`:

```
S1  RMS reprojection error  < 1.0 px       S6  SSIM ≥ 0.97 / PSNR ≥ 32 dB
S2  loop closure            < 0.25°        S7  capture ≤ 90 s
S3  seam score              < 2× noise     S8  stitch ≤ 60 s
S4  max gain ratio          < 1.03         S9  peak RSS < 700 MB
S5  coverage 100% ≥1×, ≥25% pairwise    S10 opens as a GPano photo sphere
```

If it does not have a number, it is not a criterion — it is an opinion.

---

## Status

| Item | Status |
|---|---|
| Planning | ✅ complete — this directory |
| Research **R1** OpenCV distribution | ✅ done — [findings](findings/R1_opencv_distribution.md) |
| Research **R2** intrinsics | ✅ done — [findings](findings/R2_intrinsics.md) |
| Research **R3** bracketing | ✅ done — [findings](findings/R3_bracketing.md) |
| Research **R4** low-texture registration | ⬜ optional; only if `low_texture` fails Phase 03 |
| Research ~~R5~~ ARCore | ❌ dropped with Phase 14 |
| Phase 00 **Spike A** OpenCV build | ✅ built + measured — 5.13 MB Android arm64 / 6.17 MB iOS arm64, 16 KB verified. On-device probe run still pending |
| Phase 00 **Spike B** intrinsics | 🟨 harness built (`spikes/spike_bc_device`), **needs a device run** |
| Phase 00 **Spike C** bracketing | 🟨 harness built (`spikes/spike_bc_device`), **needs a device run** — the burst wall clock is still the one unmeasured number |
| **Phase 01** skeleton & data model | ✅ done — `flutter analyze` clean, 76 tests pass |
| **Phase 02** synthetic rig & replay | ✅ done — 9 profiles, 8 metrics, gate runs in 83 s. Baselines recorded as FAIL against the control group, and the gate is proven to go red when it gets worse |
| **Audit of 00/01/02** | ✅ done — `flutter analyze` clean, **100 tests pass**, gate green. Three fixes applied, see below |
| **Phase 03** native registration | ✅ done — S1 0.17 px on `pristine`; 7–8 px elsewhere is the open gap |
| **Phase 04** native compositing | ✅ done — strip blend bit-identical, wrap seam closed, both polar caps filled |
| **Phase 05** HDR exposure fusion | 🟨 done — beats its single-exposure control on both criteria, but **non-deterministic**; see open issues |
| **Audit of 03/04/05** | ✅ done — analyze clean, 100 Dart + 128 native checks, gate green and now pointed at the native pipeline. Three fixes applied, three issues open |
| **Phase 06** platform camera | 🟨 written — both halves compile, 140 Dart tests pass, analyze clean. **Every exit criterion is still unmeasured**: they need one device run each, see below |
| **Phase 07** platform pose | 🟨 written — both halves compile, **204 Dart tests pass**, analyze clean. Everything decidable off a device is decided; the §5 timestamp-alignment test, the mirroring check and the 3-minute drift need one device run, see below |
| **Phase 08** capture orchestration | 🟨 done — Math §8's worked example reproduces exactly (11/8/8 + 2 zenith = 29), the validator now rasterises a 40 000-point Fibonacci lattice, **312 Dart tests pass**, analyze clean. The 90 s session (S7) is the one exit criterion that needs a device. Baselines re-recorded in the 06–09 audit |
| **Phase 09** capture UI | 🟨 done — six elements in one painter, zero per-frame allocations, goldens over pure white and pure black, **344 Dart tests pass**, analyze clean across package and example. **The sunlight and gloves checks are not done** and cannot be automated: `docs/CAPTURE_UI_FIELD_CHECKLIST.md` |
| **Audit of 06–09** | ✅ done — analyze clean, **344 Dart + 142 native checks**, gate stable across repeat runs. Two fixes applied, three issues open — see below |
| **Phase 10** isolate pipeline | 🟨 done — analyze clean, **375 Dart + 146 native checks**, 50 cancels during blending and 100 cancel cycles pass on the desktop build. The tier probe, the OOM downgrade and the dropped-frame count **need a device run**: `example/integration_test/stitch_device_test.dart`, no setup required |
| **Phase 11** metadata & viewer | 🟨 done — analyze clean across package and example, **455 Dart tests** (+ the native group), `exiftool` accepts real stitched output with no warnings and now runs in the gate. The direction-marker golden is **verified to go red** against a deliberately mirrored shader. Two exit criteria **need a device run** (`example/integration_test/viewer_device_test.dart`, no setup) and one is **manual, once**: Google Photos and Facebook |
| **Phase 12** quality & devices | 🟨 done as far as a desk allows — analyze clean, **154 native checks**, gate green with no regressions across all nine profiles, four docs written, parallax floor measured. **The device matrix is empty and the field corpus is empty**: both need hardware and a site visit, and both now say so loudly rather than being absent quietly. See below |
| **Phase 13** example demo & release | 🟨 done as far as a desk allows — **519 Dart tests**, analyze clean across package and example, `dart doc` 0 warnings, `public_member_api_docs` now an error. The API audit found and fixed **seven** `src/` leaks. The native build is scripted and **verified**: `libsphere_stitch.so` is in the example APK and the iOS xcframework links. **The seven flows have not been run on a device**, and S10 — an exported equirect opening in Google Photos — is still the one manual check |

Update this table as work lands.

### What Phase 12 measured, and what it changed

**A single-exposure position was handed to registration at the wrong scale.**
`frameScale` is decided once per capture and the intrinsics are scaled by it once,
but a position with one exposure took the byte-identical passthrough path and kept
its full-size file — so its focal was off by exactly the downscale factor, which
is a right-shaped error bundle adjustment cannot absorb. It fires on the whole of
the fleet's low end (a `LEGACY` camera cannot bracket, so every position is
single-shot) and on any one position whose bracket the frame gate reduced to one
exposure, where it would have presented as a single mysteriously misaligned
direction and been blamed on low texture. **The harness cannot see it** — 480 px
frames oversample a 2048 canvas by 0.58×, so the downscale never engages there.
`testEveryFrameIsAtTheScaleTheReportClaims` builds a 12 MP mixed capture and
failed on its first run at 3024 px against a claimed 1512. Fixed in `hdr_fuse.cpp`;
the single exposure is resampled like its fused neighbours.

**Architecture §3.3's translation signature does not separate, and is not
shipped.** Implemented as specified (residual against log feature scale, over the
same MAD-gated inlier set as S1), it reads **−0.09** on `parallax_1m` — 10 cm of
offset at 1 m, 36 px of S1 — and **+0.38** on `pristine`, which has no translation
at all. The profile built to contain parallax has the lowest correlation of the
set; the control has the highest. Likely the fixture rather than the physics: the
synthetic room is textured with fractal noise, which is scale-invariant, so
detection scale carries no depth information. The number is reported for a future
attempt and **no warning is raised from it**, because a fabricated cause costs
more than a missing one — the first time a manager who pivoted correctly is told
they walked, every other warning loses its authority. Full numbers and the
experiment that would settle it: [findings](findings/translation_signature.md).

**The parallax floor now has numbers.** `tools/parallax_sweep.dart` reproduces
§3's analytic table by an independent route, and measured S1 tracks the predicted
disparity at a consistent 0.68–0.75× across a 30× range of `r/d`. The control
reaches 0.14 px; 3 cm of lens travel at 1 m puts S1 six times over target; and
across that range the seam score rises 3.4× → 5.0× while SSIM collapses 0.97 →
0.63, which is the graph cut doing precisely what §3 asked of it. In
`docs/METRICS.md`.

**Four of §3's five performance wins were already in place** — the fusion
downscale, the parallel bracket decode, seam finding at 0.07 scale, and skipping a
no-op undistortion. What the measurement found instead was that registration's
*own* decode loop and its SIFT pass were serial. Both are now parallel, bounded to
four workers, and the bound is a memory decision: each decode worker holds ~72 MB
at 12 MP, so an unbounded `parallel_for_` would spend S9's whole budget to save a
few seconds. Feature detection builds a detector per worker rather than sharing
one, verified byte-for-byte against the serial path.

### What Phase 12 could not do

Two deliverables need things a desk does not have, and both are built so that the
absence is loud rather than silent:

**The device matrix is empty.** S7, S8, S9, thermal state at completion and
battery drain per station are statements about hardware.
`example/integration_test/device_matrix_test.dart` produces a row per device —
tests 1–5 unattended, test 6 the only source of S7 and the only one needing a
person — and `tools/device_matrix.dart` merges them, declares the fleet so an
unrun device is a row that says so, and **exits non-zero while the matrix is
incomplete**. `docs/DEVICE_MATRIX.md` currently reads `0 of 6`. The rugged Android
is listed first, as the doc insists.

**The real-site corpus is empty.** The mechanism is complete: seven scenes with
per-scene thresholds, reference-free metrics for the four criteria a real capture
cannot support (S1, S2, S6 and tilt — the stitcher's own figures appear under
`*_reported` ids, never inheriting a truth-referenced name), a checksummed
manifest, a fetch script, and gate integration. The gate prints **"the real-site
corpus is ABSENT (0 of 7 scenes)"** on every run and repeats it in the markdown,
because the way a regression detector dies is silence — which is the same lesson
as the gate once defaulting to `legacy-dart`. `docs/FIELD_CORPUS.md` is the
protocol; it takes a morning.

### Found while writing Phase 13

**The public API audit went red on seven leaks, and three of them were the same
mistake.** `PigeonCameraPlatform` and `PigeonPosePlatform` each took an
injectable pigeon-generated host API in a public constructor, and
`IntrinsicsResolver.resolveAndroid`/`resolveIos` take generated fact types.
Nothing had ever passed the injectable ones — they were seams added on
principle and never used — so the parameters came out, and the two resolvers are
`@internal`, which the analyzer enforces against consumers rather than merely
asserting in prose. `SphereViewer.textureLimit` was the opposite case: a
genuinely useful knob whose type could not be named, so `TextureLimit` is now
exported. The point of the audit is that none of these are visible from inside:
the package compiles, the example compiles, and the first person to hit one is a
consumer trying to write down the type of something the package handed them.

**An arm64-only simulator slice does not work on an arm64 Mac.** The obvious
xcframework — device arm64 plus simulator arm64 — fails to link on an Apple
Silicon machine, because Xcode builds a simulator target for arm64 *and* x86_64
unless told otherwise and CocoaPods only selects a slice carrying every
architecture in `ARCHS`. It matches nothing, copies nothing, and the error is
`Library 'sphere_stitch_merged' not found`, which reads as a missing file. The
simulator archives are now lipo'd into one fat library.

**A static archive whose only caller is Dart does not get linked in, and the
build says nothing.** Nothing in the Swift half of the plugin calls
`sv_stitch`; the only caller is across an FFI boundary the linker cannot see,
and a static archive is pulled in member by member on demand. So the three FFI
entry points were simply absent, the build succeeded, and the failure would have
arrived on a device after a 90-second capture as `Failed to lookup symbol
'sv_stitch'`. `ios/Classes/SphereStitchSymbols.c` takes their addresses in a
`__attribute__((used))` table; `nm -gU` on the built framework confirms all
three. `-force_load` was tried first and is worse — Xcode validates the path as
a build input before the phase that produces it has run, and says "Build input
file cannot be found".

**`NSMotionUsageDescription` reversed.** `ios/README.md` said the key was
unnecessary because it gates `CMPedometer` and `CMMotionActivity` rather than
raw device motion — narrowly true, and not worth the failure mode. If it is
needed and missing, the attitude stream simply never delivers: no crash, no
prompt, a reticle that does not move on a site. It is one line, and being wrong
in the other direction costs nothing.

**`StitchQueue`'s atomic write was not atomic against itself.** Temp-file-plus-
rename protects against a crash mid-write, and against nothing else: two
overlapping saves write the same `.tmp` path, the first rename moves it, and the
second fails with a path-not-found on a file it had just written. It is
reachable in ordinary use — `enqueue` saves from the caller while the drain loop
saves a status transition, and a bundle arriving during a stitch is the normal
case on a site walk. Phase 13's new `retry` widened the window enough to catch
it in a laptop test. Fixed with the same `_saveChain` the capture session
already puts around `CaptureBundle.save`, which is the tell: one layer already
knew, and the knowledge did not travel.

**And the chain had its own bug, in both places.** Seeding it with a
`Future.value()` field initialiser captures the zone the *constructor* ran in.
`flutter_test` runs a `testWidgets` body under a fake async zone whose
microtasks advance only when the test pumps, so an object constructed in the
test body and then used inside `WidgetTester.runAsync` — the only way to await
real file I/O, and therefore what a consuming app's widget test will do —
chains every write onto a future nothing ever completes. The symptom is a test
that hangs with no stack and nothing to grep for; it cost twenty minutes to
find, on code that had just been written, by somebody who knew what had
changed. Both chains are now seeded on first use.

**The demo's own `ChangeNotifier` fired after dispose, and that is a real
integration hazard rather than a test artefact.** A stitch takes a minute and
finishes on its own schedule, so "the screen went away while the queue was
working" is the normal case — closing the app on the last station of a walk hits
it every time. It surfaced as a framework assertion from a stack trace with no
UI in it. Worth knowing for any host app that hangs UI state off `queue.events`.

### Start here

1. **Run the Phase 06 and Phase 07 device tests on a tablet and an iPad** — see
   `example/integration_test/RUNNING.md`. Phase 07's is the shorter of the two
   and settles the question this project cannot reason its way out of: whether
   the platform→world conversion is mirrored, and whether the pose and the
   shutter are on one clock to within 3 ms. It needs a doorframe, two minutes of
   setup and someone to pan the tablet.

   Phase 06's: This now supersedes running
   `spikes/spike_bc_device` for most purposes: it measures the same headline
   numbers (burst wall clock, `cameraIntrinsicMatrix` availability, lock drift)
   through the *shipping* plugin rather than through a throwaway app, so a
   passing result is evidence about the code that will actually run. The spike
   remains useful for its wider capability dump across a fleet.

   The quick run needs no physical setup and takes four minutes; it produces the
   burst wall clock, which R3 established no source anywhere has ever published.
   The full run adds a tape-measured field of view and a grey card, and answers
   whether the unresolved Apple Forums #749574 lock drift affects our devices —
   which Phase 04's gain compensation assumes it does not.
2. **Phase 01** — pure Dart, zero dependencies, zero risk. Start immediately, in
   parallel; it does not depend on any spike.
3. **Phase 00 Spike A is done** as far as it can go without hardware: the build
   is scripted and reproducible in `spikes/spike_a_opencv/`, sizes and 16 KB
   alignment are measured. Note the recipe changed — build vanilla OpenCV with
   `BUILD_LIST`, do **not** fork `opencv-mobile`; the reasoning is in the R1
   findings.
4. **Phase 02 is done.** `tools/ci/quality_gate.sh` is the number that every
   later stitcher change is judged against; run it before and after.
5. The native track (03, 04, 05) is complete against the harness. **Phase 06**
   (platform camera) is next, and it is the one that needs a device.

### Found while writing Phase 07

**`DevicePose.forward`, `.yaw` and `.pitch` were mirrored** relative to the
rotation the same object hands the stitcher. `vector_math`'s
`Quaternion.rotated` applies the *inverse* of `asRotationMatrix` —
`axisAngle(Y, +90°)` carries `+Z` to `−X` under one and to `+X` under the other
— and `DevicePose` used the quaternion form for its angles and the matrix form
for `toOpenCvRotation`. The existing convention test could not see it because it
used the identity pose, which is its own transpose.

Nothing consumed the broken accessors yet, so no output ever changed and no
baseline moves. It is worth recording anyway, because it is precisely the shape
Math §0 warns about: two halves of one object, each self-consistent, disagreeing
about which way the user turned. Phase 08's guidance would have been the first
casualty and it would have presented as a stitcher bug. `QuaternionUtils.rotate`
is now the only rotation in the package and `conventions_test.dart` pins the
trap against a `vector_math` upgrade.

### Found while writing Phase 11

**The direction-marker golden does not catch a mirror on its own, and it was
worth finding that out deliberately.** §3.3 asks for a golden over six camera
orientations, on the argument that a sign flip produces a mirrored view that
looks plausible. Built and passing, it was then run against a shader with
`atan(dir.x, -dir.z)` changed to `atan(-dir.x, -dir.z)` — the exact defect the
section describes. **Four of the six orientations still passed.** The reason is
that a horizontal flip is a symmetry of most of the marker set: it exchanges east
and west and leaves north, south, the zenith and the nadir where they were, so
any orientation showing only those four proves nothing about handedness. The
suite catches it — two orientations plus the explicit "east is to the right of
north" test go red — but a golden built with only cardinal *forward* markers, or
tested only at the identity orientation, would have shipped a mirrored viewer
with a green test suite. The mirror check is now stated as a fact about the
world ("turning right takes you towards east") rather than as a formula
comparison, and the mutation is recorded here so nobody simplifies the marker
set later.

**A viewer that always ticks makes `pumpAndSettle` impossible — for the host
app, not just for us.** The Phase 01 viewer started a `Ticker` in `initState`
and never stopped it, which is invisible until a widget test tries to settle:
every test in a *consuming* app that pumps a screen containing a `SphereViewer`
would hang, and the cause would look like the app's own bug. The controller now
answers `needsTick`, and the widget starts and stops the ticker with it. That is
also the right behaviour on the device — a panorama sitting still is the normal
state, and waking the raster thread 60 times a second to recompute nothing is
pure battery on a tablet that is out all day.

Two smaller things that would have been silent: `autoRotateSpeed` was a plain
field, so setting it changed nothing anybody was watching and the auto-rotate
button would have appeared dead once the ticker became demand-driven; and
inertia decayed geometrically without ever reaching zero, which would have kept
`needsTick` true forever and quietly restored the always-on ticker.

**`PoseHeadingDegrees` must be omitted, not zeroed, and the same is true one
layer down.** Zero is a real bearing — due north — so a file that writes 0 for
"we do not know" is indistinguishable from one that was surveyed facing north,
and every viewer opens it confidently in the wrong direction. This propagates
further than it looks: `CaptureBundle.headingDegrees` was a bare `double?`,
which is exactly the shape that lets a magnetometer reading be mistaken for a
plan-derived one three layers downstream. It is now a `PanoramaHeading` carrying
its own source, pre-Phase-11 manifests load their bare number as
**magnetometer** (the conservative reading — the field existed when that was the
only source there was), and a magnetometer heading puts a plain-language warning
into `StitchReport.warnings`.

**The metadata writer belongs in Dart, not in C++.** The natural instinct is to
write the XMP in `compositing.cpp` beside the encoder. But the metadata's most
valuable field is the heading, its best source is the *plan* (§2), and the plan
is a Dart-side fact the native pipeline has never heard of — so pushing the
writer across the FFI boundary would mean pushing the heading priority order
across it too, leaving the C++ side holding a rule about a drawing it cannot
see. It is a Dart post-pass over the encoded file, and it does segment surgery
rather than a decode/encode round trip so the scan data is carried through byte
for byte and a 6144-wide panorama is never re-compressed.

### Found while writing Phase 10

**A blend strip is not the smallest uninterruptible unit, and the seam finder is
much worse.** Phase 10 §3 names the blend strip as the floor under the 500 ms
cancellation bound — true only while a strip is under 500 ms, and it is not.
Measured on `nominal` at `high`: blending is 2724 ms over 8 strips, ~340 ms each
on a desktop host that runs the whole pipeline in 15.6 s against the 60 s S8
budgets for a device, so a device strip is around 1.4 s. The flag is now polled
per *tile*.

The seam stage was the real problem. `GraphCutSeamFinder::find` is a single call
with no poll point anywhere inside it, measured at **542 ms** on the same run —
already over the bound on the fast machine, and there is no flag to pass it. It
is now decomposed into the per-pair loop `PairwiseSeamFinder::run` performs
internally: `GraphCutSeamFinder::Impl` derives from `PairwiseSeamFinder`, and
`findInPair(i, j)` reads only images `i` and `j`, their gradients, their corners
and the *current* masks `i` and `j`. Same pairs, same order, masks carried
forward, therefore the identical sequence of operations on identical inputs —
and `testPairwiseSeamMatchesSingleCall` asserts the resulting masks bit-for-bit
against a single call rather than trusting that reasoning. The longest
uninterruptible unit is now one `findInPair`, measured at **25 ms**. It costs
something — each image's Sobel gradients are recomputed once per pair it takes
part in — but not an amount this host can resolve: `seam_find` measured 542 ms
before the change and 371 ms and 682 ms on two runs after it, so run-to-run
noise is larger than the overhead. `seam_pair_max_ms` is reported per run so a
device can measure what a laptop cannot.

Exposure fusion is the same shape. §3 asks only for a poll between positions,
but `testFusionMeetsItsBudgetAtCaptureResolution` measures **841 ms for one
12 MP position**, and stage 5 is roughly 40% of a real stitch and the stage a
user is most likely to be watching when they change their mind. The flag is now
checked between exposures and immediately before the Mertens merge as well.

**OpenCV does not throw `std::bad_alloc`.** Phase 10 §4's sketch catches it and
maps it to `SV_OUT_OF_MEMORY`, which is the code the tier downgrade acts on. But
`cv::fastMalloc` raises a `cv::Exception` with code `StsNoMem`, and at 8192×4096
the allocation that fails is virtually always OpenCV's — so a boundary guard
written exactly as sketched would have reported every real out-of-memory as an
OpenCV error and left the retry path dead on the one device the tier table exists
for. The guard inspects `cv::Exception::code` before the type decides.

**`capture_quarter_turns` was going to the wrong place.** `registration.cpp`
reads it from the request root; `bundle.json` carries it nested inside `bundle`.
Passing the bundle through verbatim would have left it unread, and the synthetic
harness cannot see the difference because it always records 0. On a tablet whose
camera is mounted a quarter turn off the display this is the *same* bug the
06–09 audit fixed — a right multiplication BA cannot absorb — reintroduced one
layer up. `StitchRequest.toJson` lifts it, and a test pins it.

**The gate trips, on a different profile each run, and none of it is the seam
change.** Two consecutive runs over identical code flagged `partial: rss
633 -> 844` and then `nominal: s3_wrap 3.095 -> 4.114` — different profiles,
different metrics. That pattern is the tell, and both were chased down rather
than waved at, because `s3_wrap` measures the wrap *seam* and is precisely what
a botched seam decomposition would move.

The decisive experiment is `pristine`: locked exposure, so stage 5 is a
passthrough and the whole pipeline is deterministic. Built with the pairwise
seam finder and with the original single call, it produces **s3 3.327208862,
s3_wrap 6.051231912, SSIM 0.964022157 — identical to nine decimal places, twice
each**. That covers the real pipeline including wrap duplicates and pole
handling, which the four-tile unit test does not, so the decomposition is
output-neutral on real data and not merely in principle.

Which leaves the other two as what they look like:

* **`nominal` `s3_wrap` swings 3.17–4.29 on identical code.** Seven samples on
  the shipping build span that range; three on the reverted build span
  3.28–3.56, and the first three pairwise samples happened to be the high ones,
  which is what made it look like a shift. `nominal` is a 3-shot bracket, so it
  inherits open issue 1 — `cv::MergeMertens` is non-deterministic, different
  fused pixels give different registration and therefore different seams. A 35%
  spread is wider than the gate's 15% fusion band, so this profile now trips
  about one run in three, exactly as `motion_blur`'s `s2` already does.
* **`partial`'s peak RSS is stale, not moved.** Rebuilt with the single call it
  measures 750, 849 and 844 MB against the pairwise version's 785, 786, 805 and
  845 — the same distribution — and the native side's own per-stage high-water
  marks show the seam stage never sets the peak at all (`seam` equals `warp`
  equals `compensate`; the peak is set in `poles` and `encode`). The 633 MB
  baseline is simply older than this machine's behaviour.

No baseline is re-recorded here. Moving one is a deliberate act with a reason
attached, and "Phase 10 found it already wrong" is a reason to investigate the
fusion bug, not a licence to overwrite the record while passing through.

*(Phase 12 tried the prescribed fix. **It is wrong for `drive`, right for the
wait-for-I/O loops, and this paragraph's diagnosis is not the whole story.**

Applying a deadline to `drive` turned three consecutive green runs of
`capture_view_test.dart` into two failures out of three. `rounds` there is doing a
second job nobody wrote down: it is *how many frames of animation to advance*, and
`tester.pump()` with no duration does not move the fake clock — so a condition
that is not yet reachable is spun on for the whole timeout, thousands of pumps,
and the flash, the haptics and the position counter all end up somewhere else by
the time the assertions run. Reverted, with the experiment recorded above the
function.

Applying it to `settle` in `capture_session_test.dart` — a pure wait-for-I/O loop
with no frame semantics — **did** fix a real failure: "frames are on disk the
moment the position is accepted" failed reproducibly with ten suites running
together and passes now.

`stitch_queue_test.dart`'s "survives an app kill" test had a third variant of the
same bug, and that one is fixed properly: it waited for an in-memory marker and
then read the queue's state file immediately, racing a real write. It now waits
for the status to reach disk, which is what it was asserting all along — six
consecutive green runs, against roughly one failure in four before.

And the residual: `capture_view_test.dart` still fails about one run in five on a
loaded machine **with every helper in its original state**. So its flakiness is a
property of those tests rather than of a round count, and the sentence above —
"running it alone passes every time" — is not reliable. Still open.)*

**Phase 09's capture-view tests are flaky under CPU load, and it is not this
phase's doing.** Running the full suite alongside the 100-cycle cancellation
test — which saturates every core for seven minutes — turns
`capture_view_test.dart` from 8 passes into 2 to 11 failures, and running it
alone passes every time. The cause is `drive()`, which bounds itself at 40
rounds of `pumpEventQueue()`: the session's `bundle.save()` is genuine file I/O,
and on a loaded machine forty rounds is no longer enough for it to land. It is
a pre-existing property of those tests rather than a regression, but it will
bite CI the first time the native suite and the widget suite share a machine.
The fix is to bound `drive` by a deadline rather than by a round count.

**The progress ABI answers two different questions and Phase 01 recorded both.**
`SvProgress.permille` is documented in `sphere_stitch.h` as progress *within* a
stage, and `StitchProgress.fraction` is documented in Dart as overall and
monotone. Both are right — C++ knows it is warping frame 12 of 34 and cannot
honestly say what share of the remaining minute that is — but §2's sketch maps
one straight onto the other, which would give the user a bar that restarted
eleven times. `StitchProgressMapper` is the conversion, with measured per-stage
weights, on the Dart side where re-measuring them is cheap.

### First-device bring-up (2026-08-12)

The camera would not open at all:

```
PlatformException(open_failed, Can't create handler inside thread
Thread[sphere-camera-ops,5,main] that has not called Looper.prepare())
```

Four bugs, found over two device runs and mostly of the same shape — **the desk
cannot see them, and the device finds them one at a time, in the worst possible
order.** 520 Dart tests, 154 native checks and a green gate said nothing about any
of them. Three are platform-thread affinity, which is why (4) ends with a detector
rather than just a fix.

**1. The preview texture was created off the platform thread** (the reported
crash). Flutter's `TextureRegistry.createSurfaceTexture()` ends in
`SurfaceTexture.setOnFrameAvailableListener(listener, new Handler())` — a bare
`Handler`, which adopts the *calling* thread's Looper. Everything in
`CameraSession` runs on the plugin's `sphere-camera-ops` executor, a plain
`Thread` with no Looper, so it threw; the plugin's `run()` wrapper relabelled it
`open_failed`, which sent everyone looking at the camera rather than at the
texture. Creation *and* release now hop to the platform thread.

iOS had the identical bug at `textures.register()` and `unregisterTexture()`,
fixed the same way. iOS races rather than throwing, which is worse to diagnose,
not better. (`textureFrameAvailable` stays off-thread — that one is the
documented exception, and Flutter's own camera plugin does it.)

**2. Nothing ever requested the CAMERA permission.** The package checks it and
returns a clean `camera_permission_denied`, but a package that pulls in a
permission plugin forces that dependency on every consuming app, so asking is the
host's job — and the demo was not doing it. Without an `adb shell pm grant` the
flow ended at a snackbar the operator could not act on. The example now requests
it, and handles permanently-denied separately, since that is the one state the
prompt cannot fix.

**3. The capability probe never checked that the stitcher can run.**
`libsphere_stitch.so` ships **`arm64-v8a` only**, while the APK carries
`armeabi-v7a` and `x86_64` slices. On an emulator or a 32-bit tablet every frame
would be captured perfectly, the queue would accept the bundle, and the stitch
would fail at the far end — ninety seconds and a walk to the next station later.
That is exactly the mid-flow discovery Phase 12 §1 exists to prevent, and the
probe's own doc comment says so. New `SphereCapability.unsupportedNoNativeLibrary`,
checked with one `sv_version()` call beside the other refusals. The bundles such a
device leaves behind are not wasted: build the library for that ABI and they all
stitch.

**4. Pose samples were sent to Dart from the sensor thread.** Found by the next
run, once the camera opened far enough to start the pose stream — the process
died on the *first* sample after Start:

```
FATAL EXCEPTION: sphere-motion
java.lang.RuntimeException: Methods marked with @UiThread must be executed on
the main thread. Current thread: sphere-motion
```

The same bug class as (1), in a different API. Phase 07 deliberately skipped the
main-thread hop for `onPoseSample` — and only for `onPoseSample`; every other
callback in both plugins already posted — on the stated premise that
"`BasicMessageChannel.send` is safe from any thread". It is not: `send` reaches
`FlutterJNI.dispatchPlatformMessage`, which is `@UiThread`. **Both platforms
carried that claim, in the same words**, so iOS had it too, where it corrupts the
engine's message queue quietly instead of crashing.

The latency the premise was buying was worth nothing. A pose is placed in
`PoseBuffer` under its own `timestampUs` and read back by SLERP at the shutter
timestamp, so *when it arrives* is not an input to anything — only its order and
its presence are, and one poster thread posting to one looper preserves both.
Coalescing or dropping samples to save main-thread work would be the change that
actually costs accuracy, by widening the interval interpolation must bridge.

**The detector.** Three of these four bugs are invisible to every test that does
not run on a device, and this class has now cost two device sessions. The
laptop-runnable guard is lexical: `tools/ci/platform_thread_check.sh` finds every
`FlutterApi.on*` and `textures.*` call site in native code and requires a
platform-thread hop token within three lines. It is wired into
`release_checks.sh`, it asserts a **minimum site count** so stale patterns cannot
silently match nothing (the Phase 12 failure mode), and it is mutation-tested
against all three historical bugs — each reintroduced in turn, each caught, green
again after restore. That exercise immediately earned itself: macOS ships BWK awk,
where `gensub` is a fatal undefined function, and it sat on the offender path — so
the guard would have died precisely when it first had something to report.

It cannot prove a hop is *correct*, only that someone thought about one. That is
enough for the failure that actually occurs, which is a bare call with no hop
anywhere near it.

**Still to decide:** whether to ship `armeabi-v7a` at all. R1's build list covers
it; nothing has built it. If the rugged fleet in Phase 12's matrix is 64-bit, the
refusal above is the right permanent answer and the ABI question closes.

### Best-effort stitching (2026-08-12)

Every capture on the device failed with:

> This capture plan cannot be registered: adjacent frames overlap by only 35%
> (feature matching needs at least 25%), and 99.8% of the sphere is covered.

That sentence refutes itself — 35% clears 25% — and the reason is that the
message blamed overlap whichever half of `minimumPairwise < 0.25 || coveredOnce
< 1.0 - 1e-9` had fired. **The coverage clause fired, and it could not have done
anything else.** `fraction_covered_at_least_once` is `covered / 40000` over a
Fibonacci lattice, so one uncovered lattice point lands 2.5e-5 below 1.0 against
a 1e-9 tolerance — 25 000x too small to admit even one. Real captures always
leave a few, usually at the nadir under the operator's own feet, so the gate
rejected all of them. It also ignored the nadir cap S5a explicitly lets a plan
declare, a second way to fail a sphere that was never going to be complete by
design. `CoverageReport.isAcceptable` carries the same 1e-9 and the same flaw.

**The policy is now a grade, not a gate**, at the product owner's direction:
stitch by what actually matched, never refuse on geometry. Both refusals are
gone — the plan pre-flight in `sphere_stitch.cpp`, and `grouped.empty()` in
`registration.cpp`, which used to reject an all-IMU capture as "not accurate
enough to be worth presenting". That was already inconsistent: the block forty
lines below it makes the opposite call for the all-components-failed case, and
§4 is explicit that a frame is never dropped because a hole in the sphere is
worse than a soft frame. Everything downstream was already built for this —
unmatched frames keep their IMU prior and still contribute pixels, and stage 14
fills the rest by push-pull extrapolation.

`sparse_plan` — 15% overlap, written to "fail loudly rather than silently
produce mush" — now returns a complete panorama carrying `plan_cannot_register`,
`match_graph_split`, `bundle_adjustment_failed` and
`imu_only_dominates_residual`. The metrics say plainly that it is a bad capture
(S1 16.67 px); the operator gets an image rather than a second walk.

Two defects fell out of making that path reachable:

**Bundle adjustment was unbounded.** OpenCV's default is
`TermCriteria(EPS | COUNT, 1000, DBL_EPSILON)` — a thousand LM iterations
against machine precision. A well-conditioned component converges in a few
dozen; a degenerate one cannot converge at all, so it ground through all
thousand and *then* reported failure. On `sparse_plan` that was **211 s of a
215 s stitch**. It never mattered while such captures were refused before BA
ran. Bounded to 200 iterations at 1e-6: **215 s → 55 s, with S1 identical at
16.67 px** — the time was pure waste — and `nominal` unchanged at BA 1.0 s.

**The blender's mask certified black pixels.** `blendedMask` means "this pixel
is in the blend", not "it came out with something in it": where contributing
weights are vanishingly thin, MultiBandBlender's reconstruction lands on exactly
zero and the mask still claims it, so stage 14 skipped it and it shipped black.
Present on `nominal` at 1.000 coverage, so no amount of shooting fixed it.
Exact black now clears the bit in `covered` in place. **`holes` 0.005% → 0.000%
on `nominal`** — the sphere is complete. Doing this with a separate CV_8U mask
first cost 96 MB of peak RSS on `low_texture` for a buffer read once; clearing
the bit where it already lives allocates nothing.

**Baselines are deliberately not re-recorded.** The gate correctly reports
`sparse_plan: no longer refused`, which is the guard doing its job about a policy
that changed on purpose. It also reports `rss` moves on three profiles — but
`nominal` peak RSS measured **949 / 1035 / 1149 MB across three identical runs**,
a 200 MB spread on the same binary, so those deltas are inside the noise floor
and the final code adds no allocation. `nominal`'s `s3_wrap` reads 3.58–3.80
against a 3.095 baseline; that metric was already failing its 1.10x target, and
part of the gap is the documented fusion band. Re-recording on a loaded machine
would bake noise into the baselines, so the gate's own instruction stands: run
`tools/ci/quality_gate.sh --record` **once, on an idle machine, in its own
commit**.

### The focal collapse (2026-08-12, second device round)

A real capture produced a panorama that was a few patches of imagery floating in
pole fill. The report named the cause, and the number that mattered was the one
that **passed**:

| Reported | Value |
|---|---|
| Refined focal | **9804.4 px** → HFOV **23.51°** |
| S5 coverage | 46.6% |
| S1 registration | **0.54 px — passing** |
| S2 loop closure | −1.000° |
| Levelling | 0.000° |

A phone main camera is ~67° HFOV. At 23.5° every frame warps to about a tenth of
the solid angle it should, which *is* the bad stitch and the 46.6% coverage —
one defect seen twice.

**S1 passing was the tell.** `BundleAdjusterRay` solves rotations and focal
together, and that pair is degenerate: lengthen the focal, shrink every rotation,
and the residual barely moves because the solution stays consistent *with
itself*. It was never consistent with where the tablet was pointed. Nothing
clamped the refined focal, and nothing compared it to the seed — the report
emitted `refined_intrinsics` only, so the divergence was unreadable even in
hindsight.

Fixed, in four places:

1. **A focal clamp in `adjustComponent`.** More than ±20% from the seed is not a
   refinement; the seed focal is restored, the refined *rotations* are kept
   (they are separately observable), and `focal_refinement_rejected` says so. R2
   measured genuine refinement at ~3%, so 20% never binds on a real solve.
2. **A collapse detector**, catching the same failure by its effect rather than
   its symptom: `angularSpreadDegrees` compares how much sphere the solved
   cameras span against the IMU. Materially less means the solve is discarded for
   the priors — a few degrees of honest error beats a self-consistent fiction.
   The IMU is the right reference precisely because it never solved anything and
   so cannot collapse.
3. **A field-of-view plausibility gate** in `intrinsics_resolver.dart`. Outside
   40°–130°, `LENS_INTRINSIC_CALIBRATION` is rejected in favour of the physics
   rung — R2 already had this key reported null and all-zero, and out-of-family
   is its third failure mode, the most damaging because it *is* a number and
   passes every structural check. A final `_guardFieldOfView` clamps whatever
   survives every rung and says so in the notes.
4. **Seed beside refined in the report** (`captured_intrinsics`, carrying the
   device's own provenance). Either number alone is unfalsifiable.

**Both guards are mutation-tested**, which is the only reason to believe them.
Forcing a 3.2× focal — the ratio the device showed — fires the clamp, restores
the seed exactly, and holds coverage at 1.000 instead of collapsing. Shrinking
every solved rotation fires the collapse detector ("54° when the tablet swept
180°") and the IMU fallback rescues coverage. Neither fires on `nominal`,
`pristine` or `harsh_imu`, where BA's real +3% → −1.6% refinement passes
untouched.

**Two reported numbers were lying.** S2's `−1.000°` is a *sentinel* meaning
"fewer than three registered equatorial frames — no ring", and the report screen
rendered it against a 0.25° target, where it then **passed**, because −1 < 0.25.
It now reads "not measured" with the reason. And `Levelling 0.000°` was
tautological: registration applied the levelling rotation and *then* measured
residual tilt on the levelled result, and levelling is defined as the rotation
that carries the solution's mean up onto measured up — so the residual was zero
by construction, for any input. Measured before levelling it reads 0.0018° on
`nominal` and can now fail. The levelling rotation's own magnitude is reported
beside it. Same family as the original S2 bug that telescoped to identity.

### Exposure, and the wait

**Exposure is automatic now** — `ExposureStrategy.auto`, one frame per position,
metered fresh, the default. The lock was costing three shots and a fusion stage
per position to hold a value that on device *was not holding*: brightness match
came out at 1.315 against a 1.03 target. Per-frame metering plus the gain
compensation already in the pipeline is what Pixel and Street View do. The
metering sweep is skipped entirely, along with the family of lock-quality
warnings that no longer describe anything.

One trap found while wiring it: with no lock, `planBracket` falls back to a
hard-coded 1/60 s at ISO 100, so a device with `MANUAL_SENSOR` would have shot
every frame at a fixed daylight exposure — several stops under indoors, arriving
at "some images are too dark" by a completely different route. The auto path now
forces `CONTROL_AE_MODE_ON` ahead of every bracket branch and skips them. iOS had
the same shape and is fixed the same way.

**The queue stitches twice**: `previewTier` (low, 4096×2048) first, so a complete
sphere is viewable seconds after the last shutter, then the device's real tier,
which replaces it. Events carry `preview: true` so a UI can swap. The preview
goes to its own file and its failures are deliberately swallowed — it is a
convenience, and a failed preview must not cost the full pass. Mutation-tested:
removing the preview pass turns the new test red.

**Still open: the upside-down viewer.** The mapping is *not* at fault — the
shader maps zenith to row 0 (`equirect.frag:46`) and the compositor agrees
(`compositing.cpp:440`), and drag/zoom signs check out. That leaves sphere
orientation: `captureQuarterTurns` (whose sign has never been confirmed on
hardware, and where a wrong sign at one quarter turn is exactly a 180° roll — the
observed symptom) or levelling. Deliberately **not** flipped speculatively: with
two candidate causes, guessing at one masks the other, and the fixed tilt metric
plus `example/integration_test/pose_device_test.dart` can now settle it from
measurement.

### Open issues after the 06/07/08/09 audit

**1. `cv::MergeMertens::process` is non-deterministic — now isolated.** Previously
recorded as "HDR fusion is non-deterministic"; the culprit is OpenCV's own Mertens
implementation, reached by elimination. 16 of 34 fused frames differ byte-for-byte
between two runs *with serial decode, alignment off and ghost suppression off*, and
JPEG encoding is deterministic, so the pixels themselves differ. Not threading
(`OPENCV_FOR_THREADS_NUM=1` still varies), not OpenCL dispatch
(`OPENCV_OPENCL_RUNTIME=disabled` still varies), not our decode. S1 on `nominal`
spans **8.24–9.13 px** across repeated runs.

Everything downstream inherits it, so the gate now carries a documented 15% band on
fusion-affected metrics (`quality_gate.dart`, `_fusionAffected`). That band is a
placeholder for a bug, not a judgement about the metrics — it goes back to the
default 5% the day fusion is deterministic. `motion_blur`'s `s2` swings ~42%, wider
than any sane band, so the gate still trips on it roughly one run in three; that is
honest signal about a known bug and not a reason to switch the gate off.

Likely cause, worth checking first: a pyramid level in Mertens whose border is not
fully written when the level sizes do not divide evenly — the classic signature of
"only some frames, at scattered offsets".

**2. Registration on distortion-carrying profiles.** Unchanged from the previous
audit: `pristine` is 0.17 px, everything with uncorrected distortion is 8–22 px.
This is the R2 intrinsics gradient, and it is why Phase 06's iOS distortion result
matters — the model is worth 6.3× on S1.

**3. Device measurements do not exist.** Phases 06 and 07 are written and compiling
but **every one of their exit criteria is unmeasured**: burst wall clock, intrinsics
within 2%, grey-card lock stability, ±2 ms clock drift, the 3 ms timestamp fit, the
mirroring check, 3-minute drift, and the 29-position session under 90 s. Both phases
ship device test harnesses (`example/integration_test/`, `RUNNING.md`) that produce
the numbers in about four minutes each. Until they are run, the platform half of
this package is unverified on hardware.

### Fixed in the 06/07/08/09 audit

- **The capture-frame roll was never applied to the IMU seeds.** Poses are
  device-frame, JPEGs are capture-frame, and Math §2's `C = N·D` assumes they agree
  — true only for a sensor mounted square to the display, which most tablets are
  not, and iOS delivers landscape photos while reporting a 0° sensor orientation.
  The correction is `R_pc = M·R_wd·N·Rz(−θ)`, a **right** multiplication, which is
  exactly why bundle adjustment could not absorb it: its gauge freedom is a left
  multiplication. `Rz` preserves the optical axis, so every seed still pointed the
  right way while being rolled a quarter turn — leaving `shouldMatch` correct,
  handing BA a seed outside its basin, and tilting the §7 gravity levelling.
  Invisible to the harness, which renders and records in one frame. It would have
  surfaced on the first real capture as a stitcher bug. `CaptureBundle` now records
  `captureQuarterTurns` at capture time — the only place the fact exists — and
  `sv_geometry.cpp` applies it.
- **`low_texture` refused to emit a panorama after capture**, while its own warning
  said the result "is emitted with an honest number rather than withheld". Refusing
  a *plan* before the camera opens (`sparse_plan`) is free and prevents a wasted
  90-second capture; refusing after 34 shutter presses destroys work already paid
  for. It now emits an IMU-positioned panorama at 100% coverage with honest metrics
  and a loud warning, per arch §8 and Phase 03 §4.
- **Peak RSS tripped the "crossed a criterion" rule on alternate runs**, because it
  is a GC high-water mark sitting a few percent from its 700 MB target. Its own 25%
  drift band watches it; the crossing rule no longer applies to it.
- Baselines re-recorded — Phase 08's plan reordering re-seeded the rig's
  per-position noise, which was the correct explanation and is now the recorded one.

### Open issues after the 03/04/05 audit

Three things, in priority order. **None blocks Phase 06** — the platform camera
plugin is independent of stitcher accuracy (see the parallelism diagram) — but
none should reach a device without being closed.

**1. HDR fusion is non-deterministic.** Two identical runs over the same bundle
produce **16 of 34 fused frames differing byte-for-byte**, and the files differ
in size, so this is substantive content divergence rather than float-reduction
noise. It propagates: S1 on `nominal` swings 8.24–8.57 px across identical runs,
while `--no-hdr` is exactly 7.89 px every time.

It matters for three reasons beyond tidiness. Replayability (arch §6.6) assumes
re-stitching a bundle gives the same answer — it is how a field failure gets
diagnosed. The quality gate cannot distinguish a real regression from run noise,
and by its own reasoning a gate that cries wolf gets switched off. And a
byte-level divergence of this size in ~half the frames is the signature of
**uninitialised memory**, which is a correctness bug, not just a reproducibility
one. It is not thread scheduling: `OPENCV_FOR_THREADS_NUM=1` still varies, and
`testParallelDecodeMatchesSerial` already covers the one `parallel_for_` in the
stage. Start by looking for a `cv::Mat` read before it is written.

**2. Registration regressed between Phase 03 and Phase 04, and nobody noticed.**
Phase 03 recorded `nominal_best` at 0.295 px; the same configuration now measures
4.65 px, and Phase 04 flagged it ("worth a look before Phase 05") before Phase 05
shipped over it. `pristine` is unaffected at 0.17 px, so the conventions, BA and
levelling are sound — this is specific to the profiles carrying distortion.

The reason it went unnoticed is item 3.

**3. Fixed: the quality gate was watching the wrong code.** It defaulted to the
`legacy-dart` control group, so after Phases 03–05 landed it went on comparing
the control against itself — green every run, about code nobody was changing.
That is precisely why a 15× registration regression survived two phases. The gate
now defaults to `native`, a deliberate refusal (`sparse_plan`) is a recordable
outcome rather than a crash, and a profile that **stops** refusing is itself
reported as a regression. Baselines re-recorded against the shipping pipeline.

Also fixed in this audit: **S1 excluded IMU-only frames**, so the headline number
described the frames that registered well rather than the panorama. On `nominal`
that read 0.295 px against a ground-truth-referenced 4.65 px with nothing
explaining the gap — the same shape as the S2 loop-closure tautology Phase 03
caught. S1 now covers every frame; the registered-only figure is reported
alongside, named for what it is.

### Found while writing Phase 08

**The plan was being built in the wrong frame.** `CameraOpenResult.intrinsics`
is in the *capture stream's* frame: Android delivers the JPEG off the sensor
unrotated, and iOS delivers photos in the sensor's landscape orientation while
reporting `sensorOrientationDegrees: 0`. The plan, the pose and the preview all
live in the **device** frame, portrait-locked. Feeding sensor-frame intrinsics
to the planner swaps `h` and `v`, which produces a plan for a camera held the
other way round — and still returns a plausible-looking ring count, which is
what makes it dangerous. `SphereCaptureSession` now reconciles them.

**The same mismatch is still open on the stitcher side.** The bundle carries
device-frame poses and sensor-frame JPEGs, so on a camera mounted 90° from the
display every `toOpenCvRotation()` is off by a fixed roll about the optical
axis. A common *right*-multiplication is not the gauge freedom BA leaves free,
so it degrades the seeds and the IMU match gate rather than cancelling. The
harness renders from `aimingDeviceToWorld` and cannot see it. It belongs with
Phase 03's conventions and needs a device with a non-zero sensor mounting to
settle the sign.

**Registration refuses a capture its own warnings say it will emit.** When every
component fails BA, `registration.cpp` returns an error while the report it
built says "the result is emitted with an honest number rather than withheld".
Architecture §8 says a low-texture frame falls back to its IMU prior and is
flagged, never dropped. `low_texture` now takes that path, so the contradiction
is live.

**Math §8's half-step stagger is necessary and not sufficient.** Rings `+k` and
`−k` have the same shot count and the same step, so any offset built from step
parity gives them identical yaw sets; and two rings of *different* count can
still coincide by arithmetic accident (at h = 46°, the 12-shot equator and the
10-shot ring above it both shot −90°). The plan builder adds a quarter step on
the southern rings and an irrational nudge per level. Cost: S5a/b/c move by
under 0.15 pp.

**The quality-gate baselines are stale by construction, and were not
re-recorded.** The shooting order is part of the plan, and the synthetic rig
seeds its per-position noise by *shooting index* — so reordering re-shuffles
which target gets which noise realisation. `pristine` `s3_wrap` 5.600 → 6.051,
`harsh_imu` `tilt` 0.735 → 0.837, `nominal` `s1` → ~9.0 (confounded by the known
HDR non-determinism), and `low_texture` tipped from "S1 28 px, 74% IMU-only" to
"no component converges", so it now refuses instead of producing a bad
panorama. Coverage did not move. Re-recording is a deliberate act with its own
reason attached, and one profile changed *behaviour* rather than numbers, so the
decision is left open.

### Found while writing Phase 09

**The target dot belongs to the preview, not to the screen.**
`GuidanceState.targetScreenOffset` is a fraction of the *frame's* half-extent
(Phase 08 §3), and §2's full-bleed preview is cover-fitted — so on a 3:4 sensor
behind a 1:2 display the frame is 50% wider than the canvas. Mapping the offset
onto the canvas puts the dot several degrees from the thing it is pointing at on
every device whose display and sensor aspect ratios differ, which is all of
them, and it looks like a perfectly plausible dot while doing it. The painter
now resolves the cover-fitted preview rectangle and places the dot in that.

The same crop produces a second case the guidance engine cannot see: a target
that is inside the frame but outside the *display*. It reports no edge arrow —
correctly, it knows nothing about the crop — so the painter falls back to the
arrow whenever the mapped dot would be clipped. Otherwise the one state that
shows nothing at all is the state where the user is nearly there.

**§2 and §4 disagree about the retake list, and §4 won.** §2's progress
paragraph ends "tap the counter to reveal a list of positions with retake
buttons — hidden by default"; §4's constraints table says "nothing interactive
in the top half", and the counter is top-right by the same §2. The list is
therefore *not* on the capture screen: retakes live on the review screen
(§3.3's "Retake position…"), and `SphereCaptureSession.retake` was already the
mechanism either way. The cost is one extra step to re-shoot a position mid-walk;
the alternative was a touch target under the hand that holds the tablet, in the
half of the screen the user is not supposed to be looking at.

**A two-tone progress bar cannot survive both extremes.** Whichever two tones
are picked, one of them is the background: white filled segments vanish on a
sunlit wall, dark pending ones vanish on an unlit ceiling. The bar is now a dark
plate with a white border, with white segments on it — presence versus absence
rather than shade versus shade. The golden tests over pure white and pure black
caught this on their first run, before any of it reached a device, which is the
argument for having them.

**`ω`, `1/cos φ` and the aim tolerance appear nowhere in the UI.** Phase 09 §5
says `SphereCaptureView` makes no decisions and to "assert by review"; a test
now also greps the file for Phase 08's vocabulary. Review is still what proves
the property, but the grep catches the way it actually degrades — a threshold
copied into a build method during a hurried fix, which then drifts from the one
the shutter gate uses and presents as a stitcher bug months later.

**Zero per-frame allocations rules out more of Flutter's drawing API than it
looks like.** `Rect.center`, `Offset`, `Color.withValues` and `Path` are all
allocations, and the overlay repaints on every pose sample while the device runs
a camera, a sensor stream and a JPEG burst. The paint path now translates the
canvas instead of constructing offsets, indexes a nine-step pre-built ramp
instead of computing a flash colour, and draws cached `ui.Paragraph`s rebuilt
only when their text changes — which for the counter is 29 times a session and
for the instruction line a few dozen, against 100 times a second.

### Two findings from Phase 02, and how they were resolved

Both came from the coverage rasteriser on its first run, and both are geometry,
not opinion — see `lib/src/plan/plan_builder.dart` and `coverage_validator.dart`.

**1. `ω = 0.33` cannot satisfy S5's "≥95% covered ≥2×" — and S5 was the thing
that was wrong.** Measured across three realistic main-camera intrinsics,
`ω = 0.33` gives 100% / ~80% at 28–34 positions; reaching 95% needs `ω = 0.45`
and 34–43 positions.

Resolved by fixing the criterion, not the plan. In one dimension the
double-covered fraction is exactly `ω/(1−ω)`, so demanding 95% *is* demanding
`ω = 0.487` — while Math §8 defaulted to 0.33 twelve lines later. The
contradiction is proof the 95% was never derived. Matching needs pairwise
overlap (0.33 beats the 20–30% every production stitcher works at); seam routing
and blending need band *width* (~280 px at 6144 wide — a 5-band blend needs ~32);
and frame-drop redundancy is handled in Phases 03 and 08, not by shooting more.
Paying +25% capture time and +30% stitch frames for it would have broken S7 and
squeezed S8 to buy nothing. **S5 is now S5a/b/c** — see Math §8.

**2. A *single* polar shot cannot cover the poles twice.** The caps above ±70°
are ~6% of the sphere's area and one polar frame covers them exactly once. This
one was a real gap in the arithmetic, and the fix stands: **two frames per pole,
the second rolled 90°** — one extra shutter each, and the poles are precisely
where warping is most extreme and frame-edge quality worst, so redundancy there
is worth more than anywhere else.

Neither is a defect in the document's *method*; both are cases Math §8 defers to
the validator, which is exactly what it says to do — "`coverage_validator` is the
gate, not this arithmetic". The first one is a reminder that a criterion can be
wrong too.
