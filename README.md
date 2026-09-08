# Field Capture

Flutter/Android implementation of the Asite **Field Capture** prototype — offline-first 360°
site progress monitoring.

**Phase 5 of 6 complete. Every screen in the prototype is built.** All ten routes resolve to
a real screen; no placeholders remain. See [`ASSUMPTIONS.md`](ASSUMPTIONS.md) for everything
the prototype does not specify, and [`BUILD.md`](BUILD.md) to run it.

Phase 6 is QA and the release APK — nothing here has been compiled yet.

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
| 13 | 3D · pick a trajectory | Built — walk list, no-model and no-walks states |
| 14 | 3D · walk the trajectory | Built — perspective render, scrub, yaw, mini plan |
| 15 | 3D · compare slider | Built — draggable wipe, viewpoint preserved |

All ten routes were declared in `app_router.dart` on day one. The ones not yet built resolved
to a placeholder naming the phase that would deliver them, so no navigation path was ever a
dead end and each phase only swapped a builder. As of Phase 5 there are no placeholders left.

### The dead ends, and what happened to them

Six controls were reported as answering a tap with nothing useful. Two of the six turned out to
be fully wired already — camera reconnect runs `CameraLostCard → reconnect() → busy → paired`,
and the queue's pause, resume and retry all reach real controller methods. Four were real:

| Control | Was | Now |
|---|---|---|
| Image capture | Pin, then saved instantly — no screen at all | `CapturePhase.shooting` and a framing screen with a shutter (§C7) |
| Issue photo buttons | Both called the same no-op; neither could be undone | The draft records which button attached it, tapping it again removes it, and the 360° button is refused while the camera is gone (§H2) |
| Scan for 360° cameras | Snackbar | A scan → list → pair sheet (§C14) |
| + Define new trajectory | Snackbar | Rendered as unavailable, with the reason on the control (§I5) |

The last one is the odd one out, and deliberately so. A control that reads as live until you
press it is worse than one that reads as unavailable: the first gets tapped in a demo, the
second does not. The deck's layout is kept; only the affordance changes. The line above it no
longer offers to "define a new path" either.

Nothing in the demo path now answers a tap with an apology.

### Exercising the states — the demo console

**Settings → Demo controls.**

The app renders a good deal more than the deck draws: loading, empty and error states for every
list, a failed bundle download, an unsupported-device message for Mobile Capture. None of it had
a way in. The data faults were constructor arguments on the mocks, reachable only by editing
`main.dart` and restarting; connectivity was a tap on the status pill and camera loss a
*long-press* on the camera chip. Nothing there can be driven in front of an audience, so every
hidden hook is now a labelled control on one screen:

| Control | Reaches |
|---|---|
| Connectivity | Online · Online — syncing · Offline, on every screen that shows the pill |
| 360° camera | Paired · Lost — the red chip, the help card, the refused dock tiles |
| Project list | Loading · empty · error |
| Calibration list | Loading · empty · error |
| Plan fails to load | The Level Workspace error state |
| Downloads drop at 62% | A part-downloaded bundle that offers to resume |
| Mobile Capture supported | The unsupported-device message (§G7) |
| Fail the active upload | The failed queue row, its reason and its retry countdown |
| Reset all demo data | Back to the seed — see below |

**How reset works, and why it needs no clear-down code.** Each mock holds the captures, issues
and walks saved since launch in its own fields. `DemoControls.generation` is read by every
repository provider, so bumping it constructs fresh mocks — and a fresh instance *is* the reset.
Nothing has to enumerate what to discard, so nothing can drift as more state is added.

**Why each repository selects its own slice.** Every repository reads the same `DemoControls`,
so a plain `ref.watch` would rebuild all of them on any toggle — and flipping the project list
would then quietly discard the walk just recorded on stage. Each one watches a `.select` of only
its own fields. `test/demo_controls_test.dart` asserts that isolation, because it is invisible
when broken.

The console lives in `features/demo/` and its state in `shared/demo/`, both of which come out
with the mocks. It is the one screen allowed to reach across features: being the console for all
of them is the job.

---

## Architecture

```
lib/
├── core/                    shared across every feature
│   ├── constants/           spacing, radii, the 48px touch-target floor
│   ├── theme/               colours, typography, ThemeData
│   ├── routing/             the 10 prototype routes + 2 added in Phase 6
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
│   └── perspective/         the 3D view — camera, renderer, scrub, compare
├── app.dart                 theme + router only
└── main.dart                bootstrap only
```

