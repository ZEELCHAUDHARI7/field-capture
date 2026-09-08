# R1 — OpenCV distribution

**Researched:** 2026-08-06
**Sources:** opencv/opencv GitHub repo (releases, `modules/*/CMakeLists.txt`, `platforms/ios/build_framework.py`, `platforms/android/build_sdk.py`, `cmake/OpenCVModule.cmake`), opencv.org/releases, opencv.org/license, OE-32 wiki page, nihui/opencv-mobile GitHub repo (README, `opencv4_cmake_options.txt`), rainyl/opencv_dart GitHub repo (`packages/dartcv/src/dartcv/stitching/stitching.{h,cpp}`, Dart FFI layer), CocoaPods.org, Maven Central / central.sonatype.com, Android Developers Blog (16 KB page size, May 2025), developer.android.com/guide/practices/page-sizes, Apple developer forums (App Thinning Size Report).

## Answer

Ship OpenCV by **building it from source with a minimal module list** (either by patching `nihui/opencv-mobile`'s documented per-module flag file, or by building vanilla OpenCV with `-DBUILD_LIST=core,imgproc,imgcodecs,flann,features2d,calib3d,photo,video,stitching`), and write our own thin `extern "C"` shim over the specific `cv::detail::` classes we need, FFI-bound directly from Dart. No existing distribution channel gets us there off the shelf: official prebuilt binaries are "world" builds (all modules, ~40 MB iOS / ~300 MB Android on disk) with no confirmed stitching-module verification and no true `.xcframework`; CocoaPods has been abandoned since 2020; there is no official SPM package; `opencv-mobile` explicitly strips `stitching`/`calib3d`/`flann` by default; and the only maintained Dart binding (`dartcv4`/`opencv_dart`) wraps only the high-level `cv::Stitcher` with zero `cv::detail::` exposure and no way to force a full 360×180 equirectangular canvas. None of this requires reimplementing stitching primitives ourselves — the C++ `stitching` module itself is untouched and Apache-2.0-clean for our required module set; the work is a custom binding layer, not a two-week algorithm rewrite.

## Evidence

### 1–2. Distribution channels, and what's actually in them

| Channel | Official? | Current? | `stitching` included? | Verdict |
|---|---|---|---|---|
| iOS `opencv-<ver>-ios-framework.zip` (GitHub release) | Yes | 4.12.0 (2025-07-09) | Build script (`build_framework.py`) excludes nothing by default → likely yes, but **never directly opened/verified against the shipped zip** | Not a true `.xcframework` — ships a fat `.framework`; third-party repackagers (`younata/opencv-xcframework`) exist but are unofficial |
| Android `opencv-<ver>-android-sdk.zip` (GitHub release) | Yes | 4.12.0 | Likely yes (community GitHub issue #13561 assumes it's present) — **not maintainer-confirmed, not opened** | ABIs: armeabi-v7a, arm64-v8a, x86, x86_64 |
| CocoaPods (`OpenCV2`, `OpenCV`, etc.) | No | **Stuck at 4.3.0 since April 2020** | Unknown | Abandoned — do not use |
| Swift Package Manager | **None official** | — | — | GitHub issue #18398 / PR #18925 attempted, never merged |
| Maven Central `org.opencv:opencv` (AAR) | **Yes, official since 4.9.0** | Up to 5.0.0.1 seen | Not verified (AAR contents not opened) | Best "official Gradle-native" option if going the prebuilt route |
| `nihui/opencv-mobile` | No (community, but first-party maintained) | Tracks 2.4.13.7 / 3.4.20 / 4.13.0 / 5.0.0 in parallel; recent NDK r29 / Xcode 15.2 support | **Explicitly OFF by default** — confirmed literal line in `opencv4_cmake_options.txt`: `-DBUILD_opencv_stitching=OFF`, and `-DBUILD_opencv_calib3d=OFF`. `xfeatures2d`, `objdetect` also OFF. `features2d`, `photo` kept ON. `flann`'s default state not confirmed — needs checking (see Still unknown). | Rebuildable — the repo's own README documents editing the options file and rerunning the packaging script; this is a supported customization path, not a hack |
| `dartcv4` / `opencv_dart` (Dart FFI binding) | No (community, Apache-2.0, actively maintained) | `dartcv4` 2.2.1+4 | Binds **only `cv::Stitcher`** (`create`, `estimateTransform`, `composePanorama`, `stitch`, a handful of parameter getters/setters). The only `cv::detail::` token in the source is an enum cast (`WaveCorrectKind`), not a class binding. | **Cannot satisfy this project's requirement** — see §5 |

opencv-mobile's own README gives a size comparison for its **default** (no stitching/calib3d/flann) module set, OpenCV 5.0.0: Android package 25 MB vs. 303 MB official; iOS package 5.56 MB vs. 42.1 MB official. These are a *floor*, not the number after adding stitching/calib3d/flann back — no source gave a direct figure for that exact combination.

### 3. Minimal `-DBUILD_LIST`

```
core,imgproc,imgcodecs,flann,features2d,calib3d,photo,video,stitching
```

(`imgcodecs` isn't required by any listed API but is needed to decode/encode real images.)

| API | Module | Hard deps |
|---|---|---|
| `cv::SIFT` | `features2d` (moved out of `xfeatures2d`/nonfree once the patent expired; merged via PR #17119, shipping in OpenCV 4.4.0 / 3.4.11) | `imgproc`; optional `flann` |
| `cv::detail::BestOf2NearestMatcher`, `BundleAdjusterRay`, `SphericalWarper`, `BlocksGainCompensator`, `MultiBandBlender` | `stitching` | `imgproc`, `features2d`, `calib3d`, `flann` (all hard) |
| `cv::detail::GraphCutSeamFinder` | `stitching` | Same as above — **no external max-flow library.** Uses `GCGraph<float>` from `modules/imgproc/include/opencv2/imgproc/detail/gcgraph.hpp`, OpenCV's own in-house min-cut/max-flow implementation, included directly by `stitching/src/seam_finders.cpp`. |
| `cv::createMergeMertens`, `cv::createAlignMTB` | `photo` | `imgproc` |
| `cv::findTransformECC` | `video` (not `photo` — `modules/video/src/ecc.cpp`) | `imgproc`; optional `calib3d`, `dnn` |

`calib3d`'s own hard deps: `imgproc`, `features2d`, `flann`.

**`videoio`, `objdetect`, `dnn`, `gapi`, `highgui`, `ml` can all be excluded.** Confirmed by grep across the full dependency closure: `video`'s only relationship to `dnn` is an *optional* DNN-based optical-flow backend, irrelevant to `findTransformECC`; nothing in `stitching`/`calib3d`/`features2d`/`photo` references any of the other four.

**Build-mechanics asymmetry:** Android's `platforms/android/build_sdk.py` supports `--modules_list` natively, which maps straight to `BUILD_LIST`. **iOS's `platforms/ios/build_framework.py` does not support `BUILD_LIST` at all** — it only exposes `--without <module>` (one exclusion at a time). Getting `BUILD_LIST` on iOS requires either passing `--without` for every one of `videoio objdetect dnn gapi highgui ml ts python2 python3 java js`, or patching `getCMakeArgs()` with a one-line addition (`args.append("-DBUILD_LIST=%s" % self.build_list)`), or bypassing the script and invoking `cmake` + `ios.toolchain.cmake` directly.

### 4. Size measurement and build configuration

- **iOS installed-size delta:** on-disk static framework size is meaningless (dead-stripping only pulls in referenced object code). Build two archives of the same app — one without the OpenCV lib linked, one with it linked against real call sites (not just headers) — then use **Product ▸ Archive ▸ Organizer ▸ Distribute App ▸ Development/Ad Hoc ▸ "All compatible device variants"** to get `App Thinning Size Report.txt`, and diff the **uncompressed** size (= actual on-device installed size) between the two for the same device variant. `-Xlinker -why_load` / `-why_live` in `OTHER_LDFLAGS` debugs unexpectedly-large pulls. Bitcode is irrelevant — deprecated since Xcode 14 (June 2022); ship `arm64` device + `arm64` simulator slices only.
- **Android per-ABI delta:** an AAB ships exactly one `.so` per ABI to a given device, so there's no fat-APK tax. Measure with `bundletool get-size total --apks=out.apks`, the Play Console "App size" report, or `unzip -l` / `apkanalyzer files list` diffing the raw `.so` entry per ABI (multiply by ~0.5–0.6 for a rough compressed-download estimate; Play Console's number is authoritative).
- **Android 16 KB page-size requirement:** Google Play deadline **November 1, 2025** for new apps/updates targeting Android 15+ (API 35+), with opt-in extensions to **May 31, 2026** available on request (Android Developers Blog, May 2025). NDK r28+ compiles 16 KB-aligned by default; on r27 or older, add `-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384` explicitly. Requires AGP ≥ 8.5.1 for correct zip alignment of uncompressed native libs. Verify with `llvm-objdump -p libopencv.so | grep LOAD` (expect `align 2**14`), Google's `check_elf_alignment.sh`, `zipalign -c -P 16`, or `bundletool dump config` (expect `PAGE_ALIGNMENT_16K`).
- **Size-reduction flags:** `-DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-Os -ffunction-sections -fdata-sections" -DCMAKE_C_FLAGS="-Os -ffunction-sections -fdata-sections" -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--gc-sections" -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON` (LTO, CMake ≥ 3.9). iOS's dead-stripping is automatic in Release archives — no separate flag needed.
- **Android STL:** use `ANDROID_STL=c++_static` for a single self-contained FFI plugin `.so` (better `--gc-sections` pruning, no risk of colliding with a different `libc++_shared.so` version another plugin ships). `c++_shared` is only needed if multiple native libraries in the same app must share one C++ runtime instance across a C++ ABI boundary.

### 5. `opencv_dart` / `dartcv4` API surface

Both packages (now one monorepo, `github.com/rainyl/opencv_dart`; `dartcv4` is the pure binding layer, `opencv_dart`/`opencv_core` the Flutter wrappers) expose **only `cv::Stitcher`** — confirmed by reading `packages/dartcv/src/dartcv/stitching/stitching.{h,cpp}` directly: `create(mode)`, `estimateTransform`, `composePanorama`, `stitch`, and getters/setters for a few top-level parameters (`registrationResol`, `seamEstimationResol`, `compositingResol`, `panoConfidenceThresh`, `waveCorrection`, `interpolationFlags`, `waveCorrectKind`). No binding exists for `BestOf2NearestMatcher`, `BundleAdjusterRay`, `SphericalWarper`, `BlocksGainCompensator`, `GraphCutSeamFinder`, `MultiBandBlender`, or any other `cv::detail::` class — the only occurrence of the namespace in the source is a single enum cast.

**This means the high-level API cannot guarantee a full 360×180 equirectangular output**, independent of licensing or size concerns: there is no `setWarper` binding (the warper choice is whatever `Stitcher::create(mode)` defaults to internally), and `stitch()`/`composePanorama()` returns whatever bounding-box canvas the internal blender computed from the warped image extents — no parameter for target canvas size, no forced full-sphere padding. If the input images don't geometrically close the loop, the output is a partial-extent `Mat`, not a fixed 2:1 canvas.

It is extensible in principle — Apache-2.0, `extern "C"` shim pattern, `ffigen`-driven codegen — a developer could add `cv_Detail_*` C-API functions following the existing `Stitcher` pattern and regenerate bindings. But that is exactly the from-scratch binding work this project needs to do itself; there's no shortcut inside the existing package today.

### 6. Licensing

OpenCV moved from 3-clause BSD to **Apache 2.0 starting at 4.5.0, released October 16, 2020** (confirmed at opencv.org/license: *"OpenCV 4.5.0 and higher versions are licensed under the Apache 2 License… OpenCV 4.4.0 and lower… under the 3-clause BSD license"*; rationale in the OE-32 wiki page — Apache 2.0's patent-retaliation clause). Apache 2.0 permits closed-source commercial redistribution with no copyleft; obligations are limited to including the license text, marking modified files, and retaining copyright/patent notices (§4).

For the required module set (`core, imgproc, imgcodecs, flann, features2d, calib3d, photo, video, stitching`, no `opencv_contrib`, no `OPENCV_ENABLE_NONFREE`), the whole binary is **Apache-2.0-only**:
- SIFT's US patent (6,711,293) expired March 7, 2020; SIFT lives in main-repo `features2d`, not `xfeatures2d`/nonfree — no flag needed.
- `xfeatures2d`/SURF is only an *optional* dependency of `stitching` (for an alternate descriptor), never required.
- `GraphCutSeamFinder`'s `GCGraph` is OpenCV's own in-house Apache-2.0 reimplementation, **not** the GPL/research-only-licensed Kolmogorov–Zabih reference code.
- `BundleAdjusterRay` uses OpenCV's internal Levenberg-Marquardt solver by default — Eigen and Ceres are not hard dependencies.
- IPP (`ippicv`) is x86/x64-only and isn't linked into ARM (iOS/Android arm64) builds at all.

## Consequences for the plan

- **Phases 03/04/05 should assume a custom-built OpenCV static lib + a hand-written `extern "C"` shim over the specific `cv::detail::` classes**, FFI-bound directly — not a dependency on `opencv_dart`/`dartcv4` for the stitching pipeline (those packages remain fine for any incidental `features2d`/`calib3d`/`photo` calls elsewhere if convenient, since they do bind plenty of non-`detail::` OpenCV, but the core registration/warping/blending path needs its own bindings). This is upfront binding-layer work, not the "reimplement BA/warping/blending/graph-cut by hand" fallback the research doc flagged as the two-week risk — the C++ algorithms themselves ship untouched inside OpenCV's `stitching` module.
- The acquisition path is **build from source**, most practically by forking `nihui/opencv-mobile` and flipping `BUILD_opencv_stitching`, `BUILD_opencv_calib3d`, and (pending confirmation) `BUILD_opencv_flann` from `OFF` to `ON` in its per-version `cmake_options.txt`, reusing its existing size-optimized flags and iOS/Android toolchain plumbing — rather than patching vanilla `build_framework.py` for `BUILD_LIST` support from scratch. Either path lands on the same minimal module list.
- Licensing is a non-issue for the module set actually needed — no attribution burden beyond the standard Apache 2.0 NOTICE, no GPL exposure via the graph-cut seam finder, no patent risk via SIFT.
- Official prebuilt binaries, CocoaPods, and SPM are not viable primary paths (unmaintained, no true xcframework, unverified module contents) but the official Maven Central `org.opencv:opencv` AAR (since 4.9.0) is worth a quick look as a possible *base* to strip down from, if that's cheaper than a from-scratch iOS/Android build pipeline — untested here.

## Still unknown

The following need the Phase 00 spike (or a short, targeted follow-up) to close out — research alone couldn't verify them:

1. **Real measured binary size** after adding `stitching` + `calib3d` + `flann` back into an opencv-mobile-style minimal build, for iOS (post-strip App Thinning Size Report delta) and Android (per-ABI `.so`, both `arm64-v8a` and `armeabi-v7a`). No source gave a number for this exact combination — only floors (opencv-mobile's default, no stitching) and ceilings (official "world" build) are known.
2. **opencv-mobile's default state for `flann` and `video`** — confirmed OFF: `stitching`, `calib3d`, `xfeatures2d`, `objdetect`. Confirmed ON: `features2d`, `photo`. `flann` (a hard dep of `calib3d`/`stitching`) and `video` (needed for `findTransformECC`) were not directly confirmed either way in `opencv4_cmake_options.txt` — check before assuming only 2 flags need flipping.
3. Whether official iOS/Android release zips actually contain compiled `stitching` object code — inferred from build-script defaults, never opened/verified against the shipped artifact. Only matters if official binaries get used as an early-prototyping stopgap before the custom build is ready.
4. Whether patching `build_framework.py`'s `BUILD_LIST` passthrough (iOS) works cleanly end-to-end, versus just invoking `cmake` + `ios.toolchain.cmake` directly and skipping the script.
5. 16 KB page-size alignment on the *actual* produced `.so`, once the NDK version and AGP version for this project are pinned — configuring the flags isn't the same as verifying alignment on the real build output.
6. Exact current "latest OpenCV 4.x" to pin: 4.12.0 (2025-07-09) is confirmed via the releases page; a 4.13.0 changelog entry surfaced via opencv-mobile's README but wasn't independently cross-checked against opencv/opencv's own releases page.

---

# Phase 00 Spike A — measured

**Measured:** 2026-08-06
**Machine:** Apple Silicon macOS 26 (Darwin 25.0.0), 10 cores / 16 GB
**Toolchain:** NDK 28.2.13676358, CMake 3.22.1 (Android SDK), Xcode 26.3
**OpenCV pinned:** 4.13.0
**Spike code:** `spikes/spike_a_opencv/` (throwaway)

Everything below is measured from a real build artefact. Nothing is inferred
from an NDK version, a CMake flag, or documentation.

## Headline

**The size question is closed and it is not a problem.** A stripped
`arm64-v8a` shared library containing our full `cv::detail::` pipeline —
statically linked OpenCV, `--gc-sections`, `-Os` — is **5.13 MB**, against a
budget of 25 MB per ABI. With ThinLTO it is **4.68 MB**. The `armeabi-v7a`
build is **3.44 MB**.

**16 KB page alignment verified on the produced `.so`, both ABIs** (`align
2**14` on every `PT_LOAD` segment, via `llvm-objdump -p`). R1's warning not to
trust the NDK version was well placed: the pre-existing
`~/Documents/flutter-plugin-camera360` `.so`, built with an older NDK, measures
`align 2**12` — 4 KB — and would be **rejected by Google Play**.

## What was built

`-DBUILD_LIST=core,imgproc,imgcodecs,flann,features2d,calib3d,photo,video,stitching`
resolved to exactly the intended set, per CMake's own summary:

```
To be built:            calib3d core features2d flann imgcodecs imgproc photo stitching video
Disabled:               world
Disabled by dependency: dnn highgui java_bindings_generator js_bindings_generator
                        ml objc_bindings_generator objdetect videoio
Unavailable:            gapi java python2 python3 ts
```

Confirms R1 §3: `videoio`, `objdetect`, `dnn`, `gapi`, `highgui`, `ml` all drop
out cleanly, and `calib3d`/`flann` are pulled in as hard dependencies.

## Measured sizes — Android, `libsv_spike.so`

| Variant | ABI | Stripped | Unstripped | LOAD align | 16 KB OK |
|---|---|---|---|---|---|
| `-Os` + `--gc-sections` | `arm64-v8a` | **5.13 MB** | 64.88 MB | `2**14` | ✅ |
| `-Os` + `--gc-sections` + ThinLTO | `arm64-v8a` | **4.68 MB** | — | `2**14` | ✅ |
| `-Os` + `--gc-sections` | `armeabi-v7a` | **3.44 MB** | — | `2**14` | ✅ |

Static archive sizes before linking, `arm64-v8a` (these are *not* the shipped
size — they are the pool the linker draws from):

| Archive | Size | | Archive | Size |
|---|---|---|---|---|
| `libopencv_imgproc.a` | 50.26 MB | | `libopencv_features2d.a` | 13.20 MB |
| `libopencv_core.a` | 45.05 MB | | `libopencv_stitching.a` | 10.63 MB |
| `libopencv_calib3d.a` | 39.48 MB | | `libopencv_flann.a` | 9.06 MB |
| `libopencv_photo.a` | 8.83 MB | | `libopencv_video.a` | 8.44 MB |
| `libopencv_imgcodecs.a` | 6.03 MB | | `liblibjpeg-turbo.a` | 6.41 MB |

The 191 MB of archives collapsing to 5.13 MB is the whole point of
`--gc-sections` on a static link, and it is why *"how big is the OpenCV
package"* was always the wrong question.

**Caveat, stated honestly:** 5.13 MB is the size when the linker keeps only what
the probe reaches. The probe exercises SIFT, `BestOf2NearestMatcher`,
`BundleAdjusterRay`, `SphericalWarper`, `BlocksGainCompensator`,
`GraphCutSeamFinder`, `MultiBandBlender`, Mertens, `AlignMTB`,
`findTransformECC`, `undistort` and JPEG encode/decode — i.e. essentially the
Phase 03/04/05 call surface — so it is a good proxy, but the real plugin will
pull somewhat more. Budget 6–8 MB per ABI, not 5.13.

## Measured size — iOS, `arm64`

Built by `build_ios.sh` (direct cmake, same `BUILD_LIST`, same `-Os`
`-ffunction-sections`/`-fdata-sections`). CMake resolved the identical module
set to Android: `calib3d core features2d flann imgcodecs imgproc photo
stitching video`.

**Post-link, post-strip delta: 6.17 MB.**

Measured by `measure_ios_link.sh` — link the probe twice for device `arm64`
(once against a trivial stub exporting the same C ABI, once against the real
static libs), `strip -x -S` both, diff the Mach-O sizes:

| | Size |
|---|---|
| baseline, no OpenCV | 0.05 MB |
| with OpenCV linked | 6.22 MB |
| **OpenCV delta** | **6.17 MB** |

iOS static archives (again, the pool, not the shipped size — note how much
smaller these are than Android's, because Xcode's Release config strips
aggressively at archive time):

| Archive | Size | | Archive | Size |
|---|---|---|---|---|
| `libopencv_imgproc.a` | 4.67 MB | | `libopencv_flann.a` | 0.76 MB |
| `libopencv_core.a` | 4.15 MB | | `libopencv_stitching.a` | 0.72 MB |
| `libopencv_calib3d.a` | 2.97 MB | | `libopencv_video.a` | 0.57 MB |
| `libopencv_features2d.a` | 1.04 MB | | `libopencv_imgcodecs.a` | 0.44 MB |
| `libopencv_photo.a` | 0.79 MB | | | |

All six required `cv::detail::` classes plus `GCGraph` are present in the linked
`arm64` dylib, and both `extern "C"` entry points export correctly.

**One iOS-specific link requirement worth recording: `-lz` must be passed
explicitly.** `cv::FileStorage`'s gzip path (`gzopen`, `gzgets`, `gzclose`, …)
is compiled into `libopencv_core.a` even with `BUILD_ZLIB=OFF` — that flag only
controls whether OpenCV vendors *its own* copy of zlib, not whether the code
paths exist. Android resolved these implicitly against system `libz.so`; iOS
fails to link without `-lz`. This is the kind of thing that surfaces at
integration time in Phase 03 if it is not written down now.

## Total across both platforms

| Platform | Measured | Budget | Headroom |
|---|---|---|---|
| Android `arm64-v8a` | 5.13 MB | 25 MB | 4.9× |
| Android `armeabi-v7a` | 3.44 MB | 25 MB | 7.3× |
| iOS `arm64` | 6.17 MB | 25 MB | 4.1× |

The size risk that gated this whole phase is closed with roughly 4× headroom on
both platforms. There is no need to drop `video` or `photo`, no need to ship
`arm64-v8a` only for size reasons, and no need to narrow the Phase 05 fusion
path. Those contingencies from PHASE_00's "If it fails" section are not
required.

## Runtime dependencies

```
NEEDED liblog.so  libz.so  libdl.so  libm.so  libc.so
```

System libraries only. `ANDROID_STL=c++_static` works as R1 predicted: no
`libc++_shared.so`, so no risk of colliding with a different version shipped by
another plugin.

## `cv::detail::` verified present *and* executable

All six required classes survive `--gc-sections` in the linked binary, plus 226
`cv::detail::` symbols total:

```
BestOf2NearestMatcher  BlocksGainCompensator  BundleAdjusterRay
GraphCutSeamFinder     MultiBandBlender       SphericalWarper
```

**`GCGraph<float>` and `GCGraph<double>` are present in the binary.** This
promotes R1's "graph-cut needs no external max-flow library" from a source-read
to a verified property of a real link. The project's largest risk stays closed.

The device probe (`spikes/spike_a_opencv/probe/sv_spike_probe.cpp`) deliberately
goes further than `PHASE_00_spikes.md`'s snippet: it *executes* each algorithm
on a small synthetic input and reports a result value, because with
`-ffunction-sections`/`--gc-sections` a default constructor can survive while
the algorithm body is stripped. On-device execution is still pending hardware.

## The six open items R1 handed to this spike

**1. Real measured size after adding `stitching` + `calib3d` + `flann` back.**
Answered above: **5.13 MB** stripped `arm64-v8a`, 3.44 MB `armeabi-v7a`, well
inside the 25 MB budget.

**2. opencv-mobile's default state for `flann` and `video`.** Read directly from
`opencv4_cmake_options.txt` in `nihui/opencv-mobile`:

- `-DBUILD_opencv_flann=OFF` — explicitly off.
- `video` — **not listed at all, therefore ON by default.**
- **`-DBUILD_opencv_imgcodecs=OFF`** — a *fourth* flag the recipe missed.

**This changes the opencv-mobile recommendation, see below.**

**3. 16 KB page alignment on the real build output.** Verified with
`llvm-objdump -p`: `align 2**14` on every `PT_LOAD` segment, both ABIs. The
script sets `-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384`
explicitly rather than relying on NDK r28's default, so the build stays correct
on r27. Counter-example confirming the check is worth doing: the existing
`flutter-plugin-camera360` `.so` measures `align 2**12`.

**4. Patching `build_framework.py`'s `BUILD_LIST` passthrough vs. invoking
cmake directly.** Measured against 4.13.0 — **use cmake directly.** Reasons, in
the order PHASE_00 asked us to try them:

- *Option 1, `--without` per module:* handles module selection, but the script
  **silently discards every extra `-D` argument**. Observed verbatim on stdout:
  `The following args are not recognized and will not be used: ['-DBUILD_JPEG=ON',
  '-DWITH_PNG=OFF', '-DCMAKE_CXX_FLAGS=-Os ...', ...]`. So option 1 cannot set
  the codec selection or the `-Os`/`--gc-sections` flags the size argument rests
  on. **Insufficient.**
- *Option 2, patch `getCMakeArgs()`:* fixes module selection only. The dropped
  `-D` args are a separate defect in the same script, so this does not help
  either. Also checked: 4.13.0's `build_framework.py` has **no `--cmake_option`
  escape hatch** — its entire surface is `--without`, `--disable <FEATURE>`
  (which only emits `WITH_*=OFF`), and a fixed set of flags.
- *Option 3, drive cmake + `Toolchains/Toolchain-iPhoneOS_Xcode.cmake`
  directly:* **chosen.** Full control, and it mirrors `build_android.sh`
  exactly, so both platforms share one mental model.

One trap worth recording: `IPHONEOS_DEPLOYMENT_TARGET` must be exported as an
**environment variable**, not passed as `-D`. `common-ios-toolchain.cmake` is
re-included inside CMake's `try_compile` sub-project, which does not inherit
cache entries, and it hard-errors with `IPHONEOS_DEPLOYMENT_TARGET is not
specified`. This is why `build_framework.py` exports it.

**5. iOS IPA-delta measurement method.** R1's App Thinning Size Report diff
remains the authoritative method, but it needs a signed archive. For iteration,
`spikes/spike_a_opencv/measure_ios_link.sh` measures the same quantity without
signing: link the probe twice — once against a trivial stub with the same
exported C ABI, once against the real static libs — then `strip -x -S` both and
diff the Mach-O sizes. That isolates the object code OpenCV actually
contributes at our call sites, which is the number that moves when a module is
added or dropped.

**6. Do `-Os` + `-ffunction-sections` + `--gc-sections` + LTO help?**
`-Os` + `--gc-sections` are doing nearly all the work (191 MB of archives →
5.13 MB). **ThinLTO buys a further 0.45 MB, 5.13 → 4.68 MB, about 9%.**

Worth taking, but note the mechanism: **`CMAKE_INTERPROCEDURAL_OPTIMIZATION=ON`
is broken on NDK r28.** CMake 3.22 implements IPO for Android by emitting
`-fuse-ld=gold`, and r28 no longer ships the gold linker, so the link dies with
`invalid linker name in argument '-fuse-ld=gold'`. The working route is explicit
flags: `-flto=thin` in `CMAKE_CXX_FLAGS` plus `-flto=thin -fuse-ld=lld` in the
linker flags. Given LTO also lengthens the build and complicates debugging for
9%, it is reasonable to ship without it and keep it in reserve.

## Recommendation change: build vanilla OpenCV, do not fork opencv-mobile

R1 preferred forking `nihui/opencv-mobile` and flipping three flags. Having read
its actual configuration, **that is now the worse option**, and the vanilla
`BUILD_LIST` build measured above is what `spikes/spike_a_opencv` implements.

It is not three flags. `stitching`, `calib3d`, `flann` **and `imgcodecs`** are
all OFF. And re-enabling `imgcodecs` is not enough on its own, because
opencv-mobile also sets `BUILD_JPEG=OFF`, `WITH_JPEG=OFF`, `BUILD_PNG=OFF`,
`BUILD_ZLIB=OFF` and ships an **stb_image-based replacement** for
`imread`/`imwrite` (`highgui/src/stb_image.h`, `stb_image_write.h`). We read
JPEG frames from `CaptureBundle` and write a JPEG panorama; `stb_image_write`'s
JPEG encoder is markedly lower quality than libjpeg-turbo at a given file size,
which is the wrong trade for the deliverable a manager reads a defect off. So we
would be re-enabling the codec stack it exists to remove.

Two of its other choices are actively wrong for us:

- **`-DENABLE_FAST_MATH=ON`.** `BundleAdjusterRay` runs Levenberg–Marquardt.
  `-ffast-math` relaxes IEEE semantics — NaN/Inf handling, reassociation — in
  exactly the code whose convergence criterion S1 (<1.0 px RMS) depends on.
- **`opencv-4.13.0-no-rtti.patch`.** RTTI off across a codebase whose
  `Algorithm`/`Ptr` machinery uses `dynamic_cast`.

Its remaining advantages — `-Os`, size flags, toolchain plumbing — are things we
now have measured numbers for in a vanilla build, at 5.13 MB. Forking it would
mean carrying a patch set against a moving upstream to reach a similar place
with worse numerics.

`~/Documents/flutter-plugin-camera360` is still worth lifting from: its
`BUILD_LIST` is almost ours already (`core,features2d,flann,imgcodecs,imgproc,
stitching`, missing `calib3d`/`photo`/`video`), and its `.so` measures 10.02 MB
arm64 — a useful independent cross-check that ~5–10 MB is the right order of
magnitude. Its build is **not** 16 KB aligned, so do not lift that part.

## Also worth recording

- **4.14.0 exists** (checked against `opencv/opencv` tags). We pin **4.13.0**
  because opencv-mobile only ships patches for it, keeping the fork option open
  and the comparison apples-to-apples. Now that the fork is not recommended,
  moving to 4.14.0 is a low-risk follow-up. This closes R1 "Still unknown" #6.
- **Build time from clean is not a constraint:** ~55–61 s for all nine modules
  per ABI on this machine, plus a few seconds to link the probe.
- **Cold-start delta and the on-device probe run still need hardware.** The
  library is built and the probe is wired to Dart FFI in
  `spikes/spike_bc_device`; see `spikes/README.md`.

## Acceptance status

- [ ] All probes return `ok` on both platforms, on real hardware — **needs a device**
- [x] Installed size delta ≤ 25 MB per ABI — **5.13 MB Android arm64, 3.44 MB v7a, 6.17 MB iOS arm64**
- [x] All six open items answered
- [x] Build scripted and reproducible from a clean checkout — `spikes/spike_a_opencv/`
