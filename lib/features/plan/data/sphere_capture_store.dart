import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/plan_marker.dart';
import '../models/plan_space.dart';

/// The real sphere captures, on disk.
///
/// The rest of the plan is still mock and still in memory (ASSUMPTIONS.md §B8),
/// and that stays true — but these markers point at panoramas that are real
/// files. Losing the marker on restart would leave a few hundred megabytes of
/// JPEG on the tablet with nothing referring to it, which is worse than either
/// keeping it or not taking it.
///
/// One JSON file rather than a schema engine: this is a list of markers, and
/// `drift` or `isar` would be a build step and a migration story for something
/// `jsonEncode` does in four lines. When the Asite bundle format lands and the
/// plan itself persists, this is absorbed by whatever does that.
///
/// Writes go through a temporary file and a rename, so a kill mid-write leaves
/// the previous list rather than half of the new one.
class SphereCaptureStore {
  SphereCaptureStore(this.file);

  final File file;

  static const int schemaVersion = 1;

  /// Markers by calibration id, in the order they were captured.
  final Map<String, List<CaptureMarker>> _byCalibration =
      <String, List<CaptureMarker>>{};

  bool _loaded = false;

  List<CaptureMarker> forCalibration(String calibrationId) =>
      List<CaptureMarker>.unmodifiable(
        _byCalibration[calibrationId] ?? const <CaptureMarker>[],
      );

  /// Every marker, across calibrations. Used to resolve a session id coming
  /// back off the stitch queue, which does not know which level it belongs to.
  Iterable<CaptureMarker> get all =>
      _byCalibration.values.expand((List<CaptureMarker> m) => m);

  /// Which level a sphere session was captured on, or null if it is not here.
  ///
  /// The stitch queue persists session ids and nothing else, so this is the
  /// only way back to a level for a capture recovered after the app was killed
  /// — and its upload has to be attributed to one.
  String? calibrationOf(String sessionId) {
    for (final MapEntry<String, List<CaptureMarker>> entry
        in _byCalibration.entries) {
      for (final CaptureMarker marker in entry.value) {
        if (marker.sphereSessionId == sessionId) return entry.key;
      }
    }
    return null;
  }

  /// Reads the file. Safe to call more than once; only the first does work.
  ///
  /// A file that cannot be parsed is treated as absent rather than fatal. The
  /// alternative is an app that will not open its own plan because one marker
  /// was written by a build that has since changed shape, and the panoramas are
  /// still on disk either way.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (!await file.exists()) return;

    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return;
      if (decoded['schema_version'] != schemaVersion) return;

      final Object? entries = decoded['captures'];
      if (entries is! List) return;

      for (final Object? raw in entries) {
        if (raw is! Map) continue;
        final Map<String, Object?> json = raw.cast<String, Object?>();
        final String? calibrationId = json['calibration_id'] as String?;
        if (calibrationId == null) continue;
        _byCalibration
            .putIfAbsent(calibrationId, () => <CaptureMarker>[])
            .add(_markerFromJson(json));
      }
    } on Object {
      _byCalibration.clear();
    }
  }

  Future<void> save(String calibrationId, CaptureMarker marker) async {
    await load();
    final List<CaptureMarker> list =
        _byCalibration.putIfAbsent(calibrationId, () => <CaptureMarker>[]);
    final int existing = list.indexWhere((CaptureMarker m) => m.id == marker.id);
    if (existing >= 0) {
      list[existing] = marker;
    } else {
      list.add(marker);
    }
    await _flush();
  }

  /// Replaces a marker wherever it is, by id. Returns the calibration it was
  /// found in, or null if it is not there — which happens legitimately when a
  /// stitch finishes for a capture the user has since discarded.
  Future<String?> update(CaptureMarker marker) async {
    await load();
    for (final MapEntry<String, List<CaptureMarker>> entry
        in _byCalibration.entries) {
      final int index =
          entry.value.indexWhere((CaptureMarker m) => m.id == marker.id);
      if (index >= 0) {
        entry.value[index] = marker;
        await _flush();
        return entry.key;
      }
    }
    return null;
  }

  Future<void> remove(String markerId) async {
    await load();
    for (final List<CaptureMarker> list in _byCalibration.values) {
      list.removeWhere((CaptureMarker m) => m.id == markerId);
    }
    await _flush();
  }

  /// Drops everything. The demo console's reset calls this — a reset that left
  /// the real captures behind would stop being a reset.
  Future<void> clear() async {
    _byCalibration.clear();
    _loaded = true;
    if (await file.exists()) await file.delete();
  }

  Future<void> _flush() async {
    final File temp = File('${file.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schema_version': schemaVersion,
        'captures': <Map<String, Object?>>[
          for (final MapEntry<String, List<CaptureMarker>> entry
              in _byCalibration.entries)
            for (final CaptureMarker marker in entry.value)
              _markerToJson(entry.key, marker),
        ],
      }),
    );
    await temp.rename(file.path);
  }

  static Map<String, Object?> _markerToJson(
    String calibrationId,
    CaptureMarker marker,
  ) {
    return <String, Object?>{
      'calibration_id': calibrationId,
      'id': marker.id,
      'name': marker.name,
      'mode': marker.mode.name,
      'x': marker.at.x,
      'y': marker.at.y,
      'recorded_at': marker.recordedAt.toIso8601String(),
      'sphere_session_id': marker.sphereSessionId,
      'panorama_path': marker.panoramaPath,
      'preview_path': marker.previewPath,
      'stitch': marker.stitch.name,
      'report_json': marker.reportJson,
      'stitch_error': marker.stitchError,
    };
  }

  static CaptureMarker _markerFromJson(Map<String, Object?> json) {
    return CaptureMarker(
      id: json['id']! as String,
      at: PlanPoint(
        (json['x']! as num).toDouble(),
        (json['y']! as num).toDouble(),
      ),
      recordedAt: DateTime.parse(json['recorded_at']! as String),
      name: json['name']! as String,
      mode: CaptureMode.values.firstWhere(
        (CaptureMode m) => m.name == json['mode'],
        orElse: () => CaptureMode.mobile,
      ),
      sphereSessionId: json['sphere_session_id'] as String?,
      panoramaPath: json['panorama_path'] as String?,
      previewPath: json['preview_path'] as String?,
      stitch: SphereStitchState.values.firstWhere(
        (SphereStitchState s) => s.name == json['stitch'],
        orElse: () => SphereStitchState.none,
      ),
      reportJson: json['report_json'] as String?,
      stitchError: json['stitch_error'] as String?,
    );
  }
}

/// Loaded in `main()` and injected. Deliberately **not** rebuilt by the demo
/// console's `generation` counter the way the mock repositories are: these
/// markers point at real files, and throwing them away because a fault switch
/// was flipped would orphan the panoramas. The console's reset clears the store
/// explicitly instead.
final sphereCaptureStoreProvider = Provider<SphereCaptureStore>((ref) {
  throw StateError(
    'sphereCaptureStoreProvider was read without being overridden. main() '
    'loads it before runApp; a test must override it with a store over a '
    'temporary file.',
  );
});
