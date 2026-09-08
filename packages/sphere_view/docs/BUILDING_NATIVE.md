# Building the native library

The stitch pipeline is C++ over OpenCV, reached from Dart through FFI. It has
to be built once per machine before a stitch will run. **One command does it**,
and this page describes what that command does rather than asking you to do any
of it by hand — Phase 13 §2 requires the build to be reproducible from a clean
checkout by somebody who is not its author.

```sh
tools/build_native_mobile.sh            # Android + iOS
tools/build_native_mobile.sh --android  # one platform
tools/build_native_mobile.sh --ios
tools/build_native.sh                   # the desktop build, for tools/replay
```

The first run takes **10–20 minutes per target** and is entirely OpenCV. It is
cached: a rerun with the install tree present skips straight past it, and the
part you iterate on — `src/sphere_stitch` — is a few seconds.

## What you need installed

| | Android | iOS |
|---|---|---|
| Toolchain | Android NDK **28.2.13676358**, `cmake` from the Android SDK | Xcode with command line tools |
| Get it | `sdkmanager 'ndk;28.2.13676358' 'cmake;3.22.1'` | App Store, then `xcode-select --install` |
| Overridable with | `NDK_VERSION`, `ANDROID_SDK`, `CMAKE_BIN` | `IOS_SDKS`, `IOS_DEPLOYMENT_TARGET` |

Nothing else. In particular **do not install OpenCV** — not from Homebrew, not
from CocoaPods, not a prebuilt release. Every one of those channels is wrong for
this project, and the reasons are measured rather than aesthetic ([R1
findings](../phases/findings/R1_opencv_distribution.md)):

* the prebuilt releases are all-module "world" builds, tens of megabytes of
  modules this package deliberately excludes;
* the CocoaPods route died at OpenCV 4.3.0 and there is no official Swift
  Package Manager distribution;
* Homebrew currently ships OpenCV **5.0.0**, which is a different `stitching`
  `detail::` API entirely;
* `dartcv4`, the obvious Dart-side answer, exposes **zero** `cv::detail::`
  symbols and cannot force a 360×180 canvas. That is an API gap, not a size
  gap, and no amount of packaging fixes it.

## What the script builds

```
build/opencv-android/arm64-v8a/            OpenCV static libs, NDK
build/opencv-ios/iphoneos-arm64/           OpenCV static libs, device
build/opencv-ios/iphonesimulator-arm64/    OpenCV static libs, simulator
build/opencv-ios/iphonesimulator-x86_64/   OpenCV static libs, simulator
build/sphere-stitch-ios/<sdk>-<arch>/      libsphere_stitch.a + the merged archive
ios/Frameworks/sphere_stitch.xcframework
build/opencv-host/                    OpenCV for this Mac (tools/build_native.sh)
build/native/                         libsphere_stitch.dylib + the unit tests
```

The OpenCV configuration — module list, size flags, every exclusion — lives in
exactly one file, [`spikes/spike_a_opencv/config.sh`](../spikes/spike_a_opencv/config.sh),
which all three builds source. That is not tidiness: Phase 02 §2 requires the
desktop replay harness to run *the same library the device runs*, because every
quality number in `CHANGELOG.md` was measured on the desktop build. Same
sources, same OpenCV version, same module list, differing only in the target
triple.

Modules built: `core, imgproc, imgcodecs, flann, features2d, calib3d, photo,
video, stitching`. JPEG only — no PNG, no TIFF, no WebP, no zlib. Measured
result: **5.13 MB** for Android arm64 and **6.17 MB** for iOS arm64, 16 KB-page
aligned.

Two flags that look like free wins and are deliberately off:

* **`ENABLE_FAST_MATH`** — `BundleAdjusterRay` runs Levenberg–Marquardt, and
  relaxed IEEE semantics in exactly the code whose convergence criterion S1
  (< 1.0 px RMS) depends on is not a few hundred kilobytes' worth of risk.
* **`BUILD_WITH_RTTI=OFF`** — OpenCV's own `Algorithm`/`Ptr` machinery uses
  `dynamic_cast`.

## How each platform picks it up

### Android

`flutter build apk` compiles `src/sphere_stitch` itself, per ABI, through
Gradle's `externalNativeBuild` → `android/CMakeLists.txt`. The `.so` in the APK
is therefore always built from the sources in the tree and cannot be stale. Only
OpenCV comes prebuilt from the script, and if it is missing the CMake configure
fails with the exact command to run rather than with a generic
package-not-found.

