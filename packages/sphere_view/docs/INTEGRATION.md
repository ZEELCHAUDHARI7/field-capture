# Integrating `sphere_view`

The document a consuming app reads. `sphere_view` is a standalone package with
no application dependency — the [example app](../example) is the demo and the
working reference — so this is where the knowledge that would otherwise live in
an integration lives instead.

Five things are worth reading before you write any code, because each of them
is cheap to do now and expensive to retrofit:

1. [the three-call quickstart](#1-the-three-call-quickstart)
2. [the background queue](#2-the-background-queue-and-how-to-watch-it)
3. [what to persist](#3-what-to-persist) — and **where the heading comes from**
4. [the storage policy](#4-storage-policy-keep-the-bad-ones)
5. [the capability gate](#5-the-capability-gate-check-before-you-offer)

---

## 1. The three-call quickstart

```dart
// 1. create — probes the camera, derives the shot plan from the *measured*
//    intrinsics, and proves the plan covers the sphere. All before the preview
//    opens, so a device or a lens that cannot succeed costs one screen rather
//    than a walk round the building.
final session = await SphereCaptureSession.create(
  config: const SphereCaptureConfig(),
);

// 2. SphereCaptureView — the guided capture screen. It holds no capture logic;
//    it draws what the session reports and hands back the bundle.
final bundle = await Navigator.push<CaptureBundle>(
  context,
  MaterialPageRoute(
    builder: (_) => SphereCaptureView(
      session: session,
      onCompleted: (bundle) => Navigator.pop(context, bundle),
    ),
  ),
);

// 3. SphereStitcher — or, in almost every real app, the queue in §2 instead.
final result = await SphereStitcher().stitch(bundle);
```

`result.equirectPath` is a JPEG with its XMP GPano block already written, so it
opens as a photo sphere in Google Photos and in the package's own
[`SphereViewer`](#the-viewer). `result.report` is what it is worth.

Two screens either side of `SphereCaptureView` ship with the package and are
worth using rather than reimplementing:

* `SpherePreCaptureScreen` — the coaching screen. Its "pivot, don't walk"
  sentence is the parallax mitigation from architecture §3, and parallax is the
  one error in this pipeline that no amount of algorithm removes. Measured:
  3 cm of lens travel at 1 m puts S1 six times over target, and across the
  sweep in [`METRICS.md`](METRICS.md) SSIM collapses 0.97 → 0.63.
* `SphereReviewScreen` — the capture's own warnings in plain language, before a
  minute of stitching is spent on them.

### What `create` throws, and why you want it to

| Thrown | Means | What to do |
|---|---|---|
| `PoseSourceUnsupported` | No gyroscope. There is no reduced mode — see §5 | Do not offer the feature on this device at all |
| `InsufficientCoverageException` | The plan these intrinsics imply cannot cover the sphere | Show the message. It names the field of view it got |
| `PlatformException`, `StateError` | The camera would not open — permission denied, no usable rear camera, another app holding it | Show the message; on Android, check you requested `CAMERA` |

Neither of the first two is recoverable by trying again, and both are raised
*before* anything is metered, locked or shot. That ordering is the point: 90
seconds of somebody's time on a site is worth more than the code it takes to
refuse early.

---

## 2. The background queue, and how to watch it

**This is the default path, not an optimisation.** A stitch takes up to a
minute. A site walk has thirty stations. Blocking the user behind each one is
half an hour of standing still, which is the wrong product behaviour whatever
the panorama looks like at the end of it.

So: `finish()` hands back a bundle, the bundle goes in the queue, and the
manager keeps walking.

```dart
final queue = StitchQueue(directory: await getApplicationSupportDirectory());
await queue.load();   // picks up anything a previous run left behind
await queue.start();  // returns as soon as the drain is under way

queue.events.listen((event) {
  final id = event.entry.sessionId;
  if (event.progress != null)  updateRow(id, event.progress!.fraction);
  if (event.result != null)    markReady(id, event.result!);
  if (event.error != null)     markFailed(id, '${event.error}');
  if (event.paused)            showBanner(event.pauseReason);   // usually heat
});

// Later, per station — and note that nothing here is awaited for long:
await queue.enqueue(bundle, outputPath: whereYouWantThePanorama);
```

Four properties, each for a specific reason:

* **Persistent.** The queue survives the app being killed. An entry found in
  `running` at startup did not finish — nothing else can tell you so, because
  the process that would have written `done` no longer exists — and `load()`
  puts it back to `pending` and counts an interruption.
* **Serial.** Two concurrent stitches will run the device out of memory; the
  tier table sizes *one* stitch against the device.
* **Skipped when hot.** At `serious` thermal state the queue waits and says so.
  Stricter than the rule for a stitch the user asked for, because nobody is
  waiting for this one.
* **Resumable at bundle granularity.** A stitch killed halfway starts again
  from the beginning. Deliberate: a restart costs 60 s, and checkpointing warped
  frames and blender pyramids to disk would be a large amount of fragile code to
  save less than a minute.

### The thing that is easiest to break

Do not `await` a stitch anywhere on the capture path. It is easy to write

```dart
await queue.enqueue(bundle);
await queue.drained;          // ← this is the bug
```

and everything still works: the panoramas come out, correct, in order, with the
user standing still between them. The failure is invisible in a test and
obvious on a site. The example app's `test/widget_test.dart` pins the correct
behaviour with a fake stitcher, and it is worth copying that test rather than
the sentiment.

### When one fails

`maxAttempts` (3 by default) counts real failures; a run cut short by the app
being killed does not consume one. After that the entry is `failed` and stays
there. `queue.retry(sessionId)` puts it back with a fresh budget — the right
thing to call after the device has cooled, after the user has closed whatever
was competing for memory, or after a pipeline improvement. The bundle is still
on disk, because of §4.

### Background execution

Platform background limits are real — iOS gives a few minutes, Android wants a
foreground service for reliable long work — and this package acquires neither.
It is written so that **being killed at any moment is safe**, which is what
makes a foreground service an optimisation on your side rather than a
correctness requirement.

---

## 3. What to persist

Per station, four things:

| Persist | Why |
|---|---|
| `result.equirectPath` | The panorama. Keep it **outside** the bundle directory — §4 deletes the bundle |
| a thumbnail | Panoramas are 6144 px wide; a list that decodes them at full size is how a tablet runs out of memory. `Image.file(f, cacheWidth: 216)` is enough, or encode one once |
| `result.report` (as `toJson`) | The measurement, months later, when somebody asks why a defect is soft. `StitchReport.fromJson` reads it back |
| the **heading**, with its source | See below. It is the field that decides whether the sphere opens facing the right way |

### The heading is worth sourcing from your app

`PanoramaHeading` carries a value **and where it came from**, and the two are
not interchangeable:

```dart
session.setPlanHeading(127.5);         // best
session.setMagnetometerHeading(310.0); // fallback, and recorded as such
```

For a plan-based app this is nearly free and much better than the alternative.
The manager drew a walking path on a drawing whose north is surveyed, so the
facing direction at a station is *arithmetic* — the tangent of the drawn path —
and it is good to a degree or two. The magnetometer indoors is good to tens of
degrees: rebar, steel studs, lift motors and the building's own frame bend the
field, which is the same reason this package's attitude source is
`GAME_ROTATION_VECTOR` / `.xArbitraryCorrectedZVertical` and never the
compass.

Three consequences worth knowing:

* A plan heading **displaces** a magnetometer heading, never the reverse. A
  fresher reading from a worse instrument is still a worse answer.
* A magnetometer heading puts a plain-language warning into
  `report.warnings`. That is not pedantry — a panorama that opens 40° off looks
  like a stitching fault to everyone who did not take it.
* An **unknown** heading is written as *absent*, not as zero. Zero is a real
  bearing — due north — so a file claiming 0 for "we do not know" is
  indistinguishable from one surveyed facing north, and every viewer opens it
  confidently in the wrong direction.

`setLocation` is there too, and is supplied rather than measured: this package
holds no location permission and deliberately does not ask for one.

### The viewer

```dart
SphereViewer(image: File(path), showControls: true, gyroscopeEnabled: true)
```

To open facing a particular compass direction, read the metadata back and give
the controller the panorama's own heading:

```dart
SphereViewer(
  image: file,
  controller: SphereViewerController.forPanorama(
    metadata,               // from `onMetadata`, or `GPanoReader`
    lookAtCompassDegrees: 0,
  ),
)
```

---

## 4. Storage policy: keep the bad ones

> **Delete the `CaptureBundle` when the stitch met its quality targets. Keep it
> when it did not.**

```dart
if (result.report.meetsQualityTargets) {
  await bundle.directory.delete(recursive: true);
}
```

A bundle is 29 positions × up to 3 exposures of full-resolution JPEG — a few
hundred megabytes — so keeping every one of them fills a tablet inside a week.
That is the argument for deleting, and it only applies to the captures that
came out.

The captures that did **not** come out are the ones worth keeping, and the
reason is that a `CaptureBundle` is a self-describing directory: it can be
re-stitched, later, by a better pipeline, offline, from the office. Registration
improves; fusion gets fixed; a device's distortion model becomes available.
Every one of those turns a bad panorama into a good one **without anybody
returning to site**, and a site visit costs more than every tablet in the
fleet's storage put together.

So the rule is not "delete when you are short of space". It is: the artefact you
keep is whichever of the two is still capable of getting better.

The example app implements exactly this in `StationStore._onStitched`, and its
test asserts both halves.

---

## 5. The capability gate: check before you offer

```dart
final report = await SphereCapabilityProbe.probe();
if (!report.isSupported) {
  // Hide the feature. Do not offer it and apologise later.
  return DisabledTile(reason: report.blockingReason!);
}
showCaptureButton(subtitle: report.headline);
```

**At the feature entry point, not mid-flow.** Discovering on site that a tablet
cannot do this is acceptable. Discovering it after 25 captures is not, and
neither is discovering it at the stitch, an hour later, back in the office.

The probe is cheap by construction — motion capabilities, camera *descriptors*
and total RAM, with **no camera opened** — precisely so that it can run before
a button is drawn. A gate that cost a camera open would be moved later in the
flow by the first person who noticed the delay, which defeats it.

`SphereCapability` has four values, worst first:

| Value | Meaning | What your app should do |
|---|---|---|
| `unsupportedNoNativeLibrary` | The stitching library will not load on this device's ABI | **Hide the feature.** Capture would work perfectly and produce nothing: the library ships `arm64-v8a` only, so on an `x86_64` emulator or a 32-bit tablet every frame is taken, the queue accepts the bundle, and the stitch fails ninety seconds later. The bundles are not wasted — build the library for that ABI and they all stitch |
| `unsupportedNoGyro` | No gyroscope | **Hide the feature.** There is no useful reduced mode: without a gyroscope there is no attitude source that tracks a pan, so every frame would be seeded from tilt with no heading at all. The panorama would not be worse, it would be wrong |
| `noBracketing` | No hardware exposure bracket | Offer it, and say what it costs. One exposure cannot hold the 12–16 EV of a site interior with a window, so windows blow out and shadows block up |
| `noDistortionModel` | The device publishes no lens calibration | Offer it. Joins are very slightly less exact |
| `full` | Everything available | Offer it |

Then hand the probe's own answer back to the session:

```dart
final session = await SphereCaptureSession.create(
  config: report.configFrom(const SphereCaptureConfig()),
  capability: report,   // saves a second probe
);
```

`configFrom` is not a nicety. Asking for a 3-shot bracket on a `LEGACY` Android
camera returns **one** frame per position, and a frame gate expecting three
rejects every one of them — a device that captures nothing at all, dressed up as
a device without HDR.

`report.warnings` are already coded and already have sentences; showing them at
the entry point is how "this tablet has no HDR" stops being mistaken for "this
app is broken" three weeks later.

---

## Permissions, and the one that fails silently

Declare these in your app. The package declares what it can and requests
nothing — a library that pops a system dialog decides on your behalf when the
user is interrupted.

**Android** (`android/app/src/main/AndroidManifest.xml` — `CAMERA` is merged in
from the package's own manifest, but you must **request it at runtime**;
Camera2 throws a bare `SecurityException` from inside the framework otherwise):

```xml
<uses-permission android:name="android.permission.CAMERA" />
```

**iOS** (`ios/Runner/Info.plist`):

```xml
<key>NSCameraUsageDescription</key>
<string>…to capture 360° panoramas.</string>
<key>NSMotionUsageDescription</key>
<string>…to track which way the device is pointing during a capture.</string>
```

`NSMotionUsageDescription` is the one to get right. Apple's guidance is to
include it whenever an app links CoreMotion, and the failure mode when it is
missing is the worst kind: not a crash and not a prompt, but an attitude stream
that never delivers — so the capture screen shows dots that do not move,
the shutter gate never opens, and it reads as a broken app rather than as a
missing key. It costs one line. Include it.

Full details, including minimum OS versions and why they are what they are, in
the [README](../README.md#platform-setup).

---

## What this package will not do for you

Named so that nobody spends a day looking for them:

* **No plan viewer, no map, no PDF, no backend, no authentication.** Those are
  yours. The example app deliberately has none of them either.
* **No location permission**, and no request for one. `setLocation` takes a fix
  you already hold.
* **No background execution guarantee.** See §2.
* **No thumbnail generation.** One line in your app, and you know what size you
  need.
* **No retry-on-a-schedule.** `queue.retry` is explicit, because a queue that
  retries forever is a tablet that gets warm in a bag.

## The honest limits

They are in [the README](../README.md#honest-limits) and they are worth reading
before you promise anything to a customer: parallax is irreducible and is a
capture-technique problem, the nadir is your own feet, a person who walks
through the sphere appears twice, and a device without a gyroscope cannot be
supported at all.

`docs/CAPTURE_TECHNIQUE.md` is the one-page version for the people holding the
tablet. Phase 12 claims it has more effect on output quality than most of the
algorithm work, and the parallax measurements in `METRICS.md` are why that is a
statement rather than encouragement.
