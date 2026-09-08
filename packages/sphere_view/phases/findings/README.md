# Findings

Research and spike results, one file per question.

See [../RESEARCH_QUESTIONS.md](../RESEARCH_QUESTIONS.md) for the prompts and the
expected file format.

| File | Question | Status |
|---|---|---|
| [`R1_opencv_distribution.md`](R1_opencv_distribution.md) | How do we ship OpenCV `stitching` to iOS + Android? | ✅ **research done** — 6 items left for Spike A |
| [`R2_intrinsics.md`](R2_intrinsics.md) | Camera intrinsics + distortion availability and semantics | ✅ **research done** — 4 items left for Spike B |
| [`R3_bracketing.md`](R3_bracketing.md) | Bracketed burst support and latency | ✅ **research done** — 6 items left for Spike C |
| `R4_registration.md` | Registration approach for low-texture interiors | ⬜ deferred — only if `low_texture` misses Phase 03 targets |
| ~~`R5_ar_tracking.md`~~ | ~~ARCore coverage + walk detection~~ | ❌ dropped with Phase 14 |

## Headlines

- **R1** — build OpenCV from source with a minimal module list and write our own
  `extern "C"` shim. No off-the-shelf channel works: `dartcv4` exposes zero
  `cv::detail::` and cannot force a 360×180 canvas, which is an API gap rather than
  a size gap. **`GraphCutSeamFinder` needs no external max-flow library** — this
  closed the project's largest risk. Licensing clean Apache 2.0 throughout.
- **R2** — `videoFieldOfView` is **horizontal**; Android `LENS_DISTORTION` → OpenCV
  is a **pure reorder**. Both original risks closed. But calibrated intrinsics need a
  multi-camera device, which **excludes base iPad / Air / mini**, so intrinsics
  quality is a gradient the registration stage must tolerate.
- **R3** — Camera2 still correct; native HDR extensions unusable; iOS brackets do
  **not** auto-lock AF/AWB. **No source anywhere publishes a measured burst time**,
  so the 600 ms budget the HDR strategy rests on is unverified — the highest-priority
  Phase 00 measurement.

## Spike results go here too

Phase 00 **appends** its hardware measurements to these same files rather than
creating new ones — the research and the measurement belong together. Every
measurement must name the device it came from.
