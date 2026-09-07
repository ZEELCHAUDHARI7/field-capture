# Build & test

How to get this project from source on disk to an APK running on a device.

The `android/` folder is **not** in the repo — generating it needs a Flutter SDK, and this
project was authored in an environment without one. Step 2 creates it. That is a one-time step.

---

## 0 · Install the toolchain

Skip this if `flutter --version` already answers.

Two stages, deliberately separate — stage A is small and gets the app on screen; stage B is the
big one and only matters when you need an actual APK.

### A · Flutter SDK only — ~2.5 GB, ~15 min, no admin needed

This is enough to run the app **in Chrome** and see every screen and flow. The project has no
platform plugins (only `flutter_riverpod` and `go_router`, both pure Dart), so it runs on web
unchanged.

1. Download the Windows SDK zip: https://docs.flutter.dev/get-started/install/windows/mobile
2. Extract to a path with **no spaces** and outside `Program Files` — `C:\dev\flutter` is the
   convention. (`Program Files` needs admin and breaks some Gradle paths.)
3. Add `C:\dev\flutter\bin` to PATH via the GUI, not `setx` — `setx` truncates PATH at 1024
   characters and can silently mangle it:
   *Start → "Edit environment variables for your account" → Path → New →* `C:\dev\flutter\bin`
4. Open a **new** PowerShell window (PATH is read at shell start) and check:

```powershell
flutter --version
```

Then, from `C:\App`:

```powershell
flutter create --platforms=android,web --org com.asite .
flutter pub get
flutter run -d chrome
```

Sign in with any `@asite.com` address and an 8+ character password. Everything in the test pass
below works except the Android-back cases, which have no equivalent on web.

### B · Android SDK — a further ~4-5 GB

Needed only to produce an APK.

