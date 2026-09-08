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

import 'package:field_capture/features/capture/state/sphere_capability_controller.dart';
import 'package:field_capture/features/plan/data/plan_repository.dart';
import 'package:field_capture/features/projects/data/projects_repository.dart';
import 'package:field_capture/features/uploads/models/upload_item.dart';
import 'package:field_capture/features/uploads/state/upload_queue_controller.dart';
import 'package:field_capture/shared/demo/demo_controls.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'support/sphere_test_support.dart';

/// A device that can do everything, so a refusal in the tests below can only
/// have come from the demo console.
const SphereCapabilityReport _fullCapability = SphereCapabilityReport(
  capability: SphereCapability.full,
  tier: QualityTier.high,
  poseSupport: PoseSupport(
    hasGyroscope: true,
    hasAccelerometer: true,
    hasFusedRotation: true,
    hasGravity: true,
    usesMagnetometer: false,
    frame: PoseReferenceFrame.androidGameRotationVector,
    minDelayUs: 2500,
    detail: 'test double',
  ),
  supportsBracketing: true,
  maxBracketCount: 3,
  hasDistortionModel: true,
  hasManualSensor: true,
  hardwareLevel: 'LEVEL_3',
  cameraId: '0',
  totalPhysicalMemoryMb: 8192,
  warnings: <StitchWarning>[],
);

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(overrides: sphereStorageOverrides());
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

    test('the Mobile Capture switch refuses a device the probe allowed',
        () async {
      // The probe is stubbed with a device that can do everything, so what is
      // under test is the console's override rather than the hardware.
      final ProviderContainer probed = ProviderContainer(
        overrides: <Override>[
          ...sphereStorageOverrides(),
          sphereCapabilityProbeProvider.overrideWithValue(
            () async => _fullCapability,
          ),
        ],
      );
      addTearDown(probed.dispose);

      SphereCaptureGate gate =
          await probed.read(sphereCaptureGateProvider.future);
      expect(gate.isAllowed, isTrue);
      expect(gate.blockingReason, isNull);

      probed.read(demoControlsProvider.notifier).setMobileCaptureSupported(false);
      gate = await probed.read(sphereCaptureGateProvider.future);
      expect(gate.isAllowed, isFalse);
      expect(gate.blockingReason, contains('demo console'));
      // The real answer is still carried, so nothing downstream has to guess
      // whether the refusal came from the device or from the switch.
      expect(gate.report, isNotNull);
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
