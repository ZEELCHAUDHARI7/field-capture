# Phase 10 — Isolate pipeline, progress, cancellation, memory tiers

**Goal:** run a 60-second native stitch without dropping a single UI frame, with
working progress and working cancellation, inside the memory budget of the worst
device we support.

**Duration:** 3–4 days. **Depends on:** 03, 04, 05.

---

## 1. Why an isolate is mandatory

FFI calls **block the calling isolate**. A 60 s `sv_stitch` on the main isolate
freezes the UI for a minute — no progress bar, no cancel, and on both platforms
the OS watchdog may kill the app. So the FFI call happens on a worker isolate.

The subtlety: an isolate does not make the *native* work concurrent with anything
— it makes it concurrent with **Dart**. The C++ still runs on a real thread and
still competes for CPU and memory. The isolate buys a responsive UI, not free
throughput.

---

## 2. Structure

```dart
Future<StitchResult> stitch(CaptureBundle bundle, {void Function(StitchProgress)? onProgress}) async {
  final tier   = bundle.deviceInfo['tier'] as String? ?? await MemoryTier.probe();
  final request = StitchRequest.from(bundle, tier: tier, outputPath: ...);

  // Shared memory, allocated on the MAIN isolate so both sides can see it.
  final progress = calloc<SvProgress>();
  try {
    final poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      onProgress?.call(StitchProgress(
        stage:    StitchStage.values[progress.ref.stage],
        fraction: progress.ref.permille / 1000.0,
      ));
    });

    final reportJson = await Isolate.run(() => _runNativeStitch(
      request.toJson(), progress.address));   // pass the ADDRESS, not the pointer

    poll.cancel();
    return StitchResult.fromReport(reportJson);
  } finally {
    calloc.free(progress);
  }
}
```

Three details that are easy to get wrong:

1. **Pass `progress.address` (an `int`), not the `Pointer`.** Pointers are not
   sendable across isolates; the integer address is, and both isolates share the
   same process address space, so reconstructing with `Pointer.fromAddress` is
   valid. This is the whole trick that makes shared-memory progress work.
2. **Allocate on the main isolate and free in `finally`.** If the worker owned the
   allocation, a crash there would leak it, and the poller could read freed memory.
3. **`DynamicLibrary.open` must happen inside the worker isolate.** FFI lookups
   are per-isolate; a handle captured from the main isolate is not usable.

### Why shared memory rather than `NativeCallable.listener`

`NativeCallable.listener` requires the isolate that created it to have a live
event loop for the entire native call, and the C++ side must hold a callback
pointer whose validity is tied to that isolate's lifetime. Getting the teardown
ordering wrong produces crashes that only appear under cancellation — the exact
path that is hardest to test. A polled `int32` triple has no lifetime hazards, and
100 ms polling is far finer than a human perceives.

---

## 3. Cancellation

`progress.ref.cancel = 1` from the main isolate. C++ polls it:

- between positions in HDR fusion (Phase 05)
- between frames in feature detection and matching (Phase 03)
- between **blend strips** (Phase 04 §5)

and returns `SV_CANCELLED` after freeing everything.

Requirement: cancellation takes effect within **500 ms**. The longest
uninterruptible unit is a single blend strip, which sets the practical lower
bound — so if strip time exceeds 500 ms at `high` tier, add a check inside the
per-strip `feed` loop too.

Test it under load, repeatedly. Cancel-during-blend is the case most likely to
leak or crash, and it is the case a user hits most often (they change their mind
while watching the progress bar).

---

## 4. Memory tiers

```dart
class MemoryTier {
  static Future<QualityTier> probe() async {
    final totalMb = await _platform.totalPhysicalMemoryMb();  // MemInfo / os_proc_available_memory
    if (totalMb < 3072) return QualityTier.low;    // 4096x2048, 4 strips
    if (totalMb < 6144) return QualityTier.mid;    // 6144x3072, 6 strips
    return QualityTier.high;                       // 8192x4096, 8 strips
  }
}
```

Use **total** physical memory for the tier decision, not available memory —
available fluctuates and would make output resolution non-deterministic between
runs on the same device, which makes bug reports useless.

On iOS also consult `os_proc_available_memory()` as a **safety check** before
starting: if it is below the tier's estimated peak, drop a tier and record a
warning. iOS kills on memory pressure with no recoverable signal, so a
pre-flight check is the only defence.

