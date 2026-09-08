import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/demo/demo_controls.dart';
import '../models/calibration.dart';

/// The boundary a real Asite calibrations client will implement.
///
/// [downloadBundle] returns a progress stream rather than a Future so the
/// UI can render the "46%" state the prototype draws, and so a real
/// implementation can resume from a byte offset without changing this signature.
abstract interface class CalibrationsRepository {
  Future<List<Calibration>> fetchCalibrations(String projectId);

  Stream<double> downloadBundle(String calibrationId);
}

/// PHASE 1 MOCK.
///
/// Seeded with the prototype's own three calibrations so the built screen can
/// be held next to page 04 of the PDF.
class MockCalibrationsRepository implements CalibrationsRepository {
  MockCalibrationsRepository({
    this.latency = const Duration(milliseconds: 600),
    this.simulateEmpty = false,
    this.simulateError = false,
    this.simulateDownloadFailure = false,
  });

  final Duration latency;
  final bool simulateEmpty;
  final bool simulateError;

  /// Fails a download at 62%, matching the upload queue's failure copy, so QA
  /// can exercise the resume path.
  final bool simulateDownloadFailure;

  @override
  Future<List<Calibration>> fetchCalibrations(String projectId) async {
    await Future<void>.delayed(latency);

    if (simulateError) {
      throw Exception('Calibration list unavailable.');
    }
    if (simulateEmpty) return const <Calibration>[];

    // The deck's calibration list shows three bundles, but its level rail shows
    // four (B1, L01, L03, L05). L01 is added here so the two screens agree —
    // see ASSUMPTIONS.md §F2. Ids are `<projectId>-<levelKey>`; the plan
    // repository parses them, so the shape matters.
    return <Calibration>[
      Calibration(
        id: '$projectId-l03',
        projectId: projectId,
        name: 'Level 03 – Slab',
        levelCode: 'L03',
        levelIndex: 3,
        sizeBytes: 24 * 1000 * 1000,
        updatedAt: DateTime(2026, 6, 28),
        download: const Downloaded(),
        hasModel: true,
      ),
      Calibration(
        id: '$projectId-b1',
        projectId: projectId,
        name: 'Basement B1',
        levelCode: 'B1',
        levelIndex: -1,
        sizeBytes: 18 * 1000 * 1000,
        updatedAt: DateTime(2026, 6, 26),
        download: const NotDownloaded(),
      ),
      Calibration(
        id: '$projectId-l01',
        projectId: projectId,
        name: 'Level 01 – Podium',
        levelCode: 'L01',
        levelIndex: 1,
        sizeBytes: 22 * 1000 * 1000,
        updatedAt: DateTime(2026, 6, 27),
        download: const Downloaded(),
      ),
      Calibration(
        id: '$projectId-l05',
        projectId: projectId,
        name: 'Level 05 – Core & Shell',
        levelCode: 'L05',
        levelIndex: 5,
        sizeBytes: 31 * 1000 * 1000,
        updatedAt: DateTime(2026, 6, 30),
        download: const Downloading(0.46),
      ),
    ];
  }

  @override
  Stream<double> downloadBundle(String calibrationId) async* {
    double progress = 0;
    while (progress < 1) {
      await Future<void>.delayed(const Duration(milliseconds: 220));
      progress = (progress + 0.07).clamp(0.0, 1.0);

      if (simulateDownloadFailure && progress >= 0.62) {
        throw Exception('Connection dropped at 62%');
      }
      yield progress;
    }
  }
}

/// See the note on `projectsRepositoryProvider`. The download fault is read
/// here too, so a bundle can be made to drop at 62% mid-demo.
final calibrationsRepositoryProvider =
    Provider<CalibrationsRepository>((ref) {
  final (DataFault fault, bool downloadsFail, _) = ref.watch(
    demoControlsProvider.select(
      (DemoControls demo) =>
          (demo.calibrations, demo.downloadsFail, demo.generation),
    ),
  );
  return MockCalibrationsRepository(
    simulateEmpty: fault == DataFault.empty,
    simulateError: fault == DataFault.error,
    simulateDownloadFailure: downloadsFail,
  );
});
