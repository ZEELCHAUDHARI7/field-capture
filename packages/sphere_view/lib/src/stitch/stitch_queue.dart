import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/models/capture_bundle.dart';
import '../api/models/json_codec.dart';
import '../api/models/sphere_capture_config.dart';
import '../api/models/stitch_progress.dart';
import '../api/models/stitch_result.dart';
import '../api/sphere_stitcher.dart';
import '../camera/camera_platform.dart';
import '../camera/pigeon_camera_platform.dart';
import '../camera/thermal_policy.dart';

/// Where one queued bundle has got to.
enum StitchQueueStatus {
  /// Waiting its turn.
  pending,

  /// Being stitched right now. Persisted, so that finding one of these at
  /// startup is how the queue knows the app was killed mid-stitch.
  running,

  /// Finished; [StitchQueueEntry.outputPath] is the panorama.
  done,

  /// Gave up. [StitchQueueEntry.lastError] says why.
  failed,
}

/// One bundle's place in the queue, as persisted to disk.
class StitchQueueEntry {
  /// Creates an entry.
  StitchQueueEntry({
    required this.sessionId,
    required this.bundleDirectory,
    required this.outputPath,
    required this.enqueuedAtMs,
    this.status = StitchQueueStatus.pending,
    this.attempts = 0,
    this.interruptions = 0,
    this.lastError,
  });

  /// The bundle's session id, and the queue's key: enqueuing the same session
  /// twice is a no-op rather than a second stitch of the same station.
  final String sessionId;

  /// Absolute path to the bundle directory. Absolute here — unlike the shot
  /// paths *inside* a bundle, which are relative so the bundle stays
  /// replayable when copied — because this is a note about where a thing is on
  /// this device, not part of the portable record.
  final String bundleDirectory;

  /// Where the panorama goes.
  final String outputPath;

  /// When it joined the queue, for FIFO ordering across restarts.
  final int enqueuedAtMs;

  /// Where the fast first pass is written.
  ///
  /// Derived from [outputPath] rather than stored, so an entry persisted before
  /// previews existed still answers it and no migration is needed.
  String get previewOutputPath => previewPathFor(outputPath);

  /// The preview companion of a panorama path.
  ///
  /// Public and static because a host app has to know it too — to display the
  /// preview, and to delete it when the station is cleared. A second copy of
  /// this rule in the app is a second thing that can drift, and the symptom of
  /// drift is an orphaned file or a `PathNotFoundException`.
  static String previewPathFor(String outputPath) {
    final dot = outputPath.lastIndexOf('.');
    final slash = outputPath.lastIndexOf(Platform.pathSeparator);
    return dot > slash
        ? '${outputPath.substring(0, dot)}-preview${outputPath.substring(dot)}'
        : '$outputPath-preview';
  }

  /// Where it has got to.
  StitchQueueStatus status;

  /// How many times a stitch has been *started* for it.
  int attempts;

  /// How many of those were cut short by the app being killed.
  ///
  /// Counted separately from [attempts] because they mean different things: a
  /// stitch that failed twice on its own is a bundle with a problem, while one
  /// interrupted twice is a device that keeps getting backgrounded, and only
  /// the first is worth giving up on.
  int interruptions;

  /// Why it failed, when it did.
  String? lastError;

  /// Serialises for the on-disk queue.
  Map<String, Object?> toJson() => {
    'session_id': sessionId,
    'bundle_directory': bundleDirectory,
    'output_path': outputPath,
    'enqueued_at_ms': enqueuedAtMs,
    'status': status.name,
    'attempts': attempts,
    'interruptions': interruptions,
    'last_error': lastError,
  };

  /// Inverse of [toJson].
  factory StitchQueueEntry.fromJson(Map<String, Object?> json) {
    const ctx = 'StitchQueueEntry';
    return StitchQueueEntry(
      sessionId: jsonString(json, 'session_id', context: ctx),
      bundleDirectory: jsonString(json, 'bundle_directory', context: ctx),
      outputPath: jsonString(json, 'output_path', context: ctx),
      enqueuedAtMs: jsonInt(json, 'enqueued_at_ms', context: ctx),
      status: jsonEnum(json, 'status', StitchQueueStatus.values, context: ctx),
      attempts: jsonInt(json, 'attempts', context: ctx),
      interruptions: json.containsKey('interruptions')
          ? jsonInt(json, 'interruptions', context: ctx)
          : 0,
      lastError: json['last_error'] == null
          ? null
          : jsonString(json, 'last_error', context: ctx),
    );
  }

