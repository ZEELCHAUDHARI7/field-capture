import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sphere_view/sphere_view.dart';

/// Where one station has got to, as the list row needs to say it.
///
/// Derived, never stored. The queue already persists the authoritative state
/// (`pending` / `running` / `done` / `failed`) and the bundle on disk already
/// says how much of the sphere was shot; a second copy of either would be a
/// second thing that can be wrong.
enum StationPhase {
  /// The capture never reached `finish()` — the app was killed part-way
  /// through it. Resumable: [SphereCaptureSession.resume] picks the bundle up
  /// at the first uncaptured target.
  interrupted,

  /// Nothing is on disk to resume from: the app died before the first position
  /// was written.
  empty,

  /// In the queue, waiting its turn.
  queued,

  /// Being stitched right now.
  stitching,

  /// Stitched. [Station.result] is the panorama and its report.
  ready,

  /// The queue gave up on it.
  failed,
}

/// One station of the demo's site walk.
///
/// The fields here are exactly what `docs/INTEGRATION.md` tells a consuming app
/// to persist, which is the point of writing the demo this way round: the store
/// below is a working example of that list rather than a paraphrase of it.
class Station {
  /// Creates a station row.
  Station({
    required this.sessionId,
    required this.label,
    required this.startedAt,
    required this.bundleDirectory,
    required this.outputPath,
    this.enqueued = false,
    this.bundleDeleted = false,
  });

  /// The capture session's id, and the key everything else is looked up by —
  /// the queue entry, the panorama, the report.
  final String sessionId;

  /// What the row is called. "Station 1", and nothing more clever.
  final String label;

  /// When the capture started, for ordering.
  final DateTime startedAt;

  /// The `CaptureBundle` directory.
  final String bundleDirectory;

  /// Where the equirectangular JPEG goes.
  ///
  /// Deliberately **outside** [bundleDirectory]: the storage policy in
  /// `docs/INTEGRATION.md` deletes the bundle once a stitch has met its quality
  /// targets, and a panorama living inside the thing being deleted would make
  /// that policy impossible to follow.
  final String outputPath;

  /// Whether the capture finished and reached the queue.
  ///
  /// A row that is `false` here with a bundle on disk is a capture the app was
  /// killed in the middle of, which is flow 7.
  bool enqueued;

  /// Whether the storage policy has already removed the bundle.
  bool bundleDeleted;

  /// Where the report is kept once the stitch produces one.
  String get reportPath => '$outputPath.report.json';

  /// Serialises for the demo's own index file.
  Map<String, Object?> toJson() => {
    'session_id': sessionId,
    'label': label,
    'started_at': startedAt.toUtc().toIso8601String(),
    'bundle_directory': bundleDirectory,
    'output_path': outputPath,
    'enqueued': enqueued,
    'bundle_deleted': bundleDeleted,
  };

  /// Inverse of [toJson].
  factory Station.fromJson(Map<String, Object?> json) => Station(
    sessionId: json['session_id']! as String,
    label: json['label']! as String,
    startedAt: DateTime.parse(json['started_at']! as String),
    bundleDirectory: json['bundle_directory']! as String,
    outputPath: json['output_path']! as String,
    enqueued: json['enqueued'] as bool? ?? false,
    bundleDeleted: json['bundle_deleted'] as bool? ?? false,
  );
}

/// The demo's model: a list of stations, the stitch queue behind it, and the
/// live progress of whatever the queue is working on.
///
/// It is a `ChangeNotifier` rather than anything more elaborate because the
/// interesting behaviour is not in the state management. What matters is that
/// **the capture flow never waits for a stitch**: [record] enqueues and
/// returns, the queue drains on its own, and every row's status comes from
/// [StitchQueue.events]. Break that and two spheres back to back stop working,
/// which is the thing this demo exists to keep honest.
class StationStore extends ChangeNotifier {
  /// Creates a store over an existing [queue] and index directory.
  ///
  /// The parameters exist so a widget test can point the whole demo at a
  /// temporary directory; the app itself uses [StationStore.forApp].
  StationStore({
    required this.bundleRoot,
    required this.panoramaRoot,
    required this.indexFile,
    required this.queue,
  });

