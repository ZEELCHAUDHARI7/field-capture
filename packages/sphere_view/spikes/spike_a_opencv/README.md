# Spike A — OpenCV build

Throwaway. Produces the numbers in the "Phase 00 Spike A — measured" section of
`phases/findings/R1_opencv_distribution.md`.

## Reproduce from clean

```bash
./build_android.sh          # both ABIs, ~2 min each
./build_android.sh --lto    # ThinLTO variant
./build_ios.sh              # device arm64
./measure.sh                # the table that goes into R1
./measure_ios_link.sh       # iOS post-link, post-strip delta
```

Nothing else is required — the scripts download OpenCV themselves and use the
toolchains that Flutter already needs (Android SDK's CMake, the NDK, Xcode).
Everything version-pinned lives in `config.sh`.

## What each file is for

| File | Purpose |
|---|---|
| `config.sh` | Every pin and flag, with the reasoning inline |
| `build_android.sh` | Static OpenCV → link probe → strip → measure, per ABI |
| `build_ios.sh` | Same, driving cmake directly (see below) |
| `measure.sh` | Sizes, 16 KB alignment, `cv::detail::` presence, runtime deps |
| `measure_ios_link.sh` | iOS size delta without needing a signed archive |
| `probe/sv_spike_probe.cpp` | The on-device probe — *executes* each algorithm |
| `work/` | Downloads and build trees. Delete freely |
| `out/` | Built `.so` files and measurements |

## Three things worth knowing before you touch this

**iOS does not use `build_framework.py`.** In OpenCV 4.13.0 that script has no
`BUILD_LIST` support *and* silently discards every extra `-D` argument, so it
cannot carry the codec selection or the `-Os`/`--gc-sections` flags the size
argument depends on. `build_ios.sh` drives cmake and the shipped iOS toolchain
directly instead, mirroring `build_android.sh`. The full comparison of the three
approaches PHASE_00 asked us to try is in the R1 findings.

**`IPHONEOS_DEPLOYMENT_TARGET` must be exported, not passed as `-D`.**
`common-ios-toolchain.cmake` is re-included inside CMake's `try_compile`
sub-project, which does not inherit cache entries, and hard-errors without it.

**LTO does not go through `CMAKE_INTERPROCEDURAL_OPTIMIZATION`.** CMake 3.22
implements IPO for Android by emitting `-fuse-ld=gold`, and NDK r28 no longer
ships gold. `build_android.sh --lto` passes `-flto=thin` and pins lld instead.

## Running the probe on a device

The library is not checked in. To exercise it on hardware:

```bash
./build_android.sh
mkdir -p ../spike_bc_device/android/app/src/main/jniLibs/arm64-v8a
cp out/android/base/arm64-v8a/libsv_spike.so \
   ../spike_bc_device/android/app/src/main/jniLibs/arm64-v8a/
```

Then rebuild `spike_bc_device` and run it; the `spikeA_opencv` section of its
report fills in. Dart reaches `sv_spike_opencv_probe` over FFI, which is how the
real plugin will call it too — not JNI.

## Why the probe executes rather than constructs

`PHASE_00_spikes.md`'s snippet constructs each class and reports `y`. That is a
weak proof under our build configuration: with `-ffunction-sections` and
`--gc-sections`, a default constructor can survive while the algorithm body is
stripped, and several of these classes construct fine then fail at first use
when an optional dependency is missing.

So each probe runs the real algorithm on a small synthetic input and reports a
result value — SIFT keypoint count, graph-cut mask coverage, blended output
dimensions, ECC correlation, JPEG round-trip error. The graph-cut probe
additionally asserts that the masks actually changed, because a seam finder that
silently makes no cut would otherwise report success.
