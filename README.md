# Field Capture

Flutter/Android implementation of the Asite **Field Capture** prototype — offline-first 360°
site progress monitoring.

**Phase 4 of 6 complete.** Every screen in the prototype is now built except the 3D
perspective view — sign in, projects, calibrations, the Level Workspace, the capture flows,
site issues, the upload queue and settings. See [`ASSUMPTIONS.md`](ASSUMPTIONS.md) for
everything the prototype does not specify, and [`BUILD.md`](BUILD.md) to run it.

---

## First run

This repository contains `lib/`, `pubspec.yaml` and the docs. The Android platform folder is
**not** included, because generating it requires a Flutter SDK and this project was authored in
an environment without one. Generate it once:

```bash
cd <this folder>
flutter create --platforms=android --org com.asite .
flutter pub get
flutter run
```

`flutter create` adds only the missing platform scaffolding; it will not overwrite anything in
`lib/`.

To build the APK:

```bash
flutter build apk --release
```

### If `flutter pub get` or `flutter analyze` fails first time

Two things are worth checking before anything else:

1. **`flutter --version`.** The code targets Dart 3.4+ and uses `WidgetStateProperty`
   (Flutter 3.22+), `PopScope.onPopInvokedWithResult` (3.24+), `Color.withValues` (3.27+,
   isolated in `AppColors.alpha`), `MediaQuery.disableAnimationsOf` and `TextScaler`. On an
   older SDK, upgrade rather than downgrading the code.
2. **Package versions.** `pubspec.yaml` pins `flutter_riverpod ^2.4.0` and `go_router ^14.0.0`.
   Riverpod 3.x renames parts of the notifier API; if pub resolves to 3.x, pin it back to
   `^2.4.0` explicitly.

`ThemeData.cardTheme` and `tabBarTheme` are deliberately **not** set in `app_theme.dart` —
their types were renamed across recent Flutter releases, and pinning them would tie the theme
to one SDK version. Cards are styled by `core/widgets/app_card.dart` instead.

---

## What is built

| Prototype page | Screen | State |
|---|---|---|
| 02 | Sign in | Built — validation, submitting, auth error |
| 03 | Project list | Built — loading, empty, error, pull-to-refresh, sync stamps |
| 04 | Calibration list | Built — all four download states, blocked-open message |
| 05 | Plan view · camera connected | Built — plan canvas, pins, trails, coverage, rail, dock |
| 06 | Plan view · camera lost | Built — red chip, dismissible help card, dock refuses politely |
| 13 | Coverage · all history | Built — Today/All filter, earlier visits drawn muted |
| 22 | Offline everywhere | Built — the pill is global, capture is unaffected |
| 07 | Name the capture | Built — pre-filled name, validation, cancel discards |
| 08 | Set the start pin | Built — crosshair, confirm, chrome collapses |
| 09 | Recording a walk | Built — wall-clock timer, storage warning, discard confirm |
| 10 | Waypoint mid-walk | Built — live trail, recording continues |
| 11 | End pin after the walk | Built — full path, Save blocked without an end pin |
| 12 | Mobile Capture guide | Built — 4-step sweep, reticle, progress ring |
| 16 | Site issues | Built — severity-ordered list, computed grid references |
| 17 | Issue detail | Built — read-only sync timeline, Asite Field notice |
| 18 | Report an issue | Built — chips, optional photo, pin step with centre fallback |
| 19 | Upload queue | Built — all five item states, derived summary, retry, Wi-Fi policy |
| 20 | Settings | Built — camera card, quality chips, upload and storage policy |
| 14–16 | 3D Perspective | Placeholder — Phase 5 |

Every route resolves to something, so navigation is never a dead end. Each placeholder names
the prototype pages it will implement and the phase that delivers it.

### Exercising the states

The prototype draws no loading, empty or error states, so the mocks expose flags for them.
Flip them in `main.dart` with a `ProviderScope` override:

```dart
runApp(
  ProviderScope(
    overrides: <Override>[
      projectsRepositoryProvider.overrideWithValue(
        MockProjectsRepository(simulateError: true),
      ),
    ],
    child: const FieldCaptureApp(),
  ),
);
```

Tapping the connectivity pill cycles **Online → Online — syncing → Offline**, so every screen's
connectivity treatment can be walked without a real network. **Long-pressing the camera chip**
on the Level Workspace drops the 360° camera, which is how the camera-lost state, the help card
and the disabled dock tiles are reached without unplugging hardware. Both hooks are removed when
the real session and connectivity land.

---

## Architecture

```
lib/
├── core/                    shared across every feature
│   ├── constants/           spacing, radii, the 48px touch-target floor
│   ├── theme/               colours, typography, ThemeData
│   ├── routing/             all 10 routes, declared up front
│   ├── utils/               formatters (bytes, dates, elapsed, percent)
│   └── widgets/             the shared widget kit
├── shared/
│   ├── connectivity/        one connectivity source read by 8 screens
│   └── camera/              360° camera session — connected / lost / reconnecting
├── features/
│   ├── auth/                sign in
│   ├── projects/            project list
│   ├── calibrations/        calibration list + download lifecycle
│   ├── plan/                THE HUB — level workspace, plan canvas, pins, coverage
│   ├── capture/             the capture state machine + its three screens
│   ├── issues/              raise, list and inspect site issues
│   ├── uploads/             the queue captures land in
│   ├── settings/            camera pairing, capture quality, upload policy
│   └── placeholders/        stands in for phase 5
├── app.dart                 theme + router only
└── main.dart                bootstrap only
```

