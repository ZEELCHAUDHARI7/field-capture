import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sphere_view/sphere_view.dart';

import '../../../shared/storage/sphere_storage.dart';
import '../../plan/data/sphere_capture_store.dart';
import '../../plan/models/plan_marker.dart';
import '../../plan/state/workspace_controller.dart';
import '../../uploads/state/upload_queue_controller.dart';
import '../models/stitch_job.dart';

/// The one stitch queue, for the life of the app.
///
/// Serial by construction — two concurrent stitches run a tablet out of memory,
/// and the tier table sizes *one* stitch against the device. Persistent, so an
/// entry survives the app being killed. Held here rather than created per
/// screen because both of those properties are properties of the queue file,
/// and two queues over one file is two answers to "what is still to do".
final stitchQueueProvider = Provider<StitchQueue>((ref) {
  final SphereStorage storage = ref.watch(sphereStorageProvider);
  final StitchQueue queue = StitchQueue(directory: storage.queueDirectory);
  ref.onDispose(() => unawaited(queue.dispose()));
  return queue;
});

/// What each capture's stitch is doing, keyed by session id.
///
/// A projection of the queue's event stream, kept because the queue reports
/// changes and the plan needs current state.
///
/// A job that finishes cleanly takes itself out of the map a few seconds later:
/// its card is a notification, and the durable record is the pin, which is by
/// then wearing a "ready" badge and opening the panorama. Without that, thirty
/// stations leave thirty cards stacked over the plan. A job that **failed**
/// stays until it is dismissed — it is the only place Retry is offered, and
/// silently clearing it would hide the one capture that needs a decision.
class StitchJobsController extends Notifier<Map<String, StitchJob>> {
  /// True once this controller has been torn down.
  ///
  /// The event handlers below do real file IO and then touch `ref` again. A
  /// disposed `ref` throws, and these futures are deliberately not awaited by
  /// anyone — so the throw would surface as an unhandled async error with no
  /// stack pointing at the cause. Reachable in one tap: the demo console's
  /// "Delete every captured 360" stops the queue, which cancels the running
  /// stitch and pushes an event, and then invalidates this provider while that
  /// event's handler is still inside a file write.
  bool _disposed = false;

  /// How long a finished card stays up before clearing itself.
  ///
  /// Long enough to be read and tapped by somebody who was looking at the plan
  /// when it landed, short enough that a walk does not end behind a wall of
  /// them.
  static const Duration clearAfter = Duration(seconds: 8);

  final Map<String, Timer> _clearTimers = <String, Timer>{};

  @override
  Map<String, StitchJob> build() {
    final StitchQueue queue = ref.read(stitchQueueProvider);
    final StreamSubscription<StitchQueueEvent> subscription =
        queue.events.listen(_onEvent);
    ref.onDispose(() {
      _disposed = true;
      for (final Timer timer in _clearTimers.values) {
        timer.cancel();
      }
      _clearTimers.clear();
      unawaited(subscription.cancel());
    });
    unawaited(_boot(queue));
    return const <String, StitchJob>{};
  }

  /// Picks up anything a previous run left behind, then starts draining.
  ///
  /// `load()` is what makes a kill survivable: an entry found `running` did not
  /// finish — the process that would have written `done` no longer exists — so
  /// it goes back to `pending` and is counted as an interruption rather than as
  /// a failed attempt.
  Future<void> _boot(StitchQueue queue) async {
    try {
      await queue.load();
    } on Object {
      // A queue file this build cannot read is not worth taking the app down
      // for. The bundles are still on disk and can be re-queued by hand.
      return;
    }
    if (_disposed) return;

    final SphereCaptureStore store = ref.read(sphereCaptureStoreProvider);

    // Everything unfinished, not just what is pending. A `failed` entry is
    // exactly the one worth surfacing after a restart — its bundle was kept on
    // purpose, and `retry` is the only way to use it. Seeding only `pending`
    // left the plan offering a Retry that did nothing at all.
    final Map<String, StitchJob> resumed = <String, StitchJob>{
      for (final StitchQueueEntry entry in queue.entries)
        if (entry.status != StitchQueueStatus.done)
          entry.sessionId: _recoveredJobFor(entry, store),
    };
    if (resumed.isNotEmpty) state = <String, StitchJob>{...state, ...resumed};

    await queue.start();
  }