arm64-v8a only. That is R1's recommendation, and the reason is memory rather
than reach: criterion S9 budgets 700 MB of peak RSS for one stitch, which a
32-bit process cannot reliably provide.

Dart then loads it with `DynamicLibrary.open('libsphere_stitch.so')`.

### iOS

Different, because iOS gives no supported way to load a `.dylib` at runtime —
Dart uses `DynamicLibrary.process()`, which searches symbols **already in the
app binary**. So the script produces a static archive holding `sphere_stitch`
*and* every OpenCV module it uses, wraps the device and simulator slices in
`ios/Frameworks/sphere_stitch.xcframework`, and the podspec links it.

**`ios/Classes/SphereStitchSymbols.c` is not dead code.** A static archive is
pulled in member by member: the linker takes an object file only when something
already in the link refers to a symbol it defines. Nothing does — `sv_stitch`,
`sv_free` and `sv_version` have exactly one caller and it is on the far side of
an FFI boundary the linker cannot see. That file takes their addresses in a
`__attribute__((used))` table, which is what creates the references. Without it
the build succeeds and the failure arrives at runtime, on a device, after a
capture, as `Failed to lookup symbol 'sv_stitch'`.

`-force_load` in `OTHER_LDFLAGS` does the same job in principle and is worse in
practice: Xcode's build system treats the path as an *input* it must be able to
find before the phase that produces it has run, and the error is "Build input
file cannot be found", which says nothing about linking.

To check it worked:

```sh
nm -gU .../Runner.app/Frameworks/sphere_view.framework/sphere_view | grep _sv_
```

Three `T` symbols is right. Nothing is wrong.

Three targets are built, not two: the device, and the simulator for **both**
arm64 and x86_64, lipo'd into one fat library. Xcode builds a simulator target
for both architectures unless told otherwise, and CocoaPods only selects an
xcframework slice that carries *every* architecture in `ARCHS` — so an
arm64-only simulator slice matches nothing, copies nothing, and fails at link
with `Library 'sphere_stitch_merged' not found`. That message reads as a missing
file rather than as a missing architecture, which is what makes it worth a
paragraph. It was measured on an Apple Silicon machine, which is precisely where
you would expect arm64-only to be enough.

Run the script **before `pod install`**. It is deliberately not a podspec
`prepare_command`: a 20-minute OpenCV build inside `pod install` looks like a
hung dependency resolution, and it would run again after every `flutter clean`.

### Desktop

`tools/build_native.sh` builds the same sources for this Mac and **runs the C++
unit tests**, which is where they are asserted — a cross-compiled test
executable links fine and cannot be started. It is what `tools/replay` and the
quality gate use.

## When something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| CMake: `OpenCV has not been built for arm64-v8a` | First build, or `--clean-all` | `tools/build_native_mobile.sh --android` |
| `Failed to lookup symbol 'sv_stitch'` on iOS | The keep-alive file was removed, or the xcframework is stale | Check `ios/Classes/SphereStitchSymbols.c` is still compiled, then `tools/build_native_mobile.sh --ios` and `pod install` |
| iOS: `Undefined symbol: _gzopen` | `s.libraries` lost `z` | OpenCV links the system zlib; put it back |
| iOS: `Library 'sphere_stitch_merged' not found` | The simulator slice is missing an architecture | `tools/build_native_mobile.sh --ios` — it builds arm64 **and** x86_64 for the simulator |
| `NDK not found at …` | A different NDK version installed | `NDK_VERSION=<yours> tools/build_native_mobile.sh --android`, and see the note in `config.sh` about 16 KB alignment |
| The OpenCV build fails | Read the tail it prints; the full log path is in the message | |
| It rebuilds OpenCV every time | The install tree was deleted, or `--clean-all` is in your command | Drop `--clean-all`; `--clean` alone keeps OpenCV |

## Changing the OpenCV pin

Change it in `spikes/spike_a_opencv/config.sh`, rebuild everything, and
**re-run the quality gate** (`tools/ci/quality_gate.sh`). The baselines in
`CHANGELOG.md` are numbers measured against a stated configuration; a new
OpenCV is a new configuration, and a pin moved without re-measuring turns the
gate into a decoration.