  /// Opens the store the app uses, on the real device directories.
  static Future<StationStore> forApp() async {
    final documents = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(documents.path, 'sphere_view'));
    return StationStore(
      bundleRoot: Directory(p.join(root.path, 'bundles')),
      panoramaRoot: Directory(p.join(root.path, 'panoramas')),
      indexFile: File(p.join(root.path, 'stations.json')),
      queue: StitchQueue(directory: Directory(p.join(support.path, 'sphere_view'))),
    );
  }

  /// Where `CaptureBundle` directories live.
  final Directory bundleRoot;

  /// Where finished panoramas and their reports live.
  final Directory panoramaRoot;

  /// The demo's own row index.
  final File indexFile;

  /// The package's persistent background stitch queue.
  final StitchQueue queue;

  final List<Station> _stations = [];
  final Map<String, StitchProgress> _progress = {};
  final Map<String, StitchResult> _results = {};

  /// Fast low-resolution passes, kept apart from [_results] on purpose.
  ///
  /// A preview must make a station *viewable* without making it *finished*. Held
  /// in the same map as the real results it would satisfy the `containsKey` in
  /// `phaseOf` and report `ready` — so a preview that succeeded followed by a
  /// full pass that failed would show a green row and swallow the failure
  /// entirely.
  final Map<String, StitchResult> _previews = {};
  final Map<String, int> _bundleCaptured = {};
  final Map<String, int> _bundlePlanned = {};
  final Map<String, String> _errors = {};

  StreamSubscription<StitchQueueEvent>? _events;
  String? _pauseReason;
  bool _disposed = false;

  /// The stations, newest first.
  List<Station> get stations => List.unmodifiable(_stations);

  /// Why the queue is holding off, when it is — the thermal message, usually.
  String? get pauseReason => _pauseReason;

  /// Reads the index, the queue and anything a previous run left behind.
  ///
  /// The order matters. The queue is loaded *first* so that an entry a kill
  /// left in `running` is repaired back to `pending` before any row asks what
  /// its status is — otherwise the first frame after a crash shows a station
  /// stuck mid-stitch that nothing is working on.
  Future<void> load() async {
    await bundleRoot.create(recursive: true);
    await panoramaRoot.create(recursive: true);

    await queue.load();

    _stations.clear();
    if (await indexFile.exists()) {
      final decoded = jsonDecode(await indexFile.readAsString());
      if (decoded is List) {
        for (final raw in decoded) {
          if (raw is Map) {
            _stations.add(Station.fromJson(raw.cast<String, Object?>()));
          }
        }
      }
    }
    _stations.sort((a, b) => b.startedAt.compareTo(a.startedAt));

    for (final station in _stations) {
      await _refreshFromDisk(station);
    }

    _events ??= queue.events.listen(_onQueueEvent);
    _notify();
  }

  /// Starts draining the queue.
  Future<void> start() => queue.start();

  /// Registers a station **before** its first shutter.
  ///
  /// This is what makes flow 7 demonstrable. If the row were only written after
  /// `finish()`, a capture the app was killed in the middle of would leave a
  /// bundle on disk that nothing in the UI knew about, and "resume after kill"
  /// would silently become "find the folder yourself".
  Future<Station> begin() async {
    final index = _stations.length + 1;
    final startedAt = DateTime.now();
    final sessionId =
        'station-$index-${startedAt.millisecondsSinceEpoch}';
    final station = Station(
      sessionId: sessionId,
      label: 'Station $index',
      startedAt: startedAt,
      bundleDirectory: p.join(bundleRoot.path, sessionId),
      outputPath: p.join(panoramaRoot.path, '$sessionId.jpg'),
    );
    _stations.insert(0, station);
    await _save();
    _notify();
    return station;
  }

  /// Hands a finished capture to the queue and returns immediately.
  ///
  /// The whole demo turns on this method not awaiting anything expensive. The
  /// user is back on the station list — able to press "Capture a 360°" again —
  /// while the first sphere is still being stitched.
  Future<void> record(Station station, CaptureBundle bundle) async {
    station.enqueued = true;
    _bundleCaptured[station.sessionId] = bundle.positions.length;
    _bundlePlanned[station.sessionId] = bundle.plan.length;
    await queue.enqueue(bundle, outputPath: station.outputPath);
    await _save();
    _notify();
    // Not awaited: `start()` returns once the drain is under way, but calling
    // it is still an async hop, and the caller is a `Navigator.pop` away from
    // the station list.
    unawaited(queue.start());
  }

  /// Puts a failed station back in the queue.
  ///
  /// The bundle is still on disk — the storage policy keeps exactly the
  /// captures that did not come out — so there is always something to retry.
  Future<void> retry(Station station) async {
    _errors.remove(station.sessionId);
    if (await queue.retry(station.sessionId)) {
      _notify();
      unawaited(queue.start());
    }
  }

  /// Drops a station the user never finished capturing.
  Future<void> discard(Station station) async {
    _stations.remove(station);
    _progress.remove(station.sessionId);
    _results.remove(station.sessionId);
    _errors.remove(station.sessionId);
    await _deleteQuietly(Directory(station.bundleDirectory));
    await _save();
    _notify();
  }

  /// Deletes every station, bundle and panorama.
  Future<void> clear() async {
    await queue.stop();
    for (final station in _stations) {
      await _deleteQuietly(Directory(station.bundleDirectory));
      await _deleteQuietly(File(station.outputPath));
      // The fast preview is a second file beside the panorama, so "Clear" has to
      // know about it or every cleared station leaves one behind.
      await _deleteQuietly(
        File(StitchQueueEntry.previewPathFor(station.outputPath)),
      );
      await _deleteQuietly(File(station.reportPath));
    }
    _stations.clear();
    _progress.clear();
    _results.clear();
    _previews.clear();
    _errors.clear();
    _bundleCaptured.clear();
    _bundlePlanned.clear();
    await _deleteQuietly(queue.stateFile);
    await queue.load();
    await _save();
    _notify();
    unawaited(queue.start());
  }

  /// Where [station] has got to.
  StationPhase phaseOf(Station station) {
    if (!station.enqueued) {
      return (_bundleCaptured[station.sessionId] ?? 0) > 0
          ? StationPhase.interrupted
          : StationPhase.empty;
    }
    // Deliberately not `_previews`: see its doc comment.
    if (_results.containsKey(station.sessionId)) return StationPhase.ready;
    final entry = entryFor(station);
    return switch (entry?.status) {
      StitchQueueStatus.done => StationPhase.ready,
      StitchQueueStatus.failed => StationPhase.failed,
      StitchQueueStatus.running => StationPhase.stitching,
      StitchQueueStatus.pending || null => StationPhase.queued,
    };
  }

  /// The queue's own entry for [station], when it has one.
  StitchQueueEntry? entryFor(Station station) {
    for (final entry in queue.entries) {
      if (entry.sessionId == station.sessionId) return entry;
    }
    return null;
  }

  /// The panorama and its measured quality, once there is one.
  StitchResult? resultFor(Station station) => _results[station.sessionId];

  /// A panorama for [station] that exists on disk *now*, or `null`.
  ///
  /// The full-resolution one once it is there, the fast preview before that.
  /// This is what a row should open: [Station.outputPath] is where the panorama
  /// will *end up*, which is not the same thing while the full pass is still
  /// running, and opening it then is a `PathNotFoundException`.
  String? viewablePathFor(Station station) =>
      _results[station.sessionId]?.equirectPath ??
      _previews[station.sessionId]?.equirectPath;

  /// Whether the only panorama available for [station] is the fast preview.
  ///
  /// Worth showing: it tells the operator the sphere they are looking at is not
  /// the final one yet, rather than leaving them to wonder why it sharpened.
  bool isPreviewOnly(Station station) =>
      !_results.containsKey(station.sessionId) &&
      _previews.containsKey(station.sessionId);

  /// The live stitch progress for [station], while it is running.
  StitchProgress? progressFor(Station station) => _progress[station.sessionId];

  /// Why [station] failed, when it did.
  String? errorFor(Station station) =>
      _errors[station.sessionId] ?? entryFor(station)?.lastError;

  /// Positions captured out of positions planned, for an interrupted row.
  (int captured, int planned) capturedOf(Station station) => (
    _bundleCaptured[station.sessionId] ?? 0,
    _bundlePlanned[station.sessionId] ?? 0,
  );

  @override
  void dispose() {
    _disposed = true;
    unawaited(_events?.cancel());
    unawaited(queue.dispose());
    super.dispose();
  }

  /// Notifies unless the store has been disposed.
  ///
  /// Not defensive tidiness: a stitch takes a minute and finishes on its own
  /// schedule, so "the screen went away while the queue was working" is the
  /// normal case rather than an edge one — closing the app on the last station
  /// of a walk hits it every time. Without the guard that lands as a framework
  /// assertion from a stack trace with no UI in it.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onQueueEvent(StitchQueueEvent event) {
    final id = event.entry.sessionId;
    _pauseReason = event.paused ? event.pauseReason : null;

    if (event.progress != null) {
      _progress[id] = event.progress!;
    }
    if (event.error != null) {
      _errors[id] = '${event.error}';
      _progress.remove(id);
    }
    final result = event.result;
    if (result != null) {
      _progress.remove(id);
      _errors.remove(id);
      if (event.preview) {
        _previews[id] = result;
      } else {
        _results[id] = result;
      }
      // A preview is shown and nothing more.
      //
      // `_onStitched` applies the storage policy, and the storage policy deletes
      // the bundle when the panorama met its quality targets. Run on a preview
      // that would delete the very bundle the full-resolution pass is about to
      // read — a fast preview that destroys the real stitch. The report is not
      // written either: it would be overwritten seconds later by the full pass,
      // and a report quoting a 4096-wide preview as the deliverable is wrong.
      if (!event.preview) unawaited(_onStitched(id, result));
    }
    _notify();
  }

  /// Persists the report and applies the storage policy.
  ///
  /// `docs/INTEGRATION.md`: delete the `CaptureBundle` on a stitch that meets
  /// its quality targets, **keep it when it does not**. A bundle is the only
  /// thing that can be re-stitched after a pipeline improvement, and the
  /// captures worth re-stitching are exactly the ones that came out badly —
  /// throwing those away is what forces somebody to drive back to the site.
  Future<void> _onStitched(String sessionId, StitchResult result) async {
    final station = _stations.where((s) => s.sessionId == sessionId).firstOrNull;
    if (station == null) return;
    try {
      await File(station.reportPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(result.toJson()),
        flush: true,
      );
    } on Object {
      // A report that could not be written is worth nothing to shout about in a
      // demo: the panorama is on disk either way and the report is still in
      // memory for this run.
    }
    if (result.report.meetsQualityTargets) {
      await _deleteQuietly(Directory(station.bundleDirectory));
      station.bundleDeleted = true;
      await _save();
      _notify();
    }
  }

  Future<void> _refreshFromDisk(Station station) async {
    final report = File(station.reportPath);
    if (await report.exists()) {
      try {
        final decoded = jsonDecode(await report.readAsString());
        if (decoded is Map) {
          _results[station.sessionId] =
              StitchResult.fromJson(decoded.cast<String, Object?>());
        }
      } on Object {
        // A corrupt report file must not stop the list from loading; the row
        // falls back to whatever the queue says.
      }
    }

    final manifest = File(p.join(station.bundleDirectory, 'bundle.json'));
    if (await manifest.exists()) {
      try {
        final bundle = await CaptureBundle.load(Directory(station.bundleDirectory));
        _bundleCaptured[station.sessionId] = bundle.positions.length;
        _bundlePlanned[station.sessionId] = bundle.plan.length;
      } on Object {
        _bundleCaptured[station.sessionId] = 0;
      }
    }
  }

  /// Distinguishes overlapping writes of the index. See [_save].
  int _writeSequence = 0;

  Future<void> _save() async {
    await indexFile.parent.create(recursive: true);
    // A *unique* temporary, not a fixed `.tmp`.
    //
    // `_save` is called from several places that can overlap — `begin`, `record`,
    // and the queue's event stream — and nothing serialises them. With one shared
    // temp name they both write it, the first rename moves it away, and the second
    // fails with `PathNotFoundException` on a file it had just written itself. That
    // is what killed the first capture on iOS, from `begin()`. The same bug was in
    // the package's own `StitchQueue._writeStateFile`.
    final temp = File('${indexFile.path}.${_writeSequence++}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert([for (final s in _stations) s.toJson()]),
      flush: true,
    );
    await temp.rename(indexFile.path);
  }

  Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } on Object {
      // Best effort. A file that will not delete is not a reason to fail the
      // action the user asked for.
    }
  }
}
