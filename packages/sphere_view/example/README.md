# `sphere_view` demo

One screen, three actions, no chrome. It exists to prove the package works end
to end and to show what calling it looks like — everything a consuming app would
own (a plan viewer, PDF export, a map, authentication, a backend) is
deliberately absent.

```
┌──────────────────────────────────┐
│  sphere_view demo         [Kill] │
│                                  │
│  [   Capture a 360°   ]          │
│                                  │
│  ── Captured ──────────────      │
│  ┌────┐ Station 3                │
│  │ ▦  │ 6144×3072 · ready        │
│  └────┘ S1 0.42 px · coverage …› │
│  ┌────┐ Station 2                │
│  │ ◔  │ stitching 42% · warping  │
│  └────┘                          │
│  ┌────┐ Station 1                │
│  │ ⧗  │ queued                   │
│  └────┘                          │
│                                  │
│  [ Device report ]  [ Clear ]    │
└──────────────────────────────────┘
```

## Running it

```sh
flutter run                      # from this directory, on a real device
```

A simulator will not do: there is no camera, no gyroscope and no thermal state
in one. The capability probe refuses on the first two, which is itself worth
seeing once.

The native stitch library has to exist before a stitch can run. From a clean
checkout, one command builds it for both platforms:

```sh
../tools/build_native_mobile.sh       # OpenCV + libsphere_stitch, Android + iOS
```

See [`../docs/BUILDING_NATIVE.md`](../docs/BUILDING_NATIVE.md).

## The seven flows

| # | Flow | Where |
|---|---|---|
| 1 | **Capture** — pre-capture coaching, metering sweep, 29 guided positions | `CaptureFlow.start` in `lib/capture_flow.dart` |
| 2 | **Background queue** — capture two or three back to back without waiting; rows show `queued → stitching N% → ready` | `StationStore` in `lib/stations.dart`, and the fact that nothing in `CaptureFlow` awaits a stitch |
| 3 | **View** — tap a ready thumbnail; gyro look is a switch | `lib/viewer_page.dart` |
| 4 | **Report** — tap the metrics line for every metric and warning in plain language | `lib/report_page.dart` |
| 5 | **Export** — the share sheet, so the equirect can be opened in Google Photos and criterion S10 checked by somebody else's XMP parser | `lib/viewer_page.dart` |
| 6 | **Device report** — capability, tier, intrinsics, bracketing, and a *measured* burst time | `lib/device_report_page.dart` |
| 7 | **Resume after a kill** — the `Kill` button ends the process; reopen and a half-finished capture is a station you can resume | `lib/simulate_kill.dart` |

### Flow 2 is the one that matters

Capture a station, press "Capture a 360°" again immediately, and capture a
second one. The first row keeps counting up while you are shooting the second.
That is the real use case — a manager walking a site does not stand still for a
minute per station — and it is the easiest behaviour in the package to break
without noticing, because breaking it looks like nothing: the panoramas still
come out, one at a time, with somebody waiting.

`test/widget_test.dart` pins it on a laptop with a fake stitcher, kill included.

### Flow 7, in full

1. Start a capture and shoot a few positions.
2. Press **Simulate app kill**. The process ends — that is a real `exit(0)`, not
   a simulation of one, because what is being demonstrated is what survives a
   process that stops without warning.
3. Reopen the app. The station is back, at the position it had reached, with a
   **Resume** button. A stitch that was running is back in the queue with its
   interruption counted.

Nothing about that path is special-cased for recovery: it is the same `load()`
every cold start runs.

## The on-device checklist

Everything below is demonstrated in code and pinned by `test/widget_test.dart`
on a laptop. **None of it has been run on hardware**, and three of the seven
flows cannot be: a simulator has no camera, no gyroscope and no thermal state.
So this is the list to work through the first time the demo meets a tablet, in
this order, because each step needs the one before it.

| | Flow | What to check | Passed? |
|---|---|---|---|
| 1 | Device report | Tap **Device report** before anything else. Capability is not `unsupportedNoGyro`, the tier is sensible for the RAM, and **Measure this device** returns a burst wall clock — the number R3 established nobody has ever published | ☐ |
| 2 | Capture | The pre-capture screen appears, the metering sweep runs, and the dot goes in the ring. 29 positions, and note the wall clock: S7 is 90 s | ☐ |
| 3 | Background queue | Press **Capture a 360°** again *immediately*. The first row must keep counting `stitching N%` while you shoot the second. **This is the one that matters** | ☐ |
| 4 | Report | Tap the metrics line. Every criterion has a number and a target; any warning reads as a sentence a site manager could act on | ☐ |
| 5 | View | Tap a ready thumbnail, then turn **Gyro look** on and physically turn on the spot. The room must move *with* you. If east and west are swapped, the conversion is mirrored — see the Phase 11 note in `phases/README.md` | ☐ |
| 6 | Export | Share → save to Photos, then open it in **Google Photos**. It must open as a sphere you can drag around, not as a very wide photo. That is criterion S10, and this is the only way to check it | ☐ |
| 7 | Resume | Start a capture, shoot a few positions, press **Simulate app kill**, reopen. The station is back with a **Resume** button and the positions it had. Then queue a stitch and kill during it: the row returns as `queued · interrupted 1×` and finishes | ☐ |

Steps 2, 3 and 7 also want a second run with the tablet **hot** — leave it in the
sun for ten minutes — because the queue's thermal hold is the part with no
laptop equivalent at all.

## Tests

```sh
flutter test                  # the demo's own, laptop-only
```

The device suites live in [`integration_test/`](integration_test) and are what
produce the numbers no desk can — burst wall clock, the timestamp fit, the
90-second session. See [`integration_test/RUNNING.md`](integration_test/RUNNING.md).
