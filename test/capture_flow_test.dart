import 'package:field_capture/features/capture/models/capture_draft.dart';
import 'package:field_capture/features/capture/models/capture_naming.dart';
import 'package:field_capture/features/capture/state/capture_flow_controller.dart';
import 'package:field_capture/features/plan/data/plan_repository.dart';
import 'package:field_capture/features/plan/models/plan_marker.dart';
import 'package:field_capture/features/plan/models/plan_space.dart';
import 'package:field_capture/features/plan/models/trajectory.dart';
import 'package:field_capture/features/plan/models/workspace_data.dart';
import 'package:field_capture/features/uploads/models/upload_item.dart';
import 'package:field_capture/features/uploads/state/upload_queue_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The capture flow is the one place in this app where a wrong transition
/// loses a crew's work, so it is tested as a machine rather than through the UI.
void main() {
  late ProviderContainer container;
  late _RecordingPlanRepository repository;

  setUp(() {
    repository = _RecordingPlanRepository();
    container = ProviderContainer(
      overrides: <Override>[
        planRepositoryProvider.overrideWithValue(repository),
      ],
    );
  });

  tearDown(() => container.dispose());

  CaptureFlowController flow() =>
      container.read(captureFlowProvider.notifier);
  CaptureFlow state() => container.read(captureFlowProvider);

  void beginVideo() {
    flow().beginNaming(
      mode: CaptureMode.video,
      calibrationId: 'prj-4821-l03',
      levelCode: 'L03',
      now: DateTime(2026, 7, 3, 9, 41),
    );
  }

  group('naming', () {
    test('starts idle and opens on the naming phase with a pre-filled name', () {
      expect(state().phase, CapturePhase.idle);

      beginVideo();

      expect(state().phase, CapturePhase.naming);
      expect(state().draft!.name, 'L03_Walk_2026-07-03_09');
    });

    test('refuses to start a second capture while one is in flight', () {
      beginVideo();
      flow().beginNaming(
        mode: CaptureMode.image,
        calibrationId: 'prj-4821-l03',
        levelCode: 'L03',
      );

      expect(state().draft!.mode, CaptureMode.video);
    });

    test('will not advance past an invalid name', () {
      beginVideo();
      flow()
        ..rename('   ')
        ..confirmName();

      expect(state().phase, CapturePhase.naming);
    });

    test('trims the name and moves to the start pin', () {
      beginVideo();
      flow()
        ..rename('  L03_Walk_custom  ')
        ..confirmName();

      expect(state().phase, CapturePhase.pinningStart);
      expect(state().draft!.name, 'L03_Walk_custom');
    });
  });

  group('pinning', () {
    test('a tap is provisional — confirm is what commits it', () {
      beginVideo();
      flow()
        ..confirmName()
        ..placeProvisionalPin(const PlanPoint(10, 12));

      expect(state().draft!.provisionalPin, isNotNull);
      expect(state().draft!.startPin, isNull, reason: 'not committed yet');

      flow().confirmStartPin();

      expect(state().draft!.startPin, const PlanPoint(10, 12));
      expect(state().draft!.provisionalPin, isNull);
    });

    test('confirming with no pin placed does nothing', () {
      beginVideo();
      flow()
        ..confirmName()
        ..confirmStartPin();

      expect(state().phase, CapturePhase.pinningStart);
    });

    test('a mis-tap costs nothing — the crosshair just moves', () {
      beginVideo();
      flow()
        ..confirmName()
        ..placeProvisionalPin(const PlanPoint(1, 1))
        ..placeProvisionalPin(const PlanPoint(20, 20))
        ..confirmStartPin();

      expect(state().draft!.startPin, const PlanPoint(20, 20));
    });
  });

  group('the walk', () {
    void walkToRecording() {
      beginVideo();
      flow()
        ..confirmName()
        ..placeProvisionalPin(const PlanPoint(13.1, 25.9))
        ..confirmStartPin();
    }

    test('video goes to recording; image saves straight away', () {
      walkToRecording();
      expect(state().phase, CapturePhase.recording);

      flow().discard();

      flow()
        ..beginNaming(
          mode: CaptureMode.image,
          calibrationId: 'prj-4821-l03',
          levelCode: 'L03',
        )
        ..confirmName()
        ..placeProvisionalPin(const PlanPoint(4, 4))
        ..confirmStartPin();

      expect(state().phase, CapturePhase.saving);
    });

    test('waypoints number from 1 and keep the recording alive', () {
      walkToRecording();

      flow().requestWaypoint();
      expect(state().phase, CapturePhase.pinningWaypoint);
      expect(state().draft!.nextWaypointNumber, 1);

      flow()
        ..placeProvisionalPin(const PlanPoint(14, 21))
        ..confirmWaypoint();

      expect(state().phase, CapturePhase.recording);
      expect(state().draft!.waypoints.length, 1);
      expect(state().draft!.nextWaypointNumber, 2);
    });

    test('backing out of a waypoint records nothing', () {
      walkToRecording();
      flow()
        ..requestWaypoint()
        ..placeProvisionalPin(const PlanPoint(14, 21))
        ..cancelWaypoint();

      expect(state().phase, CapturePhase.recording);
      expect(state().draft!.waypoints, isEmpty);
      expect(state().draft!.provisionalPin, isNull);
    });

    test('stopping asks for an end pin and Save stays blocked without one', () {
      walkToRecording();
      flow().stopWalking();

      expect(state().phase, CapturePhase.pinningEnd);

      flow().confirmEndPin();
      expect(state().phase, CapturePhase.pinningEnd,
          reason: 'no end pin placed');
    });

    test('a saved walk reaches the plan and the upload queue', () async {
      walkToRecording();
      flow()
        ..requestWaypoint()
        ..placeProvisionalPin(const PlanPoint(14, 21))
        ..confirmWaypoint()
        ..stopWalking()
        ..placeProvisionalPin(const PlanPoint(20.5, 15.9))
        ..confirmEndPin();

      await Future<void>.delayed(Duration.zero);

      expect(state().phase, CapturePhase.idle);
      expect(repository.savedTrajectories, hasLength(1));

      final Trajectory saved = repository.savedTrajectories.single;
      expect(saved.nodes.map((TrajectoryNode n) => n.kind), <TrajectoryNodeKind>[
        TrajectoryNodeKind.start,
        TrajectoryNodeKind.waypoint,
        TrajectoryNodeKind.end,
      ]);
      expect(saved.name, 'L03_Walk_2026-07-03_09');

      final List<UploadItem> queue = container.read(uploadQueueProvider);
      expect(queue.first.name, 'L03_Walk_2026-07-03_09');
      expect(queue.first.status, UploadStatus.waiting);
    });

    test('discarding at any point leaves nothing behind', () async {
      walkToRecording();
      flow()
        ..requestWaypoint()
        ..placeProvisionalPin(const PlanPoint(14, 21))
        ..confirmWaypoint()
        ..stopWalking()
        ..discard();

      await Future<void>.delayed(Duration.zero);

      expect(state().phase, CapturePhase.idle);
      expect(state().draft, isNull);
      expect(repository.savedTrajectories, isEmpty);
      expect(repository.savedCaptures, isEmpty);
    });
  });

  group('ownership', () {
    test('a flow belongs to the calibration it started on', () {
      beginVideo();
      expect(state().ownedBy('prj-4821-l03'), isTrue);
      expect(state().ownedBy('prj-4821-b1'), isFalse);
    });
  });

  group('CaptureNaming', () {
    test('reads the trailing token as the hour of capture', () {
      expect(
        CaptureNaming.build(
          levelCode: 'L03',
          mode: CaptureMode.image,
          now: DateTime(2026, 7, 3, 13, 5),
        ),
        'L03_Img_2026-07-03_13',
      );
      expect(
        CaptureNaming.build(
          levelCode: 'B1',
          mode: CaptureMode.video,
          now: DateTime(2026, 7, 1, 2, 30),
        ),
        'B1_Walk_2026-07-01_02',
      );
    });

    test('disambiguates a second capture in the same hour', () {
      const String taken = 'L03_Img_2026-07-03_13';
      expect(
        CaptureNaming.build(
          levelCode: 'L03',
          mode: CaptureMode.image,
          now: DateTime(2026, 7, 3, 13, 40),
          existingNames: const <String>[taken],
        ),
        'L03_Img_2026-07-03_13_2',
      );
    });

    test('rejects names the upload queue could not carry', () {
      expect(CaptureNaming.validate(''), isNotNull);
      expect(CaptureNaming.validate('has spaces'), isNotNull);
      expect(CaptureNaming.validate('a' * 80), isNotNull);
      expect(CaptureNaming.validate('L03_Walk_2026-07-03_09'), isNull);
    });
  });

  group('CaptureDraft', () {
    test('measures the path through its pins', () {
      const CaptureDraft draft = CaptureDraft(
        mode: CaptureMode.video,
        calibrationId: 'c',
        levelCode: 'L03',
        name: 'n',
        startPin: PlanPoint(0, 0),
        waypoints: <PlanPoint>[PlanPoint(3, 4)],
        endPin: PlanPoint(3, 8),
      );

      expect(draft.pathLengthMetres, closeTo(9, 0.0001));
    });

    test('builds a live trail only once a start pin exists', () {
      const CaptureDraft empty = CaptureDraft(
        mode: CaptureMode.video,
        calibrationId: 'c',
        levelCode: 'L03',
        name: 'n',
      );
      expect(empty.liveTrajectory, isNull);

      final CaptureDraft started =
          empty.copyWith(startPin: const PlanPoint(1, 1));
      expect(started.liveTrajectory!.nodes, hasLength(1));
    });
  });
}

/// Captures what the flow writes, without any of the mock's seed data.
class _RecordingPlanRepository implements PlanRepository {
  final List<CaptureMarker> savedCaptures = <CaptureMarker>[];
  final List<Trajectory> savedTrajectories = <Trajectory>[];
  final List<IssueMarker> savedIssues = <IssueMarker>[];

  @override
  Future<void> saveIssue(String calibrationId, IssueMarker issue) async {
    savedIssues.add(issue);
  }

  @override
  Future<void> saveCapture(String calibrationId, CaptureMarker capture) async {
    savedCaptures.add(capture);
  }

  @override
  Future<void> saveTrajectory(
    String calibrationId,
    Trajectory trajectory,
  ) async {
    savedTrajectories.add(trajectory);
  }

  @override
  Future<LevelWorkspaceData> fetchWorkspace(String calibrationId) {
    throw UnimplementedError('not needed for flow tests');
  }
}