Each feature holds `models/ data/ state/ screens/ widgets/`. Data access sits behind an
`abstract interface class` with a mock implementation, so the real Asite client is added beside
the mock and swapped by overriding one provider. No widget performs I/O and no screen imports
another feature's internals.

**Dependencies:** `flutter_riverpod`, `go_router`. That is the whole list. `intl` was skipped —
`core/utils/formatters.dart` covers Phase 1 with zero dependency.

### The decision that shapes everything

The prototype draws 21 states, but only **10 are routes**. Eleven are tabs, sheets, pin modes
or data-driven variants of one screen: the **Level Workspace**. Modelling that screen as a
single route with an explicit capture state machine — rather than eleven routes — is the
central architecture decision, and it is why Phase 2 is a single screen.

---

## Design system

Colours in `core/theme/app_colors.dart` were **pixel-sampled from the prototype mockups**, not
estimated. Anything that could not be measured from a raster is marked `ASSUMED` in the source
and listed in `ASSUMPTIONS.md`.

| | |
|---|---|
| Primary | `#085B90` |
| Dark chrome | `#071529` / `#202C3E` |
| Recording | `#FE5C4E` |
| Warning / issue pin | `#FFA41E` |
| Success | `#1C6F5A` |
| Text | `#0C1315` / `#5E5C5C` |
| Background / surface | `#FAFAFA` / `#FFFFFF` |
| Outline | `#DDE2E7` |

No screen may hard-code a colour or a text style. If something is missing, add it to
`AppColors` or `AppTypography` first.

---

## Plan space

The workspace's load-bearing idea, and the thing the prototype is explicit about: **pin
coordinates are stored in metres from the plan origin, never in screen pixels**, so they
survive zoom and pan. `PlanTransform` converts in both directions at paint time;
`PlanGrid.referenceFor` turns a point into a human reference like `B-2`, which is how the
prototype says grid references are produced ("derived from the pin, not typed by the user").
Both are pure functions and both are covered by `test/plan_space_test.dart`.

The plan artwork is behind `PlanSource`. Today it is `GeometryPlanSource` — vector primitives
drawn in code, because the deck's own plan is synthetic and "real plan raster import" is listed
as a next step. When Asite confirms the bundle format, the repository returns
`RasterPlanSource` instead; the painter already handles it and nothing else changes.

## The capture state machine

One flow, three routes, six drawn states. `CaptureFlowController` owns all of it:

```
idle ─beginNaming─▶ naming ─confirmName─▶ pinningStart
                                              │
              video ─┬──────────────────────── ┤
                     ▼                         ├──▶ mobile: mobileSweep ──▶ saving
                 recording                     └──▶ image:  saving
                  │      │
      requestWaypoint    stopWalking
                  │            │
                  ▼            ▼
          pinningWaypoint   pinningEnd ─confirmEndPin─▶ saving ─▶ idle
                  │
         confirm / cancel ──▶ recording
```

Every transition checks the phase it is leaving, so a half-recorded walk cannot leak between
screens. Screens render the phase and never mutate the draft; navigation is a *side effect* of
the flow, not of a tap, which is why backing out of the recording route by any means lands in a
consistent state. `test/capture_flow_test.dart` drives the machine directly — 18 cases covering
the happy path, every refusal, and discard at each step.

Two details worth knowing:

- **Elapsed time is derived from the wall clock**, never counted up, because the prototype says
  "recording survives the app going background — the timer is authoritative".
- **A tap is provisional.** It drops a crosshair; only the confirm button commits it, so "a
  mis-tap costs nothing". The same rule is applied to waypoints (§G8).

## Derived, not stored

The upload queue's summary card is worth knowing about, because the prototype hands us the
expected output. From its own four items it prints *"Uploading 2 of 4"*, *"49%"* and
*"444 MB remaining"* — and `uploadSummaryProvider` computes all three from the item list rather
than storing them. `test/upload_queue_test.dart` asserts each figure against the deck's
printed value, which is as close to a spec as this project gets.

The same principle covers grid references: an issue stores a plan-space point, never a label.
`B-2` is computed at render time, which is what the deck means by "derived from the pin, not
typed by the user".

## Next

Phase 5 — the 3D perspective view: the trajectory picker, scrubbing along a recorded walk at
eye height, and the Compare wipe between the design model and captured imagery.

It starts with a spike rather than a screen, because the deck never states the model source,
format, or size, and never draws a loading, failure or no-model state (`ASSUMPTIONS.md` §B7).

Still open and worth an answer: §F3 (the deck's grid references do not match its own pins),
§G9 (the Image and Mobile capture flow order) and §G10 (the partial-walk save path).
