import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/demo/demo_controls.dart';
import '../models/plan_marker.dart';
import '../models/plan_space.dart';
import '../models/trajectory.dart';
import '../models/workspace_data.dart';
import 'mock_plan_geometry.dart';
import 'sphere_capture_store.dart';

/// The boundary a real Asite calibration-bundle reader will implement.
abstract interface class PlanRepository {
  Future<LevelWorkspaceData> fetchWorkspace(String calibrationId);

  /// Records a 360° still or a mobile sphere against this calibration.
  ///
  /// Writes are local and unconditional — the capture path never needs the
  /// network, which is the product's central claim. Upload is a separate
  /// concern owned by the queue.
  Future<void> saveCapture(String calibrationId, CaptureMarker capture);

  /// Replaces a capture that is already recorded, by id.
  ///
  /// Exists for one transition: a sphere capture is pinned the moment the
  /// bundle is saved, with no panorama, and gains one a minute later when the
  /// stitch lands. Anything that reaches the plan before it is finished needs a
  /// way to say so afterwards.
  Future<void> updateCapture(String calibrationId, CaptureMarker capture);

  /// Records a completed video walk.
  Future<void> saveTrajectory(String calibrationId, Trajectory trajectory);

  /// Raises an issue against this calibration.
  ///
  /// Issues live with the plan rather than in their own store, because a pin
  /// without its plan is meaningless — and because it keeps one answer to
  /// "what is on this level".
  Future<void> saveIssue(String calibrationId, IssueMarker issue);
}

/// PHASE 2 MOCK.
///
/// Seeded from the prototype's Level 03 page: one 360° image capture point, two
/// issue pins, one walk recorded today (S → 1 → E) and one recorded earlier,
/// which only appears when the coverage filter is set to All.
class MockPlanRepository implements PlanRepository {
  MockPlanRepository({
    required this.sphereCaptures,
    this.latency = const Duration(milliseconds: 500),
    this.simulateError = false,
  });

  final Duration latency;
  final bool simulateError;

  /// The one part of this repository that is not mock.
  ///
  /// Sphere captures point at panoramas that are real files, so they outlive
  /// the process and are read from disk rather than from the maps below. They
  /// are merged into `fetchWorkspace` exactly as the in-memory captures are —
  /// the plan does not care which of the two a marker came from.
  final SphereCaptureStore sphereCaptures;

  /// Captures saved on this device since launch, by calibration.
  ///
  /// In memory only — persistence is deferred (ASSUMPTIONS.md §B8), so these
  /// are lost on restart. The merge below is what puts a just-saved capture
  /// back on the plan.
  final Map<String, List<CaptureMarker>> _localCaptures =
      <String, List<CaptureMarker>>{};
  final Map<String, List<Trajectory>> _localTrajectories =
      <String, List<Trajectory>>{};
  final Map<String, List<IssueMarker>> _localIssues =
      <String, List<IssueMarker>>{};

  @override
  Future<void> saveIssue(String calibrationId, IssueMarker issue) async {
    _localIssues.putIfAbsent(calibrationId, () => <IssueMarker>[]).add(issue);
  }

  @override
  Future<void> saveCapture(String calibrationId, CaptureMarker capture) async {
    if (capture.sphereSessionId != null) {
      await sphereCaptures.save(calibrationId, capture);
      return;
    }
    _localCaptures.putIfAbsent(calibrationId, () => <CaptureMarker>[]).add(capture);
  }

  @override
  Future<void> updateCapture(
    String calibrationId,
    CaptureMarker capture,
  ) async {
    if (capture.sphereSessionId != null) {
      await sphereCaptures.save(calibrationId, capture);
      return;
    }
    final List<CaptureMarker>? list = _localCaptures[calibrationId];
    if (list == null) return;
    final int index = list.indexWhere((CaptureMarker c) => c.id == capture.id);
    if (index >= 0) list[index] = capture;
  }

  @override
  Future<void> saveTrajectory(
    String calibrationId,
    Trajectory trajectory,
  ) async {
    _localTrajectories
        .putIfAbsent(calibrationId, () => <Trajectory>[])
        .add(trajectory);
  }

  /// Every level of the sample project, in rail order — basement first.
  ///
  /// The deck is internally inconsistent here: the calibration list shows three
  /// bundles but the level rail shows four (B1, L01, L03, L05). The rail is
  /// taken as correct and L01 was added to the calibration list so the two
  /// screens agree. See ASSUMPTIONS.md §F2.
  static const List<_LevelSeed> _levels = <_LevelSeed>[
    _LevelSeed('b1', 'B1', 'Basement B1', -1, false),
    _LevelSeed('l01', 'L01', 'Level 01 – Podium', 1, true),
    _LevelSeed('l03', 'L03', 'Level 03 – Slab', 3, true),
    _LevelSeed('l05', 'L05', 'Level 05 – Core & Shell', 5, false),
  ];