  /// Hands a finished capture to the queue and returns immediately.
  ///
  /// Nothing here awaits a stitch. That is the whole point: `finish()` gives
  /// back a bundle, the bundle goes in the queue, and the crew keeps walking. A
  /// site walk has thirty stations and a stitch takes up to a minute, so
  /// blocking on each one is half an hour of standing still.
  Future<void> enqueue({
    required CaptureBundle bundle,
    required String captureName,
    required String calibrationId,
  }) async {
    final SphereStorage storage = ref.read(sphereStorageProvider);
    final String sessionId = bundle.sessionId;

    state = <String, StitchJob>{
      ...state,
      sessionId: StitchJob(
        sessionId: sessionId,
        captureName: captureName,
        calibrationId: calibrationId,
      ),
    };

    final StitchQueue queue = ref.read(stitchQueueProvider);
    await queue.enqueue(bundle, outputPath: storage.panoramaPath(sessionId));

    // **Enqueueing does not start anything.** `StitchQueue._drain` returns the
    // moment it finds nothing pending, and `enqueue` never restarts it — so the
    // drain that ran at app boot, over an empty queue, has already finished.
    // Without this the first capture of a session sits at 0% forever and then
    // completes on the next launch, because `load()` finds it pending and
    // `start()` picks it up. `start()` is idempotent, so calling it every time
    // is free.
    //
    // Not awaited: it returns once the drain is under way, and the whole point
    // of this path is that the crew walks on.
    unawaited(queue.start());
  }

  /// Puts a failed entry back with a fresh attempt budget.
  ///
  /// Explicit rather than scheduled: a queue that retries forever is a tablet
  /// that gets warm in a bag. The right moment is after the device has cooled,
  /// or after whatever was competing for memory has been closed.
  ///
  /// The queue is asked **first**, and the pin only moves if it said yes. The
  /// other order looks harmless and is not: `StitchQueue.retry` returns false
  /// whenever the entry is missing or is not `failed`, and a marker already
  /// flipped to `stitching` for a retry that never started shows a spinning
  /// badge that nothing will ever clear.
  Future<void> retry(String sessionId) async {
    if (sessionId.isEmpty) return;
    final StitchQueue queue = ref.read(stitchQueueProvider);

    if (!await queue.retry(sessionId)) {
      // Nothing the queue can do — the entry is gone, or it was never failed.
      // Say so rather than leaving a card that will not move.
      _put(
        (state[sessionId] ?? await _recoveredJob(sessionId)).copyWith(
          done: true,
          error: 'this capture is no longer in the stitch queue',
        ),
      );
      return;
    }

    _put(
      (state[sessionId] ?? await _recoveredJob(sessionId)).copyWith(
        clearError: true,
        done: false,
        fraction: 0,
        message: 'Queued',
      ),
    );

    await _updateMarker(
      sessionId,
      (CaptureMarker marker) => marker.copyWith(
        stitch: SphereStitchState.stitching,
        clearStitchError: true,
      ),
    );

    // `retry` only moves the entry back to `pending`; something still has to
    // work it. See `enqueue` — the drain does not restart itself.
    unawaited(queue.start());
  }