  @override
  String toString() => 'StitchQueueEntry($sessionId, ${status.name})';
}

/// Something the queue did, for a UI to show.
class StitchQueueEvent {
  /// Creates an event.
  const StitchQueueEvent({
    this.preview = false,
    required this.entry,
    this.progress,
    this.result,
    this.error,
    this.paused = false,
    this.pauseReason,
  });

  /// The entry it happened to.
  final StitchQueueEntry entry;

  /// Progress, on a tick.
  final StitchProgress? progress;

  /// The panorama, on completion.
  final StitchResult? result;

  /// The failure, when there was one.
  final Object? error;

  /// Whether the queue is holding off rather than working.
  final bool paused;

  /// Whether [result] is the fast low-resolution pass rather than the final one.
  ///
  /// A preview is a real, complete, viewable panorama — just smaller. A UI
  /// should show it immediately and then replace it when the non-preview result
  /// for the same entry arrives. Ignoring this flag entirely is safe: it just
  /// means the operator waits for the full-resolution pass, which is the old
  /// behaviour.
  final bool preview;

  /// Plain-language reason for the hold — the thermal message, usually.
  final String? pauseReason;

  @override
  String toString() =>
      'StitchQueueEvent(${entry.sessionId}, ${entry.status.name}'
      '${paused ? ', paused' : ''})';
}

/// A persistent, serial, thermally-aware queue of bundles waiting to stitch.
///
/// **This is the default path, not an optimisation.** The user is standing on a
/// site with more stations to walk to; blocking them behind 60 s of stitching
/// per station across 30 stations is half an hour of standing still, which is
/// the wrong product behaviour whatever the panorama looks like at the end of
/// it (Phase 10 §5). So `finish()` hands back a bundle immediately, the bundle
/// goes here, and it stitches when convenient. The manager keeps walking.
///
/// Four properties, each for a specific reason:
///
/// * **Persistent.** The queue survives app restarts, which costs almost
///   nothing because a `CaptureBundle` is already a self-describing directory
///   (Phase 01 §3.4) — the queue file holds paths, not data.
/// * **Serial.** Two concurrent stitches will run the device out of memory. The
///   tier table (architecture §6.5) sizes *one* stitch against the device.
/// * **Skipped when hot.** At `serious` the queue waits; see
///   [ThermalPolicy.forBackgroundStitch] for why that is stricter than the rule
///   for a stitch the user asked for.
/// * **Resumable at bundle granularity, not stage granularity.** A stitch
///   killed halfway restarts from the beginning. That is deliberate: a restart
///   costs 60 s, and checkpointing inside the native pipeline — serialising
///   warped frames, seam masks and blender pyramids to disk between stages —
///   would be a large amount of fragile code to save less than a minute.
///
/// What is *not* handled here: platform background-execution limits are real —
/// iOS gives a few minutes, Android needs a foreground service for reliable
/// long work — and this class does not acquire either. It is written so that
/// being killed at any moment is safe, which is the property that makes a host
/// app's foreground service optional rather than load-bearing.
class StitchQueue {
  /// Creates a queue whose state file lives in [directory].
  StitchQueue({
    required this.directory,
    SphereCameraPlatform? platform,
    SphereStitcher Function({QualityTier? tier})? stitcherFactory,
    this.previewTier = QualityTier.low,
    this.maxAttempts = 3,
  }) : _platform = platform,
       _stitcherFactory =
           stitcherFactory ?? (({QualityTier? tier}) => SphereStitcher(tier: tier));

  /// The queue file's name inside [directory].
  static const String stateFileName = 'stitch_queue.json';

  /// Version of the queue file's layout.
  static const int schemaVersion = 1;

  /// How often a queue paused on temperature looks again.
  ///
  /// Thirty seconds because a tablet cooling from `serious` is minutes of
  /// physics, not milliseconds, and because nobody is waiting — the whole point
  /// of the queue is that this work happens when it is convenient.
  static const Duration thermalRecheckInterval = Duration(seconds: 30);

  /// Where the queue file lives.
  final Directory directory;

  /// How many starts an entry gets before it is marked failed.
  ///
  /// Counts real failures only; a run cut short by the app being killed does
  /// not consume one, or a device that backgrounds aggressively would exhaust
  /// every bundle's budget without ever having actually tried.
  final int maxAttempts;

