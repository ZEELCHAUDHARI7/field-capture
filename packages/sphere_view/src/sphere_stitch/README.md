# `src/sphere_stitch` — the native pipeline

Shared C++ for both platforms. Stages 5–15 of the pipeline in
[`phases/00_ARCHITECTURE.md`](../../phases/00_ARCHITECTURE.md) §4 live here,
behind one `extern "C"` shim.

Native is unavoidable rather than preferred: graph-cut seam finding needs
max-flow over a large lattice, and SIFT plus bundle adjustment in Dart would be
10–50× too slow with a lower quality ceiling (§5). R1 established that no
off-the-shelf OpenCV channel exposes `cv::detail::` at all — prebuilts are
all-module "world" builds, CocoaPods died at 4.3.0, there is no official SPM,
and `dartcv4` exposes zero `cv::detail::` and cannot force a 360×180 canvas — so
the shim is ours regardless of binary-size concerns.

| File | Stages | Lands in |
|---|---|---|
| `sphere_stitch.h` | the C ABI: JSON in, file out, progress via shared memory | Phase 03 |
| `sphere_stitch.cpp` | stage orchestration + progress + cancellation | Phase 03 |
| `hdr_fuse.cpp` | 5 — ECC align, Mertens fusion | Phase 05 |
| `registration.cpp` | 6–9 — undistort, SIFT, IMU-gated matching, bundle adjustment | Phase 03 |
| `compositing.cpp` | 10–13 — warp, gain comp, graph-cut seam, strip blending | Phase 04 |
| `pole_fill.cpp` | 14 — push–pull pyramid fill | Phase 04 |
| `report.cpp` | S1–S5 metric computation | Phase 03 |
| `CMakeLists.txt` | the build, shared by Android NDK, Xcode and desktop replay | Phase 00 Spike A |

Two constants here are load-bearing and documented in §7: the blender runs in
padded horizontal strips (pad `2^bands · 4 = 128 px`, giving bit-identical
output at 1/N the memory), and the canvas carries 256 px of duplicated wrap
padding so the ±180° meridian closes.

The OpenCV module list, settled by R1:
`core, imgproc, imgcodecs, flann, features2d, calib3d, photo, video, stitching`.
