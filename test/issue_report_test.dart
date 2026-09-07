import 'package:field_capture/features/issues/models/issue_draft.dart';
import 'package:field_capture/features/issues/state/issue_report_controller.dart';
import 'package:field_capture/features/plan/data/mock_plan_geometry.dart';
import 'package:field_capture/features/plan/data/plan_repository.dart';
import 'package:field_capture/features/plan/models/plan_document.dart';
import 'package:field_capture/features/plan/models/plan_marker.dart';
import 'package:field_capture/features/plan/models/plan_space.dart';
import 'package:field_capture/features/plan/models/trajectory.dart';
import 'package:field_capture/features/plan/models/workspace_data.dart';
import 'package:field_capture/shared/connectivity/connectivity_controller.dart';
import 'package:field_capture/shared/connectivity/connectivity_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The report flow is short, but it is where the prototype contradicts itself
/// — "Next — pin location" against "the pin defaults to the current plan
/// centre if not placed". These tests pin down the reading taken (§H1).
void main() {
  late ProviderContainer container;
  late _RecordingPlanRepository repository;

  final PlanDocument document = MockPlanGeometry.document();
  const String calibrationId = 'prj-4821-l03';

  setUp(() {
    repository = _RecordingPlanRepository();
    container = ProviderContainer(
      overrides: <Override>[
        planRepositoryProvider.overrideWithValue(repository),
      ],
    );
  });

  tearDown(() => container.dispose());

  IssueReportController flow() => container.read(issueReportProvider.notifier);
  IssueReportFlow state() => container.read(issueReportProvider);

  group('composing', () {
    test('opens with the prototype\'s defaults', () {
      flow().begin(calibrationId);

      expect(state().phase, IssueReportPhase.composing);
      expect(state().draft!.category, IssueCategory.access);
      expect(state().draft!.severity, IssueSeverity.medium);
      expect(state().draft!.hasPhoto, isFalse);
    });

    test('will not advance without a title — the only required field', () {
      flow()
        ..begin(calibrationId)
        ..confirmCompose();
      expect(state().phase, IssueReportPhase.composing);

      flow()
        ..setTitle('   ')
        ..confirmCompose();
      expect(state().phase, IssueReportPhase.composing);

      flow()
        ..setTitle('  Zone C access blocked  ')
        ..confirmCompose();
      expect(state().phase, IssueReportPhase.pinning);
      expect(state().draft!.title, 'Zone C access blocked');
    });

    test('a photo is optional and either button attaches one', () {
      flow()
        ..begin(calibrationId)
        ..attachPhoto();
      expect(state().draft!.hasPhoto, isTrue);
    });

    test('refuses to start a second report while one is open', () {
      flow()
        ..begin(calibrationId)
        ..setTitle('First')
        ..begin('prj-4821-b1');
      expect(state().draft!.calibrationId, calibrationId);
    });
  });

  group('pinning', () {
    void toPinning() {
      flow()
        ..begin(calibrationId)
        ..setTitle('Water ingress near core shaft')
        ..confirmCompose();
    }

    test('saves at the tapped point', () async {
      toPinning();
      flow().placePin(const PlanPoint(9.25, 15.9));
      await flow().save(document);

      expect(repository.saved, hasLength(1));
      expect(repository.saved.single.at, const PlanPoint(9.25, 15.9));
      expect(state().phase, IssueReportPhase.idle);
    });

    test('falls back to the centre of the plan when never tapped', () async {
      toPinning();
      await flow().save(document);

      final PlanPoint at = repository.saved.single.at;
      expect(at.x, closeTo(document.widthMetres / 2, 0.0001));
      expect(at.y, closeTo(document.heightMetres / 2, 0.0001));
    });

    test('the pin can be moved before saving', () async {
      toPinning();
      flow()
        ..placePin(const PlanPoint(1, 1))
        ..placePin(const PlanPoint(17.2, 12.6));
      await flow().save(document);

      expect(repository.saved.single.at, const PlanPoint(17.2, 12.6));
    });

    test('the grid reference is derived from the pin, never typed', () async {
      toPinning();
      flow().placePin(const PlanPoint(9.25, 15.9));
      await flow().save(document);

      expect(document.grid.referenceFor(repository.saved.single.at), 'B-2');
    });

    test('Back returns to the sheet without losing what was typed', () {
      toPinning();
      flow()
        ..placePin(const PlanPoint(5, 5))
        ..backToCompose();

      expect(state().phase, IssueReportPhase.composing);
      expect(state().draft!.title, 'Water ingress near core shaft');
    });

    test('cancelling leaves nothing behind', () async {
      toPinning();
      flow().cancel();

      expect(state().phase, IssueReportPhase.idle);
      expect(state().draft, isNull);
      expect(repository.saved, isEmpty);
    });
  });

  group('sync state on creation', () {
    test('queued when there is signal', () async {
      container
          .read(connectivityControllerProvider.notifier)
          .setStatus(ConnectivityStatus.online);
      flow()
        ..begin(calibrationId)
        ..setTitle('Scaffold strike')
        ..confirmCompose();
      await flow().save(document);

      expect(repository.saved.single.syncState, IssueSyncState.queued);
    });

    test('local when offline — raising an issue never needs a round trip',
        () async {
      container
          .read(connectivityControllerProvider.notifier)
          .setStatus(ConnectivityStatus.offline);
      flow()
        ..begin(calibrationId)
        ..setTitle('Scaffold strike')
        ..confirmCompose();
      await flow().save(document);

      expect(repository.saved.single.syncState, IssueSyncState.local);
    });
  });
}

class _RecordingPlanRepository implements PlanRepository {
  final List<IssueMarker> saved = <IssueMarker>[];

  @override
  Future<void> saveIssue(String calibrationId, IssueMarker issue) async {
    saved.add(issue);
  }

  @override
  Future<void> saveCapture(String calibrationId, CaptureMarker capture) async {}

  @override
  Future<void> saveTrajectory(String c, Trajectory t) async {}

  @override
  Future<LevelWorkspaceData> fetchWorkspace(String calibrationId) {
    throw UnimplementedError('not needed for report-flow tests');
  }
}