  final SphereCameraPlatform? _platform;
  final SphereStitcher Function({QualityTier? tier}) _stitcherFactory;

  /// Resolution for the fast first pass, or `null` to do only the full one.
  ///
  /// Every capture is stitched twice: once small, so the operator can look at it
  /// within seconds of the last shutter, then once at the device's real tier,
  /// which replaces it. This is what closes the gap the user actually feels —
  /// 135 s at 8192x4096 does not become fast by tuning, and on a site walk the
  /// manager is already walking to the next station while it finishes.
  ///
  /// The preview goes to a separate file, so a failure in the full pass leaves a
  /// viewable panorama rather than nothing.
  final QualityTier? previewTier;

  final List<StitchQueueEntry> _entries = [];
  final _events = StreamController<StitchQueueEvent>.broadcast();

  SphereCameraPlatform? _resolvedPlatform;
  StreamSubscription<ThermalState>? _thermalSubscription;
  Completer<void>? _cooled;
  SphereStitcher? _current;
  Future<void>? _draining;
  bool _stopped = false;

  /// Everything the queue knows about, in the order it will be worked.
  List<StitchQueueEntry> get entries => List.unmodifiable(_entries);

  /// Entries still to do.
  List<StitchQueueEntry> get pending => [
    for (final e in _entries)
      if (e.status == StitchQueueStatus.pending ||
          e.status == StitchQueueStatus.running)
        e,
  ];

  /// Progress, completions, failures and thermal pauses.
  Stream<StitchQueueEvent> get events => _events.stream;

  /// Whether a stitch is running right now.
  bool get isBusy => _current != null;

  /// The queue file.
  File get stateFile =>
      File('${directory.path}${Platform.pathSeparator}$stateFileName');

  /// Reads the queue off disk and repairs anything a kill left behind.
  ///
  /// The repair is the whole reason `running` is a persisted state. An entry
  /// found in that state at startup did not finish, and nothing else can tell
  /// us so: the process that would have written `done` or `failed` no longer
  /// exists. It goes back to `pending` and is counted as an interruption rather
  /// than an attempt — see [StitchQueueEntry.interruptions].
  Future<void> load() async {
    _entries.clear();
    if (!await stateFile.exists()) return;

    final decoded = jsonDecode(await stateFile.readAsString());
    if (decoded is! Map) {
      throw const SphereJsonFormatException(
        'StitchQueue.load',
        'the queue file does not contain a JSON object',
      );
    }
    final json = decoded.cast<String, Object?>();
    final version = jsonInt(json, 'schema_version', context: 'StitchQueue');
    if (version != schemaVersion) {
      throw SphereJsonFormatException(
        'StitchQueue.schema_version',
        'the queue was written by schema version $version, this build reads '
            '$schemaVersion',
      );
    }

    var repaired = false;
    for (final raw in jsonList(json, 'entries', (e) => e, context: 'StitchQueue')) {
      if (raw is! Map) continue;
      final entry = StitchQueueEntry.fromJson(raw.cast<String, Object?>());
      if (entry.status == StitchQueueStatus.running) {
        entry.status = StitchQueueStatus.pending;
        entry.interruptions += 1;
        repaired = true;
      }
      _entries.add(entry);
    }
    _entries.sort((a, b) => a.enqueuedAtMs.compareTo(b.enqueuedAtMs));
    if (repaired) await _save();
  }

