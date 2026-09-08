# `docs/`

Documentation for people *consuming* `sphere_view`, as opposed to
[`phases/`](../phases), which is documentation for people building it.

| File | What it is | Lands in |
|---|---|---|
| [`CAPTURE_TECHNIQUE.md`](CAPTURE_TECHNIQUE.md) | **The one to print.** One page for the site team, with the pivot diagram and the measured cost of getting it wrong. Phase 12 §6 claims it has more effect on output quality than most of the algorithm work, and the parallax measurement in `METRICS.md` says why that is true rather than encouraging | Phase 12 §6 |
| [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) | Symptom → cause → fix, both by what you can see in a bad panorama and by warning code. `test/troubleshooting_doc_test.dart` fails if a code has no row, so it cannot drift out of date silently | Phase 12 §6 |
| [`METRICS.md`](METRICS.md) | What S1–S10 mean, how to read a `StitchReport`, the measured parallax floor, and where the stitch minute goes | Phase 12 §6 |
| [`DEVICE_MATRIX.md`](DEVICE_MATRIX.md) | Generated from a device run, never typed. Currently **0 of 6 fleet rows** — every row says so rather than being absent | Phase 12 §1, **open: needs hardware** |
| [`FIELD_CORPUS.md`](FIELD_CORPUS.md) | The protocol for the seven real-site scenes. Takes a morning; every capture becomes a permanent CI fixture | Phase 12 §4, **open: needs a site visit** |
| [`PLATFORM_ANDROID.md`](PLATFORM_ANDROID.md) | The non-negotiables for the Android side of the plugin | notes now, code in Phase 06 |
| [`PLATFORM_IOS.md`](PLATFORM_IOS.md) | The non-negotiables for the iOS side | notes now, code in Phase 06 |
| [`CAPTURE_UI_FIELD_CHECKLIST.md`](CAPTURE_UI_FIELD_CHECKLIST.md) | The two Phase 09 exit criteria no test rig can check — legible in direct sunlight, operable in work gloves — as a checklist to run on a real tablet, outdoors | Phase 09 §6, **still open** |
| [`INTEGRATION.md`](INTEGRATION.md) | **The one a consuming app reads.** The three-call quickstart, how to watch the background queue, what to persist, why the heading comes from the host app and not the compass, the storage policy, and the capability gate. Integration is deliberately out of scope as *code* — this is where the knowledge lives instead | Phase 13 §3 |
| [`BUILDING_NATIVE.md`](BUILDING_NATIVE.md) | How the OpenCV and pipeline builds work, and what to do when one fails. The build itself is `tools/build_native_mobile.sh`; this describes it rather than replacing it | Phase 13 §2 |

## A note on `android/` and `ios/`

Architecture §5 lists platform folders at the package root, and they are
genuinely part of the final layout — but they are **not** created in Phase 01.
A bare `android/` or `ios/` directory beside a `pubspec.yaml` that has no
`flutter: plugin:` block makes the Flutter tool classify this package as an
*app*: it writes `local.properties`, `GeneratedPluginRegistrant`, and
`ios/Flutter/` scaffolding on every command, and regenerates them after every
deletion.

So Phase 06 creates both folders properly, with the `plugin:` block added in the
same commit, and the platform requirements live here until then.
