# ASSUMPTIONS

Everything the prototype does not state, and the decision taken instead.

The prototype PDF (*Field Capture — Site progress monitoring · 360° capture*, Asite,
7 September 2026, 22 pages) is the source of truth. Where it is silent, this file records
what was assumed, why, and what it would cost to change. Nothing here is invented silently:
if a screen behaves in a way the PDF does not show, it is listed below.

**Severity** — `HIGH` blocks a phase until answered · `MED` needs a documented assumption ·
`LOW` can be deferred safely.

**Status** — `OPEN` awaiting an answer from Asite · `ASSUMED` decided and implemented ·
`DEFERRED` not needed until a later phase · `RESOLVED` the assumption is gone, because the
real thing arrived and settled it.

---

## Decisions confirmed by the client (7 Sep 2026)

| # | Question | Decision |
|---|---|---|
| D1 | Where the APK is built | Asite to allowlist `pub.dev`, `storage.googleapis.com`, `dl.google.com` for session egress; build runs from the Claude workspace once that lands. Until then the source is authored to disk and built locally. |
| D2 | Phase 1 scope | Foundation + design system + Sign in, Project list, Calibration list. Plan canvas held to Phase 2. |
| D3 | Plan source | Assume a bundled raster per calibration plus a plan-space → image transform. Revisit when Asite confirms the bundle format. |
| D4 | Platform fit | Material 3 components restyled with the prototype's measured tokens. Android back, ripples and insets behave natively rather than imitating iOS. |

---

## A. Platform and environment

### A1 · Prototype is iOS, target is Android — `HIGH` · `ASSUMED` (D4)
The deck shows an iPhone with a home indicator, iOS press states and iOS status bar.

**Assumed:** Material 3 with the prototype's colour and type tokens. Android hardware and
predictive back are honoured everywhere, including inside pin modes and sheets (Phase 2+).
Ripples replace iOS opacity presses. `SafeArea` handles insets rather than fixed offsets.

**Cost to change:** low for colour, high for interaction — a switch to Cupertino would touch
every widget in `core/widgets/`.

### A2 · Portrait only — `LOW` · `ASSUMED`
Every mockup is phone-portrait. `main.dart` locks `portraitUp`. Layouts are constraint-driven,
so unlocking landscape later is a layout review, not a rewrite.

### A3 · Light theme only — `LOW` · `ASSUMED`
No dark variant is drawn, and the product's stated design constraint is sunlight contrast.
`themeMode` is pinned to `ThemeMode.light` so a half-designed dark theme cannot ship by accident.

### A4 · Text scaling — `LOW` · `ASSUMED`
Not addressed in the deck. System text scale is clamped to 0.9–1.3 so large-text accessibility
settings do not break the dense capture chrome. Revisit against the stated glove-mode audit.

### A5 · Fonts not bundled — `MED` · `RESOLVED`
The prototype is set in Inter, and the app fell back to Roboto — metrically close but visibly
different on every screen.