Each feature holds `models/ data/ state/ screens/ widgets/`. Data access sits behind an
`abstract interface class` with a mock implementation, so the real Asite client is added beside
the mock and swapped by overriding one provider. No widget performs I/O and no screen imports
another feature's internals.

**Dependencies:** `flutter_riverpod`, `go_router`. That is the whole list. `intl` was skipped —
`core/utils/formatters.dart` covers Phase 1 with zero dependency. The only bundled asset is
Inter, at the four static weights the type scale uses.

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

## The 3D view, and what it actually is

There is no model. The deck never states the model's source, format or size, so rather than
guess a dependency, the 3D view renders **the plan extruded to wall height** through a small
perspective renderer written for this project — near-plane clipping in camera space,
painter's-algorithm depth sorting, distance fog. No 3D engine, no new package.

The plan is the only spatial data the app holds, so walls land where the plan says walls are
and walking a trajectory passes the right rooms in the right order. That makes every
interaction in the deck real and reviewable today: the scrub, the yaw, the mini plan with its
heading cone, the compare wipe. `ModelPerspectiveSource` marks the production path and
`ModelPainter` already switches on it — swapping in a real renderer touches that one file.

The camera maths and the walk sampling are pure functions and both are covered by
`test/perspective_test.dart`, including the near-plane clip that a hand-check caught: a
clipped point lands exactly *on* the plane, so the projection guard has to admit it or every
wall you stand beside disappears.

## Next

Phase 6 — QA and release. **Done:** Inter bundled (§A5), the 48 px touch-target audit, and the
Android back-navigation audit at every mode and sheet. **Left:** screen-by-screen comparison
against the deck on real hardware, responsive checks, signing configuration and a release APK.

Phase 6 also added the demo console described under *Exercising the states*, which is what makes
the states above reachable without a rebuild.

### The 48 px audit, and what it found

The floor is stated in the deck — "touch targets never below 48px" — so it is a spec item.
Thirty-six interactive elements were measured. Material's own controls were already compliant
(`materialTapTargetSize: padded` is set in the theme), as were the map controls, level rail,
plan pins and queue buttons, all built against `AppSizes.minTouchTarget` from the start.

Six were not, and all six are chrome the deck deliberately draws small: the Today/All filter at
36, the Coverage and 3D pills at 36, the camera chip at 38, the connectivity pill at about 31,
and the workspace tabs at 46. Growing them to 48 would have broken the drawn design.

`core/widgets/min_tap_target.dart` resolves that the way Material resolves it for `IconButton`:
the child paints at its own size and the render object reports a larger one to hit testing, so
the space around a control is tappable but never inked. It differs from Material's version in
one respect — a touch in the margin resolves to the *nearest* point on the child rather than its
centre, because a segmented control has several children in a row and centre would send every
near-miss to the middle segment. `test/touch_target_test.dart` covers both.

Two containers were capping their contents regardless of what the control asked for, and both
are fixed: `AppSizes.statusStripHeight` was 44 and now tracks `minTouchTarget`, and the camera
strip's growth is absorbed into the padding beneath it so the bar is exactly as tall as it was.

### The back-navigation audit

The capture flow makes navigation a side effect of the state machine rather than of a tap, and
that held up: `PopScope` guards the recording screen, the Mobile Capture sweep and every pin
mode on the Level Workspace, and both bottom sheets discard their draft in the caller when they
are dismissed by the scrim or the back gesture rather than confirmed. Sign-in uses `go` so Back
from Projects leaves the app instead of returning to the form, and level switching uses
`replace` so Back does not walk through every level visited (§F8).

One gap was found and closed: the 3D perspective view had no `PopScope`, so Back in Compare
mode left the walk entirely. The deck is explicit that "Compare is a mode, not a separate
screen — the viewpoint is preserved", so Back now leaves the mode first, the same rule the
workspace applies to its pin modes.

**Nothing in this project has been compiled.** `flutter analyze` is the first thing Phase 6
should run.

Still open and worth an answer: §F3 (the deck's grid references do not match its own pins),
§G9 (the Image and Mobile capture flow order), §G10 (the partial-walk save path) and §I1
(the 3D model format).
