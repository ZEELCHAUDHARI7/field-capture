import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/calibrations_repository.dart';
import '../models/calibration.dart';

/// Holds the calibration list for one project, and owns the download lifecycle.
///
/// Downloads live here rather than in the widget so a user can leave the screen
/// mid-download without cancelling it — which is the behaviour a site crew on a
/// bad connection needs.
class CalibrationsController
    extends FamilyAsyncNotifier<List<Calibration>, String> {
  final Map<String, StreamSubscription<double>> _downloads =
      <String, StreamSubscription<double>>{};

  @override
  Future<List<Calibration>> build(String arg) async {
    ref.onDispose(_cancelAllDownloads);
    return ref.watch(calibrationsRepositoryProvider).fetchCalibrations(arg);
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard<List<Calibration>>(
      () => ref.read(calibrationsRepositoryProvider).fetchCalibrations(arg),
    );
  }

  /// Starts, or resumes, the download of one bundle.
  void startDownload(String calibrationId) {
    if (_downloads.containsKey(calibrationId)) return;

    _patch(calibrationId, const Downloading(0));

    final Stream<double> stream = ref
        .read(calibrationsRepositoryProvider)
        .downloadBundle(calibrationId);

    _downloads[calibrationId] = stream.listen(
      (double progress) {
        if (progress >= 1) {
          _patch(calibrationId, const Downloaded());
        } else {
          _patch(calibrationId, Downloading(progress));
        }
      },
      onError: (Object error) {
        final double resumeFrom = _progressOf(calibrationId);
        _patch(
          calibrationId,
          DownloadFailed(
            reason: 'Connection dropped at ${(resumeFrom * 100).round()}%',
            resumeFrom: resumeFrom,
          ),
        );
        _release(calibrationId);
      },
      onDone: () => _release(calibrationId),
      cancelOnError: true,
    );
  }

  void cancelDownload(String calibrationId) {
    _release(calibrationId);
    _patch(calibrationId, const NotDownloaded());
  }

  double _progressOf(String calibrationId) {
    final List<Calibration>? items = state.valueOrNull;
    if (items == null) return 0;
    for (final Calibration item in items) {
      if (item.id == calibrationId) {
        final DownloadState download = item.download;
        return download is Downloading ? download.progress : 0;
      }
    }
    return 0;
  }

  void _patch(String calibrationId, DownloadState download) {
    final List<Calibration>? items = state.valueOrNull;
    if (items == null) return;

    state = AsyncValue<List<Calibration>>.data(<Calibration>[
      for (final Calibration item in items)
        if (item.id == calibrationId) item.copyWith(download: download) else item,
    ]);
  }

  void _release(String calibrationId) {
    unawaited(_downloads.remove(calibrationId)?.cancel());
  }

  void _cancelAllDownloads() {
    for (final StreamSubscription<double> sub in _downloads.values) {
      unawaited(sub.cancel());
    }
    _downloads.clear();
  }
}

final calibrationsControllerProvider = AsyncNotifierProvider.family<
    CalibrationsController, List<Calibration>, String>(
  CalibrationsController.new,
);