  /// Takes a finished or failed card off the plan. The panorama and the entry
  /// are untouched; this is only the notification.
  void dismiss(String sessionId) {
    _clearTimers.remove(sessionId)?.cancel();
    if (_disposed) return;
    final Map<String, StitchJob> next = <String, StitchJob>{...state}
      ..remove(sessionId);
    state = next;
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  void _onEvent(StitchQueueEvent event) {
    final String id = event.entry.sessionId;
    final StitchJob job = state[id] ??
        _recoveredJobFor(event.entry, ref.read(sphereCaptureStoreProvider));

    if (event.paused) {
      _put(job.copyWith(pauseReason: event.pauseReason));
      return;
    }

    final StitchProgress? progress = event.progress;
    if (progress != null) {
      // Every capture is stitched twice — once small for a quick preview, then
      // once at the device's real tier — and each pass reports its own 0..1.
      //
      // Both drive the bar. Pinning the preview pass to the previous fraction
      // (which is what this did first) leaves the card reading 0% for the whole
      // of it, and a bar that never moves is indistinguishable from a hung
      // stitch. The bar restarting once is legible because the line above it
      // says which pass is running; a bar that sits still is not.
      _put(
        job.copyWith(
          stage: progress.stage,
          fraction: progress.fraction,
          message: event.preview
              ? 'Quick preview — ${progress.message ?? progress.stage.name}'
              : 'Full resolution — ${progress.message ?? progress.stage.name}',
          clearPauseReason: true,
        ),
      );
      return;
    }

    final StitchResult? result = event.result;
    if (result != null) {
      if (event.preview) {
        _put(job.copyWith(previewReady: true, clearPauseReason: true));
        unawaited(_onPreview(id, result));
      } else {
        _put(job.copyWith(done: true, fraction: 1, clearPauseReason: true));
        unawaited(_onStitched(id, result, job));
      }
      return;
    }

    final Object? error = event.error;
    if (error != null) {
      // An error fires on every failed attempt, not only the last. Only a
      // terminal one is worth telling the crew about — the others are about to
      // be retried on their own.
      if (event.entry.status != StitchQueueStatus.failed) {
        _put(job.copyWith(message: 'Retrying — $error', clearPauseReason: true));
        return;
      }
      _put(job.copyWith(error: '$error', done: true, clearPauseReason: true));
      unawaited(_onFailed(id, '$error'));
    }
  }

  /// The preview is a complete panorama at 2048 px, so it is worth pointing the
  /// pin at straight away. If the full pass then fails, there is still something
  /// to look at rather than nothing.
  Future<void> _onPreview(String sessionId, StitchResult result) async {
    await _updateMarker(
      sessionId,
      (CaptureMarker marker) => marker.copyWith(
        previewPath: result.equirectPath,
        stitch: SphereStitchState.ready,
      ),
    );
  }

  Future<void> _onStitched(
    String sessionId,
    StitchResult result,
    StitchJob job,
  ) async {
    final CaptureMarker? marker = await _updateMarker(
      sessionId,
      (CaptureMarker m) => m.copyWith(
        panoramaPath: result.equirectPath,
        previewPath: StitchQueueEntry.previewPathFor(result.equirectPath),
        stitch: SphereStitchState.ready,
        reportJson: jsonEncode(result.report.toJson()),
        clearStitchError: true,
      ),
    );

    // The upload is enqueued here rather than at capture time, because this is
    // the first moment the real byte count exists. The mock queue estimated it;
    // there is no longer any need to.
    if (marker != null) {
      int sizeBytes;
      try {
        sizeBytes = await File(result.equirectPath).length();
      } on Object {
        sizeBytes = 0;
      }
      if (_disposed) return;

      // The level from the store rather than from the job: a capture recovered
      // after a kill has no level on its job, and an upload attributed to no
      // level is one nobody can find.
      final String calibrationId = job.calibrationId.isNotEmpty
          ? job.calibrationId
          : (ref.read(sphereCaptureStoreProvider).calibrationOf(sessionId) ??
              '');

      ref.read(uploadQueueProvider.notifier).enqueue(
            name: marker.name,
            calibrationId: calibrationId,
            mode: marker.mode,
            sizeBytes: sizeBytes,
          );
    }

    await _applyStoragePolicy(sessionId, result);
  }

  /// **Delete the capture bundle when the stitch met its quality targets. Keep
  /// it when it did not.**
  ///
  /// A bundle is 29 positions of full-resolution JPEG — a few hundred megabytes
  /// — so keeping every one fills a tablet inside a week. That is the argument
  /// for deleting, and it only applies to the captures that came out.
  ///
  /// The ones that did not are the ones worth keeping: a bundle is a
  /// self-describing directory and can be re-stitched later, offline, by a
  /// better pipeline. Every one of those turns a bad panorama into a good one
  /// without anybody returning to site, and a site visit costs more than every
  /// tablet in the fleet's storage put together.
  Future<void> _applyStoragePolicy(
    String sessionId,
    StitchResult result,
  ) async {
    if (!result.report.meetsQualityTargets || _disposed) return;
    final Directory bundle =
        ref.read(sphereStorageProvider).bundleDirectory(sessionId);
    try {
      if (await bundle.exists()) await bundle.delete(recursive: true);
    } on Object {
      // Failing to reclaim space is not worth surfacing. The next capture will
      // try again, and the panorama is already written.
    }
  }

  Future<void> _onFailed(String sessionId, String error) async {
    await _updateMarker(
      sessionId,
      (CaptureMarker marker) => marker.copyWith(
        stitch: marker.hasPanorama
            // A preview landed before the full pass died. There is still
            // something to open, so the pin should not claim otherwise.
            ? SphereStitchState.ready
            : SphereStitchState.failed,
        stitchError: error,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _put(StitchJob job) {
    if (_disposed) return;
    state = <String, StitchJob>{...state, job.sessionId: job};

    // A clean finish clears itself; a failure waits to be dealt with.
    if (job.done && !job.isFailed) {
      _clearTimers[job.sessionId]?.cancel();
      _clearTimers[job.sessionId] =
          Timer(clearAfter, () => dismiss(job.sessionId));
    } else {
      _clearTimers.remove(job.sessionId)?.cancel();
    }
  }

  /// A job for an entry the app did not enqueue this run — one recovered from
  /// the queue file after a kill.
  ///
  /// The queue knows only session ids, so the name and the level both come from
  /// the store. The level matters: it is what the finished panorama's upload is
  /// attributed to, and every other item in that queue carries a real one.
  StitchJob _recoveredJobFor(StitchQueueEntry entry, SphereCaptureStore store) {
    final CaptureMarker? marker = _markerFor(entry.sessionId, store);
    final bool failed = entry.status == StitchQueueStatus.failed;
    return StitchJob(
      sessionId: entry.sessionId,
      captureName: marker?.name ?? 'Mobile 360°',
      calibrationId: store.calibrationOf(entry.sessionId) ?? '',
      done: failed,
      error: failed
          ? (entry.lastError ?? 'the stitch did not finish')
          : null,
      message: failed ? null : 'Resuming after the app was closed',
    );
  }

  /// The same, for a session the map has lost track of.
  Future<StitchJob> _recoveredJob(String sessionId) async {
    final SphereCaptureStore store = ref.read(sphereCaptureStoreProvider);
    // Already loaded in practice; cheap and idempotent when it is.
    await store.load();
    final CaptureMarker? marker = _markerFor(sessionId, store);
    return StitchJob(
      sessionId: sessionId,
      captureName: marker?.name ?? 'Mobile 360°',
      calibrationId: store.calibrationOf(sessionId) ?? '',
    );
  }

  CaptureMarker? _markerFor(String sessionId, SphereCaptureStore store) {
    for (final CaptureMarker marker in store.all) {
      if (marker.sphereSessionId == sessionId) return marker;
    }
    return null;
  }

  /// Applies [change] to the marker for [sessionId], persists it, and brings
  /// the plan up to date. Returns the updated marker, or null when the capture
  /// has since been discarded.
  Future<CaptureMarker?> _updateMarker(
    String sessionId,
    CaptureMarker Function(CaptureMarker marker) change,
  ) async {
    final SphereCaptureStore store = ref.read(sphereCaptureStoreProvider);
    final CaptureMarker? existing = _markerFor(sessionId, store);
    if (existing == null) return null;

    final CaptureMarker updated = change(existing);
    final String? calibrationId = await store.update(updated);
    if (calibrationId == null) return null;
    // The write above is real file IO, and this controller can be torn down
    // during it — the demo console's delete does exactly that.
    if (_disposed) return updated;

    // Straight to the store rather than through the repository: the repository
    // would only forward to the same store, and this path runs from a stream
    // callback where the repository may have been rebuilt by the demo console
    // in between.
    ref.invalidate(workspaceDataProvider(calibrationId));
    return updated;
  }
}

final stitchJobsProvider =
    NotifierProvider<StitchJobsController, Map<String, StitchJob>>(
  StitchJobsController.new,
);

/// The jobs worth drawing a card for on this level.
///
/// Recovered entries carry no calibration id — nothing knew which level they
/// belonged to at the time — so they are shown everywhere rather than nowhere.
final activeStitchJobsProvider =
    Provider.family<List<StitchJob>, String>((ref, String calibrationId) {
  final Map<String, StitchJob> jobs = ref.watch(stitchJobsProvider);
  return <StitchJob>[
    for (final StitchJob job in jobs.values)
      if (job.calibrationId == calibrationId || job.calibrationId.isEmpty) job,
  ];
});