**Resolved:** the four static weights the type scale uses (400/500/600/700) are bundled from
[rsms/inter](https://github.com/rsms/inter) v4.1 in `assets/fonts/`, declared in `pubspec.yaml`,
and selected by `AppTypography.sansFamily`. One constant, whole app. The monospace face is still
the platform's own `monospace` — Android resolves it without bundling, and the prototype only
uses it for identifiers.

### A6 · Permission flows absent — `MED` · `DEFERRED` (Phase 3)
Camera, microphone, LiDAR/depth, location, nearby Wi-Fi and storage all need Android runtime
prompts and denied-state screens. None are drawn.

---

## B. Data and backend

### B1 · No API, no schema, no auth contract — `HIGH` · `ASSUMED`
Nothing in the deck describes an endpoint, payload or token.

**Assumed:** every feature talks to an `abstract interface class` repository with a mock
implementation. Real clients are added beside the mocks and swapped by overriding one provider.
No widget knows how data arrives.

### B2 · Plan source unresolved — `HIGH` · `ASSUMED` (D3)
Every plan in the deck is a synthetic vector drawing, and "real plan raster import" is listed
as a **next step** on page 1 — so the prototype explicitly does not answer this.

**Assumed:** a raster image per calibration plus a plan-space → image transform, drawn under a
`CustomPainter` inside an `InteractiveViewer`. Pin coordinates are stored in plan space so they
survive zoom and pan, which the deck requires explicitly.

**Cost to change:** contained. Vector geometry or map tiles would change `PlanCanvas` and
nothing else.

### B3 · Grid reference derivation — `MED` · `OPEN`
Issues show `grid B-2`, stated to be derived from the pin rather than typed.

**Assumed:** the calibration carries grid metadata (origin, spacing, lettered columns, numbered
rows) and the reference is computed from plan-space coordinates. Needed for Phase 4.

### B4 · Two of four sync states never drawn — `MED` · `ASSUMED`
Copy names `local / queued / synced / assigned`; only *Synced* and *Assigned* appear.

**Assumed:** `local` → neutral grey badge, `queued` → info blue badge, matching the two drawn.

### B5 · Project sync stamp — `LOW` · `ASSUMED`
"Rows carry a sync stamp so a crew can tell stale data at a glance" — but no stamp is drawn.

**Assumed:** a relative timestamp ("Synced 4 min ago") under the offline count. Implemented.

### B6 · Offline conflicts and stale calibrations — `LOW` · `OPEN`
If a calibration is republished on Asite web while a crew holds an older bundle, nothing
describes the outcome. No warning, no re-download prompt, no conflict UI.

### B7 · 3D model source and format — `HIGH` · `DEFERRED` (Phase 5)
No format, no size, no loading state, no failure state, and no "this level has no model" state
despite the copy saying only some levels offer 3D. `Calibration.hasModel` carries the flag; the
phase starts with a spike, not a screen.

### B8 · Persistence — `MED` · `DEFERRED` (Phase 3)
Offline-first is the product's central claim, but no storage requirement is stated. Mock
repositories hold data in memory. Adding Drift or Isar later touches only `data/`.

---

## C. Flows the prototype does not draw

### C1 · Sign in has no error, loading or expiry state — `MED` · `ASSUMED`
**Assumed:** inline red banner above the form for auth failures; the button becomes a spinner
while submitting; email and password are required, email must look like an address. The mock
accepts any `@asite.com` address with an 8+ character password so QA has a real reject path.
No forgot-password and no sign-out exist anywhere in the deck — both remain `OPEN`.

### C2 · No empty states anywhere — `MED` · `ASSUMED`
Six screens need one: projects, calibrations, issues, upload queue, trajectories, first run.
The visual language (circular grey glyph, title, one sentence, one secondary action) is invented
and implemented in `core/widgets/state_views.dart`.

### C3 · No loading or error states anywhere — `MED` · `ASSUMED`
**Assumed:** card-shaped skeleton rows that fade rather than shimmer, and a bordered error card
with a *Try again* action. Both honour the platform reduce-motion setting.

### C4 · Blocked calibration open — `MED` · `ASSUMED`
Stated: "Opening an undownloaded calibration is blocked with a toast, not a silent failure."
The toast itself is not drawn.

**Assumed:** a `SnackBar` naming the calibration, with a *Download* action when the bundle has
not started. No action while it is downloading.

### C5 · Calibration download failure and delete — `LOW` · `ASSUMED`
Resume is promised ("a part-downloaded bundle resumes"), which cannot be true without a failure
state. A fourth `DownloadFailed` state was added, carrying the reason and a resume offset, and
styled to mirror the upload queue's failure treatment. No delete or free-space action exists in
the deck — `OPEN`.

### C6 · Issue pin placement never drawn — `HIGH` · `RESOLVED` (see §H1)
*Next — pin location* implies a mode identical to *Set the start pin*, but the same page says
"the pin defaults to the current plan centre if not placed". Those contradict.

**Proposed:** reuse the pin mode with a *Skip* action falling back to plan centre. Needs a
decision before Phase 4.

### C7 · "Image" capture has no post-naming screens — `HIGH` · `ASSUMED` (Phase 6)
The naming sheet says "360° image — you will set one capture point", so a still is
pin → shoot → save with no walk. The shooting state is undrawn.

**Assumed:** the shoot step exists rather than being skipped. Image previously went straight
from the pin to saved, so a mode named on the deck's own capture dock had no screen behind it.
`CapturePhase.shooting` and `ImageCaptureScreen` add the smallest step the deck does not
contradict: the framing preview it already draws for the other two modes, the capture's name,
and a shutter. A still comes from the camera, so the screen refuses when the camera is gone —
the same rule the dock applies.

### C8 · Mobile Capture — 3 of 4 steps undrawn — `MED` · `ASSUMED`
Four step dots are drawn but only "Sweep up — floor to ceiling" is shown, and the
unsupported-device message is referenced but never drawn.

**Assumed:** four fixed steps — sweep up, sweep down, rotate left, rotate right — each with a
directional reticle, auto-advancing on completion.

### C9 · Recording gaps — `MED` · `OPEN` (Phase 3)
No pause. No storage-full hard stop, though free space is displayed. No mid-recording
camera-loss state. Background survival is promised with no UI.

### C10 · Waypoints — `LOW` · `ASSUMED`
**Assumed:** unlimited, sequentially numbered from 1, no undo and no delete — consistent with
"pin drag-to-nudge" being listed as a next step.

### C11 · Partial walk save — `MED` · `OPEN` (Phase 3)
"A partial walk can still be saved — data beats a clean model." The path is described but never
drawn, and *Discard* has no confirmation dialog despite being destructive.

### C12 · Compare pane source — `MED` · `RESOLVED` (see §I6)
The right pane is labelled `LIVE CAMERA` but the body copy says "captured imagery". These are
different implementations.

**Assumed:** captured imagery at the scrubbed viewpoint; the label is prototype shorthand.

### C13 · Upload queue actions — `LOW` · `OPEN` (Phase 4)
Pause is drawn; cancel and remove are not. No clear-completed. Cellular upload is described as
an explicit opt-in but the opt-in dialog is undrawn. Items are not grouped despite the header
saying "uploads to the same calibration".

### C14 · Camera pairing sub-flow — `LOW` · `ASSUMED` (Phase 6)
*Scan for 360° cameras* is a button to nowhere. *Forget Camera* is destructive with no
confirmation (the confirmation was added under §H5).

**Assumed:** discovery is scan → list → pair. `CameraScanSheet` implements that shape with a
timer and the one camera `CameraSessionController` already describes; nothing touches Wi-Fi and
no Ricoh SDK is linked. Pairing is the first thing a crew does with this app, so it is worth
showing rather than apologising for. Only that file changes when real discovery lands.

Note: the source comment on this button previously cited §H5, which is the destructive-actions
entry. Corrected to §C14.

### C15 · "+ Define new trajectory" — `LOW` · `DEFERRED` (Phase 5)
Present on the 3D picker with no destination and no described flow.

### C16 · Settings is scroll-clipped — `MED` · `OPEN`
The PDF cuts off mid-way through "Auto-delete local files". How much of the screen is missing is
unknown. No account section, no sign-out, no app version is visible. Build what is drawn; leave
the section list open.

---

## D. Visual values that could not be measured

Colours were pixel-sampled from the mockups and read from the PDF's vector fills, so
`AppColors` is measured, not estimated. The values below are rasters or absent, so they are
assumptions.

| Token | Assumed | Basis |
|---|---|---|
| Card radius | 12 | Visually consistent across projects, calibrations, issues, uploads |
| Button radius | 8 | Sign in, Download, Report an issue |
| Sheet radius | 20, top only | Name capture, Report issue, Issue detail |
| Chip / pill radius | fully rounded | Every chip and status pill in the deck |
| Spacing scale | 4 · 8 · 12 · 16 · 20 · 24 | Screen padding and card gaps read as 16 and 12 |
| Elevation | flat — 1px border, no shadow | Cards show a hairline, not a drop shadow |
| App bar height | 60 + status bar | Measured against the mockup frame |
| Warning container | `#FDF0DA` / `#8A5300` | Derived from the measured `#FFA41E` — no amber chip is drawn |
| "Muted" historic coverage | not specified | The *All* filter draws earlier captures muted; opacity unknown |
| Motion durations | not specified | Nothing in the deck implies a duration |

**Not an assumption:** the 48px minimum touch target is stated in the prototype documentation
and is enforced as a hard rule in `AppSizes.minTouchTarget`.

---

## F. Phase 2 — the Level Workspace

### F1 · Camera reconnect has no drawn flow — `MED` · `ASSUMED`
The lost-camera chip says "tap to reconnect" and the help card carries a
**Reconnect camera** button, but the deck never draws what happens next.

**Assumed:** a third transient `CameraReconnecting` state — the chip turns amber
and reads "Reconnecting…", the card's button shows a spinner, and the session
returns to connected. No pairing protocol is implemented; there is no Ricoh SDK
and no hardware to test one against.

**QA hook:** long-press the camera chip to drop the camera, so the whole
camera-lost state is reachable without unplugging anything. Removed with the mock.

### F2 · The deck's calibration list and level rail disagree — `LOW` · `ASSUMED`
The calibration list (p. 4) shows **three** bundles: Level 03, Basement B1,
Level 05. The level rail on the plan view (p. 5) shows **four**: B1, L01, L03,
L05.

**Assumed:** the rail is correct and **L01 (Level 01 – Podium)** was added to the
calibration list, so the two screens cannot disagree in the build. L01 is seeded
as downloaded.

### F3 · The deck's grid references do not match its own pins — `MED` · `OPEN`
The Site Issues screen (p. 17) prints `grid B-2` for the scaffold-strike issue
and `grid C-2` for the water ingress. On the plan (p. 5), the two issue diamonds
sit at positions that no single consistent grid maps to those two labels — the
second diamond is drawn *above* the first, so it cannot fall in a later row.

**Assumed:** the geometry is the truth and the label is derived from it, as the
deck itself states ("Grid reference is derived from the pin, not typed by the
user"). The grid spacing was chosen so the scaffold-strike pin computes to
**B-2**, matching the deck. The water-ingress pin is placed where the deck draws
it — beside the core shaft, which is where its title says it is — and its
computed reference therefore differs from the printed `C-2`.

**Needs a decision** before Phase 4 surfaces these references in the issue list.

### F4 · Coverage rendering is not legible in the deck — `MED` · `ASSUMED`
Coverage is named, toggled and filtered, but what it actually draws cannot be
read from the raster.

**Assumed:** coverage is "what has been documented" — a soft blue disc of ~3.4 m
around each capture point, and a soft corridor of the same width along each
recorded walk. Earlier visits draw at a third of the opacity, per "earlier
captures are drawn muted".

### F5 · The project row's offline count contradicts the calibration list — `LOW` · `OPEN`
The project list (p. 3) says Riverside Quarter has "3 calibrations offline", but
its own calibration list (p. 4) shows one bundle available offline, one
downloading and one not started.

**Assumed:** the count on the project row is a server-provided summary, not a
client-side derivation, so both mocks keep the deck's numbers verbatim rather
than silently correcting one of them. Worth confirming with Asite.

### F6 · Pins do not scale with the plan — `LOW` · `ASSUMED`
Only one zoom level is drawn, so the deck cannot say whether pins scale.

**Assumed:** pins hold a constant screen size and sit in an overlay above the
canvas, with a full 48 px hit area each. Scaling them would break the stated
touch-target floor at low zoom and cover the plan at high zoom.

### F7 · Zoom range and the third map control — `LOW` · `ASSUMED`
The deck draws `+`, `−` and a frame glyph, with no ranges.

**Assumed:** 1×–6×, where 1× is the whole level fitted; the frame glyph returns
to that fitted view; zoom is applied about the centre of the viewport, so `+`
magnifies what the crew is already looking at. Buttons dim at the ends of the
range rather than silently doing nothing.

### F8 · Level switching is a route replace — `LOW` · `ASSUMED`
Tapping a level on the rail replaces the current workspace route rather than
pushing, so Back still returns to the calibration list rather than walking
backwards through every level the crew looked at. A level whose bundle is not
downloaded refuses with the same message the calibration list uses.

---

## G. Phase 3 — the capture flows

### G1 · The name's trailing token is the hour — `LOW` · `ASSUMED`
The prototype says a name is "pre-filled from level, mode, date and sequence" and shows five
examples: `L03_Img_2026-07-03_13`, `L03_Walk_2026-07-03_09`, `L03_Walk_2026-06-28_04`,
`B1_Walk_2026-07-01_02`, `L03_Mobile_2026-07-01_05`.

**Assumed:** the trailing pair is the **hour of capture**, not a running counter. The walk
recorded "today" is `_09`, and the phone's status bar in every mockup reads 9:41. Every other
example (02, 04, 05, 11, 13) is a plausible hour on a working day, and a per-level counter
would not restart across dates the way these do.

**Consequence:** two captures of the same mode in the same hour collide, which the prototype
does not address. A `_2`, `_3`… suffix is appended. Worth confirming — if the token really is a
sequence, only `CaptureNaming.build` changes.

### G2 · Only one naming hint and one pin-mode banner are drawn — `LOW` · `ASSUMED`
The sheet's subtitle is drawn once, for Image: "360° image — you will set one capture point".
The start-pin banner is drawn once, for Video: "Zoom in and tap the exact point where recording
begins".

**Assumed:** the other four strings follow the same shape. All are in
`CaptureNaming.hintFor` and `_PinModeBody._bannerFor`, and all are marked.

### G3 · No naming validation rules — `LOW` · `ASSUMED`
**Assumed:** required, 64 characters maximum, and letters/digits/`_`/`-`/`.` only — the minimum
that keeps the upload queue readable, which is the stated reason for naming up front.

### G4 · Mobile Capture: three of four steps undrawn, and no sensor — `MED` · `RESOLVED` (Phase 7)
Four step dots were drawn but only "Sweep up — floor to ceiling" was shown, and Phase 3 assumed
four fixed steps advancing on a timer.

**Superseded, and the assumption was wrong in kind rather than in detail.** The capture is not
a sequence of four sweeps. `sphere_view` derives a shot plan from the camera's *measured*
intrinsics — typically 29 positions across staggered rings, plus zenith and nadir — and proves
it covers the sphere before the camera opens. Progress is "position 7 of 29", not "step 2 of 4",
and each shutter is gated on aim, steadiness and dwell rather than on elapsed time.

Nothing about the deck's four dots survives, and nothing should: they described a UI for a
capture that was never specified, and the real one reports what it is actually doing.

### G5 · Storage warning threshold — `LOW` · `ASSUMED`
"Storage warnings surface here, before the card fills" — no threshold given.

**Assumed:** below 8 GB free, a "Storage low" pill appears beside the free-space pill on the
recording screen. What happens when it reaches zero mid-walk is still `OPEN` (§C9).

### G6 · Discard has no confirmation drawn — `MED` · `ASSUMED`
The deck says "confirmation is the only place a walk is discarded", and Discard is destructive
and sits beside Stop Walking.

**Assumed:** Discard raises a confirm dialog naming what is lost. Android Back during a
recording routes to the same dialog rather than silently abandoning the walk.

### G7 · The LiDAR gate has no capability test and no drawn message — `MED` · `RESOLVED` (Phase 7)
"Gated on device capability, with a clear message when unsupported" — the message was never
drawn and no test was named.

**The device is queried now, and LiDAR is not what it is queried for.** The deck's word was a
guess at the technology; the real requirements are a **gyroscope**, **≥3 GB of RAM** and an
**arm64** ABI. `sphereCaptureGateProvider` runs the package's probe at the dock — motion
capabilities, camera descriptors and total RAM, with no camera opened, so it is cheap enough to
run before the button is offered.

Four refusals, each with its own sentence: no gyroscope (there is no reduced mode — without one
every frame would be seeded from tilt with no heading, so the panorama would be wrong rather
than worse), no native library for this ABI (capture would work perfectly and produce nothing),
no hardware bracket (offered, with a warning: one exposure cannot hold the 12–16 EV of a site
interior with a window), no lens calibration (offered; joins are slightly less exact).

The demo console's switch remains, layered over the real answer, because the refusals are
otherwise unreachable without a second tablet.

### G8 · The waypoint bar has no confirm drawn — `LOW` · `ASSUMED`
Screen 09 draws a single full-width "Back to recording — no waypoint", because it draws the
moment *before* a pin is placed. But the deck also insists on "crosshair plus a confirm button
rather than tap-to-place" for the start pin.

**Assumed:** the same rule applies to waypoints. With no crosshair placed the bar is the single
drawn button; once one is placed it becomes "No waypoint" / "Drop waypoint N".

### G9 · The Image and Mobile flows have no drawn order — `HIGH` · `ASSUMED` (extends §C7)
Only the Video flow is drawn end to end. The naming sheet tells an Image capture it "will set
one capture point", and page 12 of the deck shows a mobile capture pin on the plan, so both
modes must be located.

**Assumed:** all three modes share one shape — name → pin the point → then Video records,
Mobile sweeps, and Image saves immediately (no shooting screen is drawn for a still).

**Still open:** whether a 360° still needs a visible shooting state, and whether Mobile Capture
is pinned before or after the sweep.

### G10 · Partial walks — `MED` · `OPEN` (unchanged)
"A partial walk can still be saved — data beats a clean model", but Save capture is drawn
disabled until an end pin exists and no partial-save affordance is drawn anywhere.

**Decision:** follow the drawing. Save stays disabled without an end pin. The partial-save path
is not invented. Needs an answer.

### G11 · Capture sizes are estimated — `LOW` · `ASSUMED`
Real sizes come from the camera. `_estimateSize` scales from the figures the deck's own upload
queue shows: ~36 MB per minute of 360° video, 28 MB per still, 46 MB per mobile sphere.

### G12 · Saved captures are lost on restart — `MED` · `PARTLY RESOLVED` (Phase 7)
`MockPlanRepository` keeps locally saved captures, issues and trajectories in memory, so they
appear on the plan immediately but do not survive a restart. That is still true of everything
the mock owns, and §B8 still defers it.

**Sphere captures are the exception, and had to be.** They point at panoramas that are real
files on the device. Losing the marker would leave a few hundred megabytes of JPEG with nothing
referring to it — worse than either keeping it or never taking it. `SphereCaptureStore` writes
them to one JSON file under the application support directory and
`MockPlanRepository.fetchWorkspace` merges them ahead of its seeds, exactly as it already merges
the in-memory captures. When the Asite bundle format lands and the plan itself persists, this is
absorbed by whatever does that.

Not `drift` or `isar` (rule 9): this is a list of markers, and a schema engine would be a build
step and a migration story for four lines of `jsonEncode`.

---

## H. Phase 4 — issues, queue, settings

### H1 · The issue pin step contradicts itself — `HIGH` · `ASSUMED` (resolves §C6)
The report sheet's primary action is **"Next — pin location"**, which reads as a required
step. The same page states **"the pin defaults to the current plan centre if not placed."**
Those cannot both be true of a step that blocks on a pin.

**Assumed — both are honoured.** The pin step always happens, so the user always sees where
the issue will land; but placing a crosshair is optional and **Save issue is never disabled**.
Save with nothing tapped and the pin goes to the centre of the plan, exactly as the copy says.
Back returns to the sheet with the title intact rather than discarding the report.

This is the reading that requires inventing least. If Asite intends the pin to be mandatory,
the change is one line — disable the confirm until `draft.pin != null`.

### H2 · Neither photo button has a capture flow — `MED` · `ASSUMED`
"Phone photo" and "360° camera still" are drawn as two dashed buttons. Nothing describes what
either opens, and there is no camera integration.

**Assumed:** the draft records *which* button attached the photo, and tapping the attached
source again removes it. No camera is opened. Both buttons previously called the same no-op, so
once tapped they were indistinguishable and neither could be undone. The 360° button is also
refused while the camera is disconnected, with the reason on the control rather than in a toast
after the tap — a still comes from the camera, the same rule the capture dock applies.

When the real capture lands, the two buttons diverge — one to the phone camera, one
to the paired 360° camera — and only `attachPhoto()` changes.

### H3 · Cellular upload opt-in is never drawn — `LOW` · `ASSUMED`
"Wi-Fi-only is the default; cellular upload is an explicit opt-in." The opt-in itself is
undrawn.

**Assumed:** switching Wi-Fi-only **off** raises a confirm naming the cost ("a single walk can
be several hundred megabytes"). Switching it back on does not ask. The same switch appears on
the queue and in Settings and reads one source, so the two screens cannot disagree.

### H4 · The pause button has no drawn destination — `LOW` · `ASSUMED`
Items drawn as *Uploading* and *Waiting* both carry a pause button, but no paused state is
drawn.

**Assumed:** a fifth `UploadStatus.paused` with an amber badge and a resume action. Pausing
keeps the item's bytes; resuming returns it to *Waiting*.

**Still missing from the deck:** cancel, remove, and clear-completed. Not invented — `OPEN`.

### H5 · Two destructive actions with no confirmation — `MED` · `ASSUMED`
**Forget Camera** and **Auto-delete local files** are both destructive and both drawn bare.
The deck's own rule is "destructive settings opt in".

**Assumed:** each raises a confirm dialog naming what is lost. Turning auto-delete *off* does
not ask; turning it *on* does.

**Scan for 360° cameras** is a button to nowhere — no discovery screen, no pairing protocol.
It reports plainly that the SDK is not wired up rather than pretending to scan. `OPEN`.

### H6 · Issue list order is unspecified — `LOW` · `ASSUMED`
The deck shows two issues, High above Medium.

**Assumed:** severity descending, then newest first — what someone scanning for blockers wants.
No filter or sort control is drawn, so none was added.

### H7 · A new issue's sync state — `MED` · `ASSUMED` (uses §B4)
The deck names four sync states and draws two. A freshly raised issue must be one of the two it
never draws.

**Assumed:** `local` when offline, `queued` when there is signal. This is the first place the
two undrawn states have a real source, and it is why raising an issue never needs a round trip.

### H8 · Settings is scroll-clipped in the deck — `MED` · `OPEN` (unchanged from §C16)
The PDF cuts off mid-way through "Auto-delete local files". Everything visible is built; the
section list is left open. No account section, sign-out or app version is drawn anywhere in
the deck, so none was invented.

---

## I. Phase 5 — the 3D perspective view

### I1 · There is no model, and no format to load one — `HIGH` · `ASSUMED` (extends §B7)
The deck never states the model's source, format or size, never draws a loading or failure
state, and never draws the "this level has no model" case its own copy implies.

**Assumed — the plan, extruded.** `ExtrudedPlanSource` renders the calibration's own plan
geometry pulled up to wall height, through a small perspective renderer written for this
project: near-plane clipping in camera space, painter's-algorithm depth sorting, distance fog.
No 3D engine and no new dependency.

**Why not add one.** Adding `three_dart`, `flutter_gl` or `model_viewer_plus` before knowing
whether the model is IFC, glTF, a point cloud or server-rendered tiles would commit the project
to the wrong dependency, and none of it could be verified — this build has never compiled.

**What this buys.** The plan is the only spatial data the app holds, so walls land where the
plan says walls are and walking a trajectory passes the right rooms in the right order. Every
interaction in the deck — scrub, yaw, mini plan, compare wipe — is real and reviewable now.
`ModelPerspectiveSource` is the marker for the real path; the painter already switches on it.

**Cost to change:** contained to `ModelPainter` and the source type. Nothing else in the app
knows how the view is drawn.

### I2 · Eye height, wall height and field of view — `LOW` · `ASSUMED`
None are stated. Eye height 1.6 m, wall height 2.8 m (slab to soffit), 70° horizontal field of
view — a plausible phone-camera framing. All three are named constants.

### I3 · The deck's own two lengths disagree — `MED` · `ASSUMED`
The walk is labelled "23 m", but its three pins are about **13 m** apart in straight lines.

**Assumed: both are right.** A real walk is not straight between waypoints, so the recorded
track is legitimately longer than the polyline through its pins. Scrubbing is therefore a
**fraction**: it drives position along the polyline, and the same fraction times the recorded
length is what the user is shown — which is how "8 m of 23 m" stays honest.

### I4 · "Rotate the phone to look" is not wired to a sensor — `MED` · `ASSUMED`
The hint pill says "Rotate the phone to look — drag to simulate", so the deck already names
drag as the fallback.

**Assumed:** drag only. No `sensors_plus`, no gyroscope. A full-width drag turns about 160°,
which keeps fine aim possible without endless swiping. Wiring the gyroscope later changes
`PerspectiveController.turnBy` and nothing else.

### I5 · "+ Define new trajectory" still has no flow — `LOW` · `ASSUMED`
Drawn on the picker with no destination and no described behaviour anywhere in the deck.

**Assumed:** it is drawn but not live. It previously answered a tap with a snackbar, which is
the worst of both — it reads as available right up until you press it. It now renders as
unavailable with the reason on the control, which keeps the deck's layout and stops it being
tapped at all. The intro line above it no longer offers to "define a new path" either. One
answered question turns this back into a button.
Defining a path without walking it is a different feature from everything else in this app.
It reports that plainly rather than opening a half-guessed editor.

### I6 · The Compare panes — `MED` · `ASSUMED` (resolves §C12)
The right pane is labelled `LIVE CAMERA` but the body copy says "captured imagery at the same
viewpoint". Those are different sources.

**Assumed: captured imagery**, and the pane is labelled as such internally. The prototype's
label is treated as shorthand — a live camera feed cannot show what a walk recorded last week,
which is the whole point of comparing. The pane shows the capture placeholder, since no 360°
frames exist yet.

### I7 · A raster plan has nothing to extrude — `LOW` · `OPEN`
If the plan source becomes `RasterPlanSource` (decision D3) before a real model exists, the 3D
view has no geometry and draws floor only. That is a real consequence of D3 worth knowing
about: the two decisions interact, and resolving §B7 resolves it.

---

## J. Phase 7 — the real 360° capture

Mobile Capture stopped being a mock. `sphere_view` is vendored at `packages/sphere_view` and
its `docs/INTEGRATION.md` is the contract this app implements. The decisions below are ours,
not the package's, and none of them is drawn in the deck — the deck never contemplated a real
capture.

### J1 · The panorama's heading is written as absent — `HIGH` · `ASSUMED`
A panorama carries a compass bearing in its XMP GPano block, and it is the field that decides
which way it opens. The package's pose sources are deliberately magnetometer-free — indoors,
rebar, steel studs and lift motors bend magnetic heading by tens of degrees — so yaw 0 is
wherever the capture started, and turning that into a bearing needs something outside the
sensor stack.

On a real site walk that something is the plan: the manager drew the path on a drawing whose
north is surveyed, so the facing direction at a station is the tangent of the drawn path, good
to a degree or two. `MockPlanGeometry` has no north and no drawn path.

**Assumed: write nothing.** `session.setPlanHeading` is not called, and the package writes an
unknown heading as *absent* rather than as zero — zero is a real bearing, due north, so a file
claiming it for "we do not know" is indistinguishable from one surveyed facing north and every
viewer opens it confidently in the wrong direction.

**Cost to change:** one call, once the plan carries north. Not calling
`setMagnetometerHeading` either is deliberate: a plan heading displaces a magnetometer heading
and never the reverse, because a fresher reading from a worse instrument is still a worse
answer.

### J2 · The device floor is narrower than the app's — `HIGH` · `ASSUMED`
Every other screen runs anywhere. Mobile Capture needs a **gyroscope**, **≥3 GB of RAM** and an
**arm64** ABI, and no emulator qualifies.

**Assumed:** this is acceptable rather than a defect, and the app says so at the entry point
instead of failing later (§G7). The alternative — a reduced mode without a gyroscope — was
rejected by the package on the grounds that the output would be wrong rather than worse.

**Open with Asite:** whether the deployed fleet meets it. The rugged tablets named in the
package's own device matrix do; nothing here has been run on Asite's actual hardware.

### J3 · The stitch runs behind the crew, and the pin appears first — `MED` · `ASSUMED`
The deck draws a capture completing and a pin appearing. It draws no waiting, because it never
had a minute of stitching to account for.

**Assumed:** the pin is written the moment the capture is saved, in a `stitching` state with a
badge, and the panorama attaches to it up to a minute later. Progress shows in a dismissible
card over the plan, in the register of the camera-lost card — the plan stays pannable and a
second capture can start immediately. A modal would be the honest alternative and is the wrong
one: thirty stations at a minute each is half an hour of a crew standing still.

A 2048 px preview lands within seconds and the pin points at it, so "ready" is true long before
the full-resolution pass finishes.

### J4 · Bad captures are kept, good ones are thrown away — `MED` · `ASSUMED`
The package's own storage policy, adopted as-is. A capture bundle is a few hundred megabytes;
keeping every one fills a tablet inside a week. So a bundle is deleted **when its stitch met
its quality targets**, and kept when it did not — a bundle is a self-describing directory that
a better pipeline can re-stitch later, offline, from the office, without anybody returning to
site. A site visit costs more than every tablet in the fleet's storage put together.

**Consequence worth stating:** a failed capture takes up more room than a successful one. That
is the intended direction.

### J5 · The upload queue gets a real size, and gets it late — `LOW` · `ASSUMED`
Every other mode estimates its bytes at capture time (§G11). A sphere cannot: the number is the
length of a file that does not exist yet.

**Assumed:** a sphere capture is enqueued for upload when its stitch lands, with the panorama's
actual length. A capture whose stitch fails is never enqueued, which is correct — there is
nothing to upload.

### J6 · iOS is not built — `LOW` · `ASSUMED`
The package supports iOS and ships a Swift plugin, but its prebuilt `sphere_stitch.xcframework`
is 53 MB of static archive and this project targets Android only. It is not vendored.

**Assumed:** Android only, and reversible in one command —
`tools/build_native_mobile.sh --ios` regenerates it. `packages/sphere_view/ios/README.md` says
so at the top so nobody looks for a missing file.

### J7 · Leaving a capture early offers three answers, not two — `MED` · `ASSUMED`
The deck draws a capture that completes. It draws nothing for a crew that has
photographed the wall they came for and wants to stop.

**Assumed:** Back during a capture asks, and offers **Keep capturing / Finish here /
Discard**. "Finish here" keeps every frame on disk and stitches them — the package's
`finish()` is deliberately total ("a partial capture is not an error and is never treated as
one"), the pipeline fills the uncovered poles, and the review screen states the achieved
coverage before a minute of stitching is spent on it.

This is the same offer the package's own exit button makes, in the same words, reached from
the system Back button instead. Offering only Discard — which is what the first cut did — made
throwing the morning away the only alternative to shooting the ceiling.

With nothing yet photographed there is no question to ask, so it does not ask.

### J8 · A finished card clears itself; a failed one does not — `LOW` · `ASSUMED`
The stitch card over the plan is a notification, and the durable record is the pin.

**Assumed:** a clean finish takes its card down after 8 seconds — thirty stations would
otherwise leave thirty cards stacked over the plan. A **failure** stays until it is dismissed:
it is the only place Retry is offered, and its bundle was deliberately kept (§J4), so clearing
it silently would hide the one capture that needs a decision.

### J9 · The viewer is drag-first, with gyro on a toggle — `MED` · `ASSUMED`
The deck draws a 360° image being looked at and does not say how.

**The two input modes cannot both be live.** `SphereViewer` writes the view's yaw and pitch
from the pose stream on every sample at ~100 Hz, and its drag handler is explicitly gated on
there being no pose subscription — so with gyro look on, a drag is overwritten before the
finger lifts and the panorama simply does not respond to touch.

**Assumed: drag by default, gyro behind a labelled toggle.** Drag is the one that always
works — every device has a touchscreen, not every device has a usable gyroscope, and a
panorama is often reviewed flat on a desk rather than held up on site. Gyro is better when
pointing at something in the room, so it is one tap away rather than absent. If the package
reports no usable gyroscope the toggle falls back to drag and says so.

Pinch-zoom and double-tap-to-reset work in both modes.

---

## E. Not addressed at all

- **Localisation.** All copy is English and currently inlined at its point of use. Strings are
  short and centralisable when the requirement appears.
- **Accessibility beyond touch targets.** Semantics labels are applied to cards, badges and
  icon buttons. No contrast audit against the dark chrome has been run yet; a "glove-mode
  spacing audit" is listed as a next step in the prototype itself.
- **Analytics, crash reporting, feature flags.** Not mentioned anywhere.
- **Tablet.** Not mentioned anywhere.