  @override
  Future<LevelWorkspaceData> fetchWorkspace(String calibrationId) async {
    await Future<void>.delayed(latency);

    if (simulateError) {
      throw Exception('Calibration bundle could not be opened.');
    }

    final String projectId = _projectIdOf(calibrationId);
    final String levelKey = _levelKeyOf(calibrationId);
    final _LevelSeed seed = _levels.firstWhere(
      (_LevelSeed level) => level.key == levelKey,
      orElse: () => _levels[2],
    );

    final DateTime today = DateTime.now();
    final DateTime earlier = today.subtract(const Duration(days: 5));

    return LevelWorkspaceData(
      calibrationId: calibrationId,
      levelName: seed.name,
      levelCode: seed.code,
      projectName: _projectNames[projectId] ?? 'Riverside Quarter — Tower B',
      document: MockPlanGeometry.document(),
      hasModel: seed.key == 'l03',
      levels: <WorkspaceLevel>[
        for (final _LevelSeed level in _levels)
          WorkspaceLevel(
            calibrationId: '$projectId-${level.key}',
            code: level.code,
            name: level.name,
            order: level.order,
            isAvailableOffline: level.offline,
          ),
      ],
      captures: <CaptureMarker>[
        // Real sphere captures first, then this session's in-memory ones, then
        // the seeds — newest work reads first, which is the same reason the
        // Today filter exists.
        ...sphereCaptures.forCalibration(calibrationId),
        ...?_localCaptures[calibrationId],
        CaptureMarker(
          id: '$calibrationId-cap-1',
          at: const PlanPoint(7.4, 7.3),
          recordedAt: today.subtract(const Duration(hours: 3)),
          name: '${seed.code}_Img_2026-07-03_13',
          mode: CaptureMode.image,
        ),
        // Only shown when the filter is All — this one is from a past visit.
        CaptureMarker(
          id: '$calibrationId-cap-2',
          at: const PlanPoint(18.7, 22.2),
          recordedAt: earlier,
          name: '${seed.code}_Mobile_2026-06-28_04',
          mode: CaptureMode.mobile,
        ),
      ],
      issues: <IssueMarker>[
        ...?_localIssues[calibrationId],
        IssueMarker(
          id: '$calibrationId-iss-1',
          // Lands on grid B-2, the reference printed on the deck's issue list.
          at: const PlanPoint(9.25, 15.9),
          recordedAt: today.subtract(const Duration(days: 1, hours: 4)),
          title: 'Zone B access blocked — scaffold strike in progress',
          category: IssueCategory.access,
          severity: IssueSeverity.high,
          syncState: IssueSyncState.assigned,
          assignee: 'D. Okafor',
          hasPhoto: true,
        ),
        IssueMarker(
          id: '$calibrationId-iss-2',
          // Drawn beside the core shaft, as the deck draws it. Its computed
          // reference differs from the C-2 printed on the deck — see
          // ASSUMPTIONS.md §F3.
          at: const PlanPoint(17.2, 12.6),
          recordedAt: today.subtract(const Duration(days: 2)),
          title: 'Water ingress near core shaft',
          category: IssueCategory.safety,
          severity: IssueSeverity.medium,
          syncState: IssueSyncState.synced,
        ),
      ],
      trajectories: <Trajectory>[
        ...?_localTrajectories[calibrationId],
        Trajectory(
          id: '$calibrationId-traj-1',
          name: '${seed.code}_Walk_2026-07-03_09',
          recordedAt: today.subtract(const Duration(hours: 5)),
          lengthMetres: 23,
          nodes: const <TrajectoryNode>[
            TrajectoryNode(
              kind: TrajectoryNodeKind.start,
              at: PlanPoint(13.1, 25.9),
            ),
            TrajectoryNode(
              kind: TrajectoryNodeKind.waypoint,
              at: PlanPoint(14.0, 21.1),
              sequence: 1,
            ),
            TrajectoryNode(
              kind: TrajectoryNodeKind.end,
              at: PlanPoint(20.5, 15.9),
            ),
          ],
        ),
        Trajectory(
          id: '$calibrationId-traj-2',
          name: '${seed.code}_Walk_2026-06-28_04',
          recordedAt: earlier,
          lengthMetres: 19,
          nodes: const <TrajectoryNode>[
            TrajectoryNode(
              kind: TrajectoryNodeKind.start,
              at: PlanPoint(5.0, 6.2),
            ),
            TrajectoryNode(
              kind: TrajectoryNodeKind.waypoint,
              at: PlanPoint(5.4, 8.9),
              sequence: 1,
            ),
            TrajectoryNode(
              kind: TrajectoryNodeKind.end,
              at: PlanPoint(10.2, 8.9),
            ),
          ],
        ),
      ],
    );
  }

  static const Map<String, String> _projectNames = <String, String>{
    'prj-4821': 'Riverside Quarter — Tower B',
    'prj-5107': 'Northfield Logistics Hub',
    'prj-4996': "St Mary's Hospital Extension",
  };

  /// Calibration ids are `<projectId>-<levelKey>`, e.g. `prj-4821-l03`.
  static String _projectIdOf(String calibrationId) {
    final int cut = calibrationId.lastIndexOf('-');
    return cut <= 0 ? calibrationId : calibrationId.substring(0, cut);
  }

  static String _levelKeyOf(String calibrationId) {
    final int cut = calibrationId.lastIndexOf('-');
    return cut < 0 ? calibrationId : calibrationId.substring(cut + 1);
  }
}

class _LevelSeed {
  const _LevelSeed(this.key, this.code, this.name, this.order, this.offline);
  final String key;
  final String code;
  final String name;
  final int order;
  final bool offline;
}

/// This one carries the session's saved captures, issues and walks in its own
/// fields, so rebuilding it is how the demo panel's reset clears them. Nothing
/// has to enumerate what to wipe, and nothing can drift as more state is added.
final planRepositoryProvider = Provider<PlanRepository>((ref) {
  final (bool fails, _) = ref.watch(
    demoControlsProvider
        .select((DemoControls demo) => (demo.planFails, demo.generation)),
  );
  return MockPlanRepository(
    simulateError: fails,
    // Read rather than watched: the store outlives the demo console's
    // generation counter on purpose, because the files it points at do.
    sphereCaptures: ref.read(sphereCaptureStoreProvider),
  );
});