### OOM recovery

Wrap the native call: on `SV_OUT_OF_MEMORY` or a `std::bad_alloc` caught at the
ABI boundary, drop one tier and retry **once**, with the downgrade recorded in
`StitchReport.warnings`. Two failures is a hard error with an honest message.

C++ must catch all exceptions at the ABI boundary — an exception crossing into
Dart is undefined behaviour and crashes the app:

```cpp
int32_t sv_stitch(...) noexcept {
    try { return run_stitch(...); }
    catch (const std::bad_alloc&)  { return SV_OUT_OF_MEMORY; }
    catch (const cv::Exception& e) { copy_msg(e.what()); return SV_OPENCV_ERROR; }
    catch (const std::exception& e){ copy_msg(e.what()); return SV_ERROR; }
    catch (...)                    { return SV_UNKNOWN_ERROR; }
}
```

---

## 5. Where the stitch runs

The user is standing on a site with more stations to walk to. Blocking them behind
a 60 s stitch per station is the wrong product behaviour.

**Default: queue and stitch in the background.** `finish()` returns a
`CaptureBundle` immediately; the bundle goes to a persistent queue and stitches
when convenient (app foreground, device not thermally stressed, ideally charging).
The manager keeps walking.

- Queue persisted to disk, so it survives app restarts. A `CaptureBundle` is
  already a self-describing directory (Phase 01 §3.4), so this is nearly free.
- Serial, one at a time — two concurrent stitches will OOM.
- Skip when `thermalState >= serious` (Phase 06 §5); resume when it drops.
- `SphereStitcher().stitchNow(bundle)` remains available for "stitch this one now".

Background execution limits are real on both platforms: iOS gives a few minutes,
Android needs a foreground service for reliable long work. So the queue must be
**resumable at stage granularity** — if killed mid-stitch, restart that bundle
from the beginning rather than losing it. Do not attempt to checkpoint inside the
native pipeline; the complexity is not worth it when a restart costs 60 s.

---

## 6. Tests

- 29-frame stitch on the main isolate never drops a UI frame (measure with
  `SchedulerBinding.instance.addTimingsCallback`; assert zero frames > 32 ms)
- progress advances monotonically through every `StitchStage`, reaching 1.0
- cancel at 10%, 50%, 90% → returns within 500 ms, no leak (measure RSS before/after
  100 cancel cycles)
- cancel during blend specifically, 50 iterations, no crash
- `Pointer.fromAddress` round-trip works across the isolate boundary
- forced `bad_alloc` → tier downgrade + retry + warning recorded
- C++ exception at the boundary is caught and mapped, not propagated
- tier probe returns a stable value across 20 calls
- queue survives a simulated app kill mid-stitch and restarts that bundle
- two enqueued bundles stitch serially, never concurrently

---

## 7. Pitfalls

1. **`Isolate.run` captures its closure**, so anything referenced must be
   sendable. Keep the closure to `(String json, int address)`.
2. **Native library path differs per platform** — `DynamicLibrary.process()` on
   iOS (statically linked), `DynamicLibrary.open('libsphere_stitch.so')` on
   Android. Get this wrong and it works on one platform only.
3. **`calloc`, not `malloc`.** An uninitialised `cancel` field containing garbage
   cancels the stitch immediately, which presents as "stitching does nothing".
4. **Do not poll faster than ~10 Hz.** The `Timer` runs on the main isolate and
   competes with the UI you are trying to keep smooth.
5. **`report_json_out` is heap-allocated by C++** and must be freed via `sv_free`,
   not Dart's `calloc.free`. Mismatched allocators corrupt the heap in a way that
   manifests much later.
6. **Progress writes must be plain aligned `int32` stores.** No atomics needed for
   a monotonic counter read by one poller, but the fields must be `int32_t` and the
   struct must have identical layout in both languages — assert `sizeOf<SvProgress>() == 12`.

---

## Exit criteria

- [ ] Zero dropped UI frames during a full stitch
- [ ] Cancellation within 500 ms from any stage, no leak over 100 cycles
- [ ] All ten tests in §6 pass
- [ ] Tier probe + OOM downgrade verified on a real 3 GB Android tablet
- [ ] Background queue survives app kill and thermal pauses
