// The demo console's wiring.
//
// The panel itself is buttons, but two things behind it are load-bearing and
// easy to break without noticing:
//
//  1. A fault has to reach the repository, or the control is decorative.
//  2. A fault must reach ONLY its own repository. Every repository reads the
//     same DemoControls object, so a careless `ref.watch(demoControlsProvider)`
//     instead of a `.select` would rebuild all of them on every toggle — and
//     because the plan mock carries the session's saved captures, issues and
//     walks in its own fields, flipping the project list would quietly throw
//     away the walk that was just recorded on stage.

import 'package:field_capture/features/capture/state/capture_flow_controller.dart';
import 'package:field_capture/features/plan/data/plan_repository.dart';
import 'package:field_capture/features/projects/data/projects_repository.dart';
import 'package:field_capture/features/uploads/models/upload_item.dart';
import 'package:field_capture/features/uploads/state/upload_queue_controller.dart';
import 'package:field_capture/shared/demo/demo_controls.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  DemoControlsController demo() =>
      container.read(demoControlsProvider.notifier);

  group('faults reach their own repository', () {
    test('project list: normal, then empty, then error', () async {
      expect(await container.read(projectsRepositoryProvider).fetchProjects(),
          isNotEmpty);

      demo().setProjects(DataFault.empty);
      expect(await container.read(projectsRepositoryProvider).fetchProjects(),
          isEmpty);

      demo().setProjects(DataFault.error);
      expect(container.read(projectsRepositoryProvider).fetchProjects(),
          throwsA(anything));
    });

    test('the Mobile Capture gate follows the switch', () {
      expect(container.read(mobileCaptureSupportedProvider), isTrue);
      demo().setMobileCaptureSupported(false);
      expect(container.read(mobileCaptureSupportedProvider), isFalse);
    });
  });

  group('faults stay in their own lane', () {
    test('a project fault leaves the plan repository alone', () {
      final PlanRepository before = container.read(planRepositoryProvider);
      demo().setProjects(DataFault.error);
      expect(
        identical(container.read(planRepositoryProvider), before),
        isTrue,
        reason: 'rebuilding the plan mock here would discard the session',
      );
    });

    test('a plan fault does rebuild it', () {
      final PlanRepository before = container.read(planRepositoryProvider);
      demo().setPlanFails(true);
      expect(
        identical(container.read(planRepositoryProvider), before),
        isFalse,
      );
    });
  });

  group('reset', () {
    test('replaces every repository, which is what clears the session', () {
      final PlanRepository plan = container.read(planRepositoryProvider);
      final ProjectsRepository projects =
          container.read(projectsRepositoryProvider);

      demo().reset();

      expect(identical(container.read(planRepositoryProvider), plan), isFalse);
      expect(identical(container.read(projectsRepositoryProvider), projects),
          isFalse);
    });

    test('clears the faults and bumps the generation', () {
      demo()
        ..setProjects(DataFault.error)
        ..setPlanFails(true)
        ..setMobileCaptureSupported(false);
      expect(container.read(demoControlsProvider).activeFaults, 3);
      expect(container.read(demoControlsProvider).isPristine, isFalse);

      demo().reset();

      final DemoControls after = container.read(demoControlsProvider);
      expect(after.isPristine, isTrue);
      expect(after.activeFaults, 0);
      expect(after.generation, 1, reason: 'the generation must not reset');
    });
  });

  test('failing the active upload fails the one in flight', () {
    final UploadQueueController queue =
        container.read(uploadQueueProvider.notifier);
    final UploadItem inFlight = container
        .read(uploadQueueProvider)
        .firstWhere((UploadItem i) => i.status == UploadStatus.uploading);

    queue.simulateFailure();

    final UploadItem after = container
        .read(uploadQueueProvider)
        .firstWhere((UploadItem i) => i.id == inFlight.id);
    expect(after.status, UploadStatus.failed);
    expect(after.failureReason, isNotNull);
    expect(after.progress, inFlight.progress,
        reason: 'failed items keep their bytes and resume from the offset');
  });
}