  /// Adds [bundle] to the queue and returns its entry.
  ///
  /// Idempotent by session id: a bundle already queued is not queued twice, so
  /// a host app can call this from a place that may run more than once — a
  /// retry, a rebuilt widget — without producing two stitches of one station.
  Future<StitchQueueEntry> enqueue(
    CaptureBundle bundle, {
    String? outputPath,
  }) async {
    final existing = _entries.where((e) => e.sessionId == bundle.sessionId);
    if (existing.isNotEmpty) return existing.first;

    final entry = StitchQueueEntry(
      sessionId: bundle.sessionId,
      bundleDirectory: bundle.directory.absolute.path,
      outputPath:
          outputPath ??
          '${bundle.directory.absolute.path}/'
              '${SphereStitcher.defaultOutputFileName}',
      enqueuedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _entries.add(entry);
    await _save();
    return entry;
  }

  /// Puts a failed entry back in the queue with a fresh attempt budget.
  ///
  /// Explicit rather than automatic, and the two halves of that are both
  /// deliberate. [maxAttempts] exists because a bundle that has failed three
  /// times will usually fail a fourth, and a queue that retries forever is a
  /// tablet that gets hot in somebody's bag. But the storage policy in
  /// `docs/INTEGRATION.md` keeps precisely these bundles — the ones that did
  /// *not* come out — so re-stitching one is a normal thing to want: after the
  /// device has cooled, after the user has closed whatever was competing for
  /// memory, or after a pipeline improvement, none of which the queue can
  /// detect for itself.
  ///
  /// Returns `false` when there is no failed entry for [sessionId], so a UI can
  /// tell "retried" from "nothing to retry" without inspecting [entries].
  Future<bool> retry(String sessionId) async {
    for (final entry in _entries) {
      if (entry.sessionId != sessionId) continue;
      if (entry.status != StitchQueueStatus.failed) return false;
      entry
        ..status = StitchQueueStatus.pending
        ..attempts = 0
        ..lastError = null;
      await _save();
      _events.add(StitchQueueEvent(entry: entry));
      return true;
    }
    return false;
  }

  /// Starts working the queue, and keeps working it as bundles arrive.
  ///
  /// Returns as soon as the drain is under way — it does not wait for the
  /// queue to empty, which would defeat the point. Await [drained] for that.
  Future<void> start() async {
    _stopped = false;
    await _watchThermalState();
    _draining ??= _drain().whenComplete(() => _draining = null);
  }

  /// Completes when the queue has nothing left to do.
  Future<void> get drained => _draining ?? Future<void>.value();

  /// Stops after the current bundle, and cancels that bundle's stitch.
  ///
  /// Cancelling rather than waiting is right because the work is resumable: the
  /// entry goes back to `pending` and starts again next time, costing one
  /// stitch, against holding the app open for up to a minute at a moment the
  /// caller has said it wants to stop.
  Future<void> stop() async {
    _stopped = true;
    _current?.cancel();
    // Released so a drain waiting out a hot device wakes up and sees `_stopped`
    // rather than holding `stop()` open until the tablet cools. Guarded because
    // the thermal listener may have completed it already, and completing twice
    // throws — from inside a shutdown path, where it would be swallowed.
    final waiting = _cooled;
    _cooled = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
    await _draining;
    await _thermalSubscription?.cancel();
    _thermalSubscription = null;
  }

  /// Releases the event stream. The queue file stays; that is the point of it.
  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  Future<void> _drain() async {
    while (!_stopped) {
      final entry = _nextPending();
      if (entry == null) return;

      final hold = await _thermalHold(entry);
      if (hold) continue;
      if (_stopped) return;

      await _runEntry(entry);
    }
  }

  StitchQueueEntry? _nextPending() {
    for (final entry in _entries) {
      if (entry.status == StitchQueueStatus.pending) return entry;
    }
    return null;
  }

  /// Waits out a hot device. Returns true when it waited and the caller should
  /// re-check the queue from the top.
  Future<bool> _thermalHold(StitchQueueEntry entry) async {
    final platform = _platformOrNull();
    if (platform == null) return false;

    ThermalState state;
    try {
      state = await platform.thermalState();
    } catch (_) {
      // A thermal probe that fails must not stall the queue forever. Not
      // knowing the temperature is not evidence that the device is hot.
      return false;
    }
    final decision = ThermalPolicy.forBackgroundStitch(state);
    if (decision.allowed) return false;

    _events.add(
      StitchQueueEvent(entry: entry, paused: true, pauseReason: decision.message),
    );
    final cooled = _cooled ??= Completer<void>();
    // Woken either by a thermal transition or by the timeout, whichever comes
    // first, and then the loop re-checks from the top. The timeout is what
    // makes the *stream* an optimisation rather than a requirement: the queue's
    // own platform does not register for callbacks (see `_platformOrNull`), so
    // on a device where nobody else is listening there are no transitions to
    // hear and polling is the only thing that would ever start the work again.
    await cooled.future.timeout(thermalRecheckInterval, onTimeout: () {});
    return true;
  }

  /// The tier the capture forced, or `null` to let the stitch probe.
  ///
  /// Read out of `device_info['config']` rather than from a typed field because
  /// that is where the session records the configuration it ran under, and the
  /// bundle is the only thing that survives to stitch time — the queue may be
  /// running an entry a crash left behind, hours and one app launch later.
  ///
  /// Unreadable or absent means `null`, which is the default behaviour anyway: a
  /// malformed manifest should cost the probe, not the stitch.
  static QualityTier? _forcedTierOf(CaptureBundle bundle) {
    final config = bundle.deviceInfo['config'];
    if (config is! Map) return null;
    final name = config['quality_tier'];
    if (name is! String) return null;
    for (final tier in QualityTier.values) {
      if (tier.name == name) return tier;
    }
    return null;
  }

  Future<void> _runEntry(StitchQueueEntry entry) async {
    final bundleDirectory = Directory(entry.bundleDirectory);
    if (!await bundleDirectory.exists()) {
      entry
        ..status = StitchQueueStatus.failed
        ..lastError =
            'the capture folder is gone: ${entry.bundleDirectory}. It was '
                'probably deleted or moved after the capture finished.';
      await _save();
      _events.add(StitchQueueEvent(entry: entry, error: entry.lastError));
      return;
    }

    entry
      ..status = StitchQueueStatus.running
      ..attempts += 1;
    // Written *before* the work starts, not after. That ordering is what makes
    // the crash-recovery in `load` possible: if the app dies during the stitch,
    // the file already says this bundle was in flight.
    await _save();

    try {
      final bundle = await CaptureBundle.load(bundleDirectory);

      // Pass 1: small and quick, so there is something to look at now.
      //
      // Wrapped in its own try because a preview is a convenience, not the
      // deliverable. If it fails — out of memory, a bad frame — the full pass
      // still gets its chance, and the operator is no worse off than before this
      // existed. Swallowing the error here is the point, not an oversight; the
      // full pass reports for both.
      if (previewTier != null) {
        final previewStitcher = _stitcherFactory(tier: previewTier);
        _current = previewStitcher;
        try {
          final preview = await previewStitcher.stitch(
            bundle,
            outputPath: entry.previewOutputPath,
            onProgress: (p) => _events.add(
              StitchQueueEvent(entry: entry, progress: p, preview: true),
            ),
          );
          _events.add(
            StitchQueueEvent(entry: entry, result: preview, preview: true),
          );
        } on StitchCancelledException {
          rethrow;
        } catch (_) {
          // Deliberately silent: see above.
        }
      }

      // Honour a tier the capture deliberately forced, and only that.
      //
      // `SphereCaptureConfig.qualityTier` documents itself as "forces an output
      // tier; null probes total RAM instead", and until now nothing read it — the
      // field was written into the manifest, serialised, compared and printed, and
      // the stitch re-probed regardless. So a caller who forced `low` on a tablet
      // that runs hot got `high` anyway, which is the opposite of what forcing a
      // tier is for.
      //
      // `null` still means probe, and that remains the default and the better
      // answer: it measures memory available *now*, at stitch time, rather than
      // total RAM at the entry point minutes earlier.
      final stitcher = _stitcherFactory(tier: _forcedTierOf(bundle));
      _current = stitcher;
      final result = await stitcher.stitch(
        bundle,
        outputPath: entry.outputPath,
        onProgress: (p) => _events.add(
          StitchQueueEvent(entry: entry, progress: p),
        ),
      );
      entry
        ..status = StitchQueueStatus.done
        ..lastError = null;
      await _save();
      _events.add(StitchQueueEvent(entry: entry, result: result));
    } on StitchCancelledException {
      // A cancel is `stop()`, not a failure. Back to pending, and the attempt
      // it consumed is given back — otherwise stopping the queue three times
      // would fail a bundle that has never actually been tried.
      entry
        ..status = StitchQueueStatus.pending
        ..attempts -= 1
        ..interruptions += 1;
      await _save();
    } catch (error) {
      entry.lastError = '$error';
      entry.status = entry.attempts >= maxAttempts
          ? StitchQueueStatus.failed
          : StitchQueueStatus.pending;
      await _save();
      _events.add(StitchQueueEvent(entry: entry, error: error));
      if (entry.status == StitchQueueStatus.pending) {
        // A failed bundle that is going to be retried must not be retried
        // immediately in a tight loop — the most likely causes (out of memory,
        // out of disk) need time, not another go a millisecond later.
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } finally {
      _current = null;
    }
  }

  Future<void> _watchThermalState() async {
    if (_thermalSubscription != null) return;
    final platform = _platformOrNull();
    if (platform == null) return;
    _thermalSubscription = platform.thermalStates.listen((state) {
      if (!ThermalPolicy.forBackgroundStitch(state).allowed) return;
      // Cooled off. Release whatever is waiting; the drain loop re-checks the
      // temperature itself, so a spurious wake costs one probe.
      final waiting = _cooled;
      _cooled = null;
      if (waiting != null && !waiting.isCompleted) waiting.complete();
    });
  }

  SphereCameraPlatform? _platformOrNull() {
    if (_platform != null) return _platform;
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    // `receiveCallbacks: false` is not an optimisation. Registering the
    // Flutter-API handler is process-wide and last-writer-wins, so a queue that
    // registered would take frame timestamps, thermal transitions and
    // interruption notices away from a live capture session — and the manager
    // who caused it would have queued one station and carried on capturing,
    // which is the normal case rather than an unusual one. The queue only ever
    // *asks*; it never needs to be told.
    return _resolvedPlatform ??= PigeonCameraPlatform(receiveCallbacks: false);
  }

  /// Serialises writes of the queue file.
  ///
  /// The same guard `SphereCaptureSession` puts around `CaptureBundle.save`,
  /// and it is here for the same reason: temp-file-plus-rename is only atomic
  /// while there is **one** writer. Two overlapping saves both write the same
  /// `.tmp` path, the first rename moves it, and the second fails with a
  /// path-not-found on a file it had just written.
  ///
  /// It is reachable in ordinary use, not only in tests: `retry` saves from the
  /// caller's thread of control while the drain loop is saving a status
  /// transition, and `enqueue` does the same when a bundle arrives during a
  /// stitch — which is the *normal* case on a site walk, since the whole point
  /// of the queue is that captures keep coming while it works. Chaining costs
  /// nothing at this rate and removes the race rather than narrowing it.
  /// Nullable, and seeded on first use rather than at construction.
  ///
  /// A `Future.value()` field initialiser would be tidier and is a trap. It is
  /// created in whatever zone the constructor ran in, and `flutter_test` runs a
  /// `testWidgets` body under a **fake** async zone whose microtasks only
  /// advance when the test pumps. A queue constructed in the test body and then
  /// used inside `WidgetTester.runAsync` — which is the only way to await real
  /// file I/O, so it is what any consuming app's widget test will do — would
  /// chain every save onto a future that is never completed, and the symptom is
  /// not an error but a test that hangs until the suite times out. Found
  /// exactly that way.
  Future<void>? _saveChain;

  Future<void> _save() {
    final previous = _saveChain;
    final next = previous == null
        ? _writeStateFile()
        : previous.then((_) => _writeStateFile());
    // The chain has to survive a failed write, or one I/O error would wedge
    // every later save — including the `running` marker that makes a kill
    // recoverable. The caller still sees the failure; the chain does not.
    _saveChain = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// Writes the queue file via a temporary and a rename.
  ///
  /// The same discipline `CaptureBundle.save` uses, for the same reason: a
  /// crash — or a battery pull — during the write must leave the previous queue
  /// intact rather than a truncated one. A half-written queue file is worse
  /// than no queue file, because it loses bundles silently instead of loudly.
  Future<void> _writeStateFile() async {
    await directory.create(recursive: true);
    // A *unique* temporary, not a fixed `.tmp`.
    //
    // Two queues can legitimately be writing the same directory at once: a
    // killed store whose `_runEntry` is still unwinding while a reopened one
    // loads and saves — which is precisely the crash-recovery path
    // `StitchQueue.load` exists for, and what `widget_test.dart`'s "a stitch
    // killed mid-run is picked back up" reproduces. With one shared temp name
    // they both write it, the first rename moves it away, and the second fails
    // with `PathNotFoundException` on a file it had just written. The atomic
    // discipline was right; the fixed name quietly broke it.
    final temp = File(
      '${stateFile.path}.${identityHashCode(this)}.${_writeSequence++}.tmp',
    );
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema_version': schemaVersion,
        'entries': [for (final e in _entries) e.toJson()],
      }),
      flush: true,
    );
    await temp.rename(stateFile.path);
  }

  /// Distinguishes one instance's successive writes from each other.
  ///
  /// The instance identity in the path is what separates *two queues*; this
  /// separates one queue's overlapping writes, which `_save` can produce because
  /// nothing serialises it. Both parts are needed, and a bare counter is not
  /// enough on its own — two instances would each start at zero and collide on
  /// exactly the path this is meant to keep apart.
  int _writeSequence = 0;
}
