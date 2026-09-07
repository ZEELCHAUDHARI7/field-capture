/// The download state of a calibration bundle.
///
/// Three states are drawn in the prototype (not downloaded, downloading,
/// available offline). [DownloadFailed] is ASSUMED: the documentation promises
/// that "a part-downloaded bundle resumes", which cannot be true without a
/// failure state. See ASSUMPTIONS.md.
sealed class DownloadState {
  const DownloadState();
}

class NotDownloaded extends DownloadState {
  const NotDownloaded();
}

class Downloading extends DownloadState {
  const Downloading(this.progress);

  /// 0.0–1.0.
  final double progress;
}

class Downloaded extends DownloadState {
  const Downloaded();
}

class DownloadFailed extends DownloadState {
  const DownloadFailed({required this.reason, required this.resumeFrom});

  final String reason;

  /// Progress the bundle had reached, so the retry resumes rather than restarts.
  final double resumeFrom;
}

/// A read-only plan bundle authored on Asite web.
class Calibration {
  const Calibration({
    required this.id,
    required this.projectId,
    required this.name,
    required this.levelCode,
    required this.levelIndex,
    required this.sizeBytes,
    required this.updatedAt,
    required this.download,
    this.hasModel = false,
  });

  final String id;
  final String projectId;

  /// "Level 03 – Slab".
  final String name;

  /// "L03" — the code shown on the level rail and used in capture names.
  final String levelCode;

  /// Storey number, basements negative. Orders the level rail bottom-up.
  final int levelIndex;

  final int sizeBytes;
  final DateTime updatedAt;
  final DownloadState download;

  /// Only levels with a 3D model offer the 3D entry point (stated).
  /// Unused until Phase 5, but carried on the model so the flag has one home.
  final bool hasModel;

  bool get isAvailableOffline => download is Downloaded;

  Calibration copyWith({DownloadState? download}) {
    return Calibration(
      id: id,
      projectId: projectId,
      name: name,
      levelCode: levelCode,
      levelIndex: levelIndex,
      sizeBytes: sizeBytes,
      updatedAt: updatedAt,
      download: download ?? this.download,
      hasModel: hasModel,
    );
  }
}
