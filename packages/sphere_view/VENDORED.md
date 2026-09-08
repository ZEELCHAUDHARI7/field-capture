# This package is vendored

`sphere_view` is developed as a standalone Flutter plugin and is copied in here
as a path dependency (`pubspec.yaml` → `sphere_view: {path: packages/sphere_view}`)
rather than pulled from pub.dev, because it is not published yet.

Read [`docs/INTEGRATION.md`](docs/INTEGRATION.md) before changing anything on the
app side. It is the host-app contract: the three-call quickstart, the background
stitch queue, what to persist, the storage policy, and the capability gate.

## Before you can build

The Android build links OpenCV **4.13.0** static libraries that Gradle cannot
build in reasonable time, so they are produced once by a script and cached in
`build/` — which is **not committed** (213 MB per ABI). From this directory:

```bash
tools/build_native_mobile.sh --android
```

10–20 minutes the first time, then cached. It needs the Android SDK, **NDK
`28.2.13676358`** and cmake. On Linux, override the two macOS defaults in
`spikes/spike_a_opencv/config.sh`:

```bash
ANDROID_SDK=/path/to/sdk NDK_HOST_TAG=linux-x86_64 tools/build_native_mobile.sh --android
```

Skipping this step does not fail obscurely — `android/CMakeLists.txt` stops with
a message naming the command above.

`src/sphere_stitch` itself is compiled from source by Gradle on every
`flutter build apk`, so the `.so` in the APK can never be stale.

## What was trimmed from the upstream copy

Nothing the build or the tests need. Removed to keep the repository reviewable:

| Dropped | Size | Why |
|---|---|---|
| `build/` | 2.6 GB | build output, including the OpenCV install tree above |
| `spikes/spike_bc_device/` | 3.4 GB | a throwaway device-probe app; no code references it |
| `spikes/spike_a_opencv/{work,out}/` | 2.5 GB | build trees, already ignored by that directory's own `.gitignore` |
| `ios/Frameworks/sphere_stitch.xcframework` | 53 MB | Android-only target — see [`ios/README.md`](ios/README.md) |
| `ios/{Runner,Flutter}/`, `android/app/` | — | host-app scaffolding left over from local runs |
| `CHANGELOG.md`, `PROMPTS.md` | 170 KB | the upstream build log |
| `example/{ios,linux,macos,web,windows}` | — | non-target platforms |

`spikes/spike_a_opencv/*.sh` **is kept even though it lives under `spikes/`** —
`tools/build_native_mobile.sh` and `tools/build_native.sh` both `source`
`config.sh` for the OpenCV version pin, the module list and the size/alignment
flags. The scripts do not run without it.

## Verifying the copy

```bash
flutter pub get
flutter analyze          # this package's own flutter_lints ^6 rules
flutter test             # 37 suites
```

`test/public_api_test.dart` resolves the barrel's element model and fails if any
`src/` type leaks into a public signature — a cheap check that the copy is intact.

To prove the native build and the hardware path independently of Field Capture,
run the demo app on a real arm64 device:

```bash
cd example && flutter run --release
```

If that captures and stitches, any later failure is in the app integration rather
than in the package.