Install **Android Studio** (https://developer.android.com/studio). It installs per-user under
`%LOCALAPPDATA%\Programs`, so no admin, and it bundles a **JDK 17** — which matters, because
Android Gradle Plugin 8.x requires 17 and the Java already on this machine may be older.

On first launch let it fetch the SDK, then:

```powershell
flutter doctor --android-licenses     # accept all
flutter doctor                        # expect a green Android toolchain
```

**Use a physical phone rather than an emulator** if you have one to hand — it skips a further
~1.5 GB system image, and it is the honest test surface for a field app anyway. Enable USB
debugging (section 4 below).

### Why not build it in the Claude session instead

That was the original plan, and it is still the better one — it would put zero toolchain on
this laptop. It needs `storage.googleapis.com`, `pub.dev` and `dl.google.com` on the session
egress allowlist, which is an Asite admin change. Re-tested 7 Sep 2026: all three still return
`403 connect_rejected`. If that allowlist lands, the APK can be built and handed over directly
and stage B above becomes unnecessary.

---

## 1 · Check the toolchain

```powershell
flutter --version
flutter doctor
```

`flutter doctor` must show a green tick for **Flutter**, **Android toolchain** and either
**Android Studio** or **Android SDK command-line tools**. Chrome/VS Code/Visual Studio warnings
don't matter — this is an Android target.

**Minimum: Flutter 3.27.** The code uses APIs added across several releases:

| API | Needs |
|---|---|
| `WidgetStateProperty` | 3.22 |
| `PopScope.onPopInvokedWithResult` | 3.24 |
| `Color.withValues` (isolated in `AppColors.alpha`) | 3.27 |
| `MediaQuery.textScalerOf`, `TextScaler.clamp` | 3.16 |

On an older SDK, run `flutter upgrade` rather than editing the code down. The one exception is
`Color.withValues` — if you are stuck below 3.27, change the single line in
`AppColors.alpha` to `color.withOpacity(opacity)` and everything else compiles.

---

## 2 · One-time setup

```powershell
cd C:\App
flutter create --platforms=android,web --org com.asite .
flutter pub get
```

Drop `,web` if you only ever want the APK — but keeping it costs nothing and gives you
`flutter run -d chrome`, which is the fastest way to look at a change.

`flutter create` only adds what is missing. It will not touch `lib/`, `test/`, `pubspec.yaml`
or the docs.

It produces `applicationId "com.asite.field_capture"`. Two edits worth making straight away in
`android\app\src\main\AndroidManifest.xml`:

```xml
android:label="Field Capture"
```

and, since `main.dart` already locks portrait, nothing else is needed there.

### If `flutter pub get` resolves Riverpod 3.x

`pubspec.yaml` pins `flutter_riverpod: ^2.4.0`, which excludes 3.x. If pub still complains,
pin it hard:

```yaml
flutter_riverpod: 2.6.1
go_router: 14.6.2
```

Riverpod 3 renamed parts of the `Notifier` API this project uses.

---

## 3 · Verify before running

Do this first. It has never been run — the authoring environment had no SDK — so treat the
first pass as a real result, not a formality.

```powershell
flutter analyze
flutter test
```

**Expected:** `flutter test` passes 40-odd cases across three suites:

| Suite | Covers |
|---|---|
| `test/formatters_test.dart` | Byte/date/elapsed/percent formats, asserted against the literal strings the prototype prints |
| `test/plan_space_test.dart` | Plan-space transform (contain-fit, round-trip, degenerate viewport) and grid-reference derivation (`B-2`) |
| `test/capture_flow_test.dart` | The capture state machine — every transition, every refusal, discard at each step |

`flutter analyze` may surface style hints (`prefer_const_constructors` and friends). Those are
informational. **Errors** are worth sending back — the code has never met a compiler.

---

## 4 · Run it

### On an emulator

```powershell
flutter emulators                          # list AVDs
flutter emulators --launch <emulator_id>   # e.g. Pixel_7_API_35
flutter run
```

No AVD yet? Android Studio → **Device Manager** → **Create Virtual Device**. A Pixel 7 with
API 34 or 35 is a good match for the prototype's frame.

### On a physical phone

1. Settings → About phone → tap **Build number** seven times
2. Settings → Developer options → enable **USB debugging**
3. Plug in, accept the RSA prompt on the phone

```powershell
flutter devices
flutter run
```

While `flutter run` is attached: `r` hot reload · `R` hot restart · `q` quit.

---

## 5 · Build the APK

```powershell
# Debug — largest, slowest, has the dev tooling attached
flutter build apk --debug

# Release — what you want for testing on a real phone
flutter build apk --release

# Release, split by CPU so each file is ~40% smaller
flutter build apk --release --split-per-abi
```

Output lands in:

```
build\app\outputs\flutter-apk\app-release.apk
build\app\outputs\flutter-apk\app-arm64-v8a-release.apk   (with --split-per-abi)
```

**On signing:** `flutter create` wires the release build type to the *debug* keystore, so
`--release` works with no setup. That APK installs and runs fine for testing but **cannot be
distributed** — Play Store and most MDM systems reject debug-signed builds. Real signing
(a keystore plus `key.properties`) belongs in the final phase.

---

## 6 · Install it

```powershell
# Straight from Flutter, to the attached device
flutter install

# Or with adb — -r reinstalls over an existing copy, keeping data
adb devices
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

To sideload manually: copy the `.apk` to the phone, open it in Files, allow
"Install unknown apps" for that app when prompted.

---

## 7 · Test pass

The app runs entirely on mock data — no backend, no camera, no network. Every screen below is
reachable on an emulator with nothing plugged in.

### Sign in — prototype p. 2

| Do | Expect |
|---|---|
| Tap **Sign in** with both fields empty | Two inline validation errors |
| `someone@gmail.com` + any password | Red banner: not an Asite account |
| `zeel@asite.com` + a short password | Red banner: not recognised |
| `zeel@asite.com` + 8+ characters | Spinner, then the project list |

### Project list & calibrations — pp. 3–4

- Three projects, offline counts, relative sync stamps
- Pull down to refresh
- **Riverside Quarter** → four calibrations: L03 offline, B1 not downloaded, L01 offline,
  L05 mid-download at 46%
- Tap **↓ 18 MB** on B1 → progress bar climbs, lands on "Available offline"
- Tap L05 while it is still downloading → message, no navigation
- Tap L03 → the Level Workspace

### Level Workspace — pp. 5, 6, 13, 22

- Plan draws with walls, columns, stair core, shaft, zone labels, lettered grid bubbles
- Pinch/drag to pan and zoom; `+` / `−` / frame buttons; buttons dim at the ends of the range
- **Coverage** toggles the blue wash · **Today / All** — All reveals a second faded walk and a
  second capture pin
- Level rail switches levels; B1 and L05 refuse with a message
- Tap an issue diamond → its title and computed grid reference
- **Tap the connectivity pill** → cycles Online → syncing → Offline
- **Long-press the camera chip** → chip turns red, help card appears, Video and Image go dim,
  Mobile Capture stays live. **Reconnect camera** brings it back.

### Capture — pp. 7–12

The full walk, on an emulator, with no camera:

1. Dock → **Video** → naming sheet, pre-filled `L03_Walk_<today>_<hour>`
2. Try a name with a space → rejected
3. **Next — pin location** → chrome collapses, blue banner, **Start Walking** disabled
4. Tap the plan → crosshair. Tap elsewhere → crosshair moves. **Start Walking** enables
5. Confirm → full-screen recording chrome, timer counting, walk name bottom-left
6. **Waypoint** → back to the plan, banner says "drop waypoint 1", live trail in bright blue
7. Place and confirm → back to recording, timer never paused
8. **Stop Walking** → end-pin mode, **Save capture** disabled until a pin is placed
9. Save → snackbar, and **the new walk is on the plan** with the upload badge incremented
10. Repeat with **Mobile Capture** → four-step sweep, reticle arrow, progress ring to 100%
11. Repeat with **Image** → pin, confirm, saves immediately

Edge cases worth hitting:

- **Android back** during recording → discard confirmation, not a silent exit
- **Android back** during a pin mode → cancels the mode, stays on the level
- Dismiss the naming sheet by swiping it down → nothing is recorded
- **Discard** from the recording screen → confirmation dialog names what is lost

### Not built yet

Upload queue, Settings, Site Issues list and 3D all resolve to a placeholder that names the
phase delivering them. That is intentional — no route in the app is a dead end.

---

## 8 · When something breaks

| Symptom | Cause |
|---|---|
| `Undefined name 'pendingUploadCountProvider'` | A stale `lib\core\widgets\upload_queue_button.dart` — it moved to `lib\features\uploads\widgets\`. Delete the old one. |
| `The method 'withValues' isn't defined for 'Color'` | Flutter below 3.27. Upgrade, or change `AppColors.alpha` to use `withOpacity`. |
| `onPopInvokedWithResult` not found | Flutter below 3.24. Upgrade. |
| Notifier/`build()` override errors | pub resolved Riverpod 3.x. Pin `flutter_riverpod: 2.6.1`. |
| `No Android SDK found` | `flutter doctor --android-licenses`, then set `ANDROID_HOME`. |
| Gradle fails on first build | Usually a JDK mismatch. `flutter doctor -v` prints the Java it found; Android Gradle Plugin 8.x wants JDK 17. |
| App installs but shows Roboto, not Inter | Expected. See `ASSUMPTIONS.md` §A5 — drop the Inter TTFs into `assets/fonts/`, uncomment the `fonts:` block in `pubspec.yaml`, set `AppTypography.sansFamily = 'Inter'`. |

Clean rebuild, when Gradle gets into a bad state:

```powershell
flutter clean
flutter pub get
flutter build apk --release
```
