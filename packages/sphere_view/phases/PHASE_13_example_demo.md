# Phase 13 — Example demo app & package release

**Goal:** an example app that demonstrates the whole package end to end, and a
package clean enough to drop into another project.

**Duration:** 2–3 days. **Depends on:** everything.

This replaces the former field-prototype integration phase. `sphere_view` stays a
standalone package with **no application dependency**; the example app is the
demo and the integration reference.

---

## 1. The example app

`example/` — one screen, three actions, no chrome. It exists to prove the package
works and to show a future integrator exactly how to call it.

```
┌──────────────────────────────────┐
│  sphere_view demo                │
│                                  │
│  [   Capture a 360°   ]          │
│                                  │
│  ── Captured ──────────────      │
│  ┌────┐ Station 1                │
│  │ ▦  │ 6144×3072 · ready        │
│  └────┘ SSIM n/a · 0.98 coverage │
│  ┌────┐ Station 2                │
│  │ ▦  │ stitching… 42%           │
│  └────┘                          │
│  ┌────┐ Station 3                │
│  │ ▦  │ queued                   │
│  └────┘                          │
│                                  │
│  [ Device report ]  [ Clear ]    │
└──────────────────────────────────┘
```

### Flows to demonstrate

1. **Capture** → the full guided session (Phase 09), including the pre-capture
   pivot instruction and the metering sweep.
2. **Background queue** → capture two or three spheres back to back without
   waiting. This is the behaviour that matters most for the real use case, and it
   is the easiest thing to accidentally break, so make it visible: rows show
   `queued → stitching N% → ready`.
3. **View** → tap a ready row to open the viewer (Phase 11), with gyro look
   toggleable.
4. **Report** → tap the metrics line to show the full `StitchReport`: all of
   S1–S5, the intrinsics source, the tier used, and every warning in plain
   language. This is the demo's most useful screen for anyone evaluating quality.
5. **Share / export** → export the equirect so it can be opened in Google Photos
   to prove the GPano metadata works (S10).
6. **Device report** → the capability probe output (Phase 12 §1): detected tier,
   `SphereCapability`, intrinsics source and values, whether bracketing is
   available, measured burst time. One screen that answers "will this work on my
   tablet".
7. **Resume** → kill the app mid-session and reopen; the partial bundle resumes.
   Include a debug button to simulate the kill.

### Explicitly out of scope

No plan viewer, no PDF, no map, no auth, no backend. Those belong to the consuming
app. The demo's job is to exercise the package's public API and nothing else.

---

## 2. Package release readiness

- **`pubspec.yaml`** — correct description, `homepage`/`repository`, topics
  (`camera`, `panorama`, `360`, `photosphere`), version `0.1.0`.
- **Public API audit** — everything in the Phase 01 §4 barrel and nothing else.
  Anything under `src/` must be genuinely private; check no `src/` type leaks into
  a public signature.
- **`dart doc` clean** — no warnings; every public member documented.
- **`flutter analyze`** clean under a strict `analysis_options.yaml`.
- **`README.md`** — the real quickstart (must compile as a test), platform setup
  (permissions, minimum SDK versions, the OpenCV build step from the R1 finding),
  device requirements, and the honest limits from `phases/README.md`.
- **`CHANGELOG.md`** — with the quality baselines this version was measured at.
- **Permissions documented**: `NSCameraUsageDescription`,
  `NSMotionUsageDescription` (iOS); `CAMERA`, `HIGH_SAMPLING_RATE_SENSORS`
  (Android). Missing `NSMotionUsageDescription` is a silent no-pose failure on iOS.
- **Minimum versions stated**: the R2 and R3 findings pin these — Android API 28+
  for `LENS_DISTORTION`, and whatever iOS version the confirmed intrinsics path
  requires.
- **Native build instructions** — the OpenCV build from the R1 finding must be
  reproducible by someone who is not you, from a clean checkout. Script it; do not
  document it as prose steps.

---

## 3. Integration guide

`docs/INTEGRATION.md` — the document a future consuming app reads instead of this
phase. Because the field integration is now out of scope, this is where that
knowledge lives:

- the three-call quickstart (`create` → `SphereCaptureView` → `SphereStitcher`)
- how to run the stitch in the background queue and observe state
- what to persist: `equirectPath`, `thumbnailPath`, `StitchReport`, and the
  heading — and **why the heading is worth sourcing from the host app** rather
  than the magnetometer (Phase 11 §2). For a plan-based app, the drawn path's
  tangent is far more accurate indoors than any compass reading
- storage policy guidance: delete the `CaptureBundle` on a stitch that meets
  quality targets; **keep it when it does not**, so it can be re-stitched after a
  pipeline improvement without returning to site
- the capability-probe gate: check before offering the feature, not mid-flow

---

## 4. Tests

- example app builds and runs on iOS and Android
- example app completes a full capture → queue → stitch → view cycle on real
  hardware
- the README quickstart compiles (as a test, not by eye)
- no `src/` type appears in any public API signature (automated check)
- `dart doc` produces zero warnings
- a fresh clone builds the native library from the scripted OpenCV step
- exported equirect opens as a sphere in Google Photos (manual, once)

---

## Exit criteria

- [ ] Example app demonstrates all seven flows in §1
- [ ] Two spheres captured back to back without waiting for the first stitch
- [ ] `StitchReport` screen shows every metric and warning
- [ ] Public API audit passes; no `src/` leakage
- [ ] Fresh clone builds, including the native OpenCV step, by scripted steps only
- [ ] `docs/INTEGRATION.md` written
- [ ] `dart doc` and `flutter analyze` clean
