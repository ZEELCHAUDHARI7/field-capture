// The 360° capture path.
//
// One property here matters more than the rest and is the easiest in the whole
// app to break without noticing: **the capture path must not wait for a
// stitch.** A stitch takes up to a minute and a site walk has thirty stations,
// so an `await queue.drained` on this path is half an hour of a crew standing
// still. Everything still works when it is wrong — the panoramas come out,
// correct, in order — which is why it is pinned by a test rather than left to
// review.

import 'dart:async';
import 'dart:io';

import 'package:field_capture/features/capture/models/capture_draft.dart';
import 'package:field_capture/features/capture/state/capture_flow_controller.dart';
import 'package:field_capture/features/capture/models/stitch_job.dart';
import 'package:field_capture/features/capture/state/stitch_queue_controller.dart';
import 'package:field_capture/features/plan/data/plan_repository.dart';
import 'package:field_capture/features/plan/data/sphere_capture_store.dart';
import 'package:field_capture/features/plan/models/plan_marker.dart';
import 'package:field_capture/features/plan/models/plan_space.dart';
import 'package:field_capture/features/plan/models/trajectory.dart';
import 'package:field_capture/features/plan/models/workspace_data.dart';
import 'package:field_capture/features/uploads/state/upload_queue_controller.dart';
import 'package:field_capture/shared/storage/sphere_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'support/sphere_test_support.dart';

void main() {
  late ProviderContainer container;
  late _RecordingPlanRepository repository;
  late List<Override> storage;

  setUp(() {
    repository = _RecordingPlanRepository();
    storage = sphereStorageOverrides();
    container = ProviderContainer(
      overrides: <Override>[
        ...storage,
        planRepositoryProvider.overrideWithValue(repository),
      ],
    );
    // Registered after the storage override's tear-down, so it runs first
    // (LIFO). The queue is stopped and *awaited* rather than merely disposed:
    // the drain writes its state file between awaits, and deleting the
    // directory under a half-finished write surfaces as a PathNotFound in
    // whichever test happens to be running by then.
    addTearDown(() async {
      await container.read(stitchQueueProvider).dispose();
      container.dispose();
    });
  });

  CaptureFlowController flow() => container.read(captureFlowProvider.notifier);
  CaptureFlow state() => container.read(captureFlowProvider);

  /// Walks the flow to the point where the capture screen would open.
  void beginSphereCapture() {
    flow()
      ..beginNaming(
        mode: CaptureMode.mobile,
        calibrationId: 'prj-4821-l03',
        levelCode: 'L03',
        now: DateTime(2026, 9, 8, 14, 2),
      )
      ..confirmName()
      ..placeProvisionalPin(const PlanPoint(11.5, 8.25))
      ..confirmStartPin();
  }

  group('the flow', () {
    test('a confirmed pin opens the capture rather than a timer', () {
      beginSphereCapture();

      expect(state().phase, CapturePhase.sphereCapture);
      // The pin is held on the draft, not committed. Nothing is on the plan
      // until there is a capture behind it.
      expect(state().draft!.startPin, const PlanPoint(11.5, 8.25));
      expect(repository.savedCaptures, isEmpty);
    });

    test('the session id is minted before the capture screen opens', () {
      beginSphereCapture();

      // It names the bundle directory, so it has to exist before anything is
      // written into it — that is what makes a capture the app was killed
      // during findable afterwards.
      expect(state().draft!.sphereSessionId, isNotNull);
      expect(state().draft!.sphereSessionId, startsWith('sphere-'));
    });

    test('discarding leaves nothing behind', () {
      beginSphereCapture();
      flow().discard();

      expect(state().phase, CapturePhase.idle);
      expect(state().draft, isNull);
      expect(repository.savedCaptures, isEmpty);
    });
  });

  group('saving a capture', () {
    late CaptureBundle bundle;

    setUp(() {
      beginSphereCapture();
      bundle = fakeBundle(
        sessionId: state().draft!.sphereSessionId!,
        directory: container
            .read(sphereStorageProvider)
            .bundleDirectory(state().draft!.sphereSessionId!),
      );
    });

    test('the pin reaches the plan before the stitch does', () async {
      await flow().completeSphereCapture(bundle);

      final CaptureMarker saved = repository.savedCaptures.single;
      expect(saved.name, 'L03_Mobile_2026-09-08_14');
      expect(saved.at, const PlanPoint(11.5, 8.25));
      expect(saved.sphereSessionId, bundle.sessionId);

      // The whole point: pinned, and openly not finished. A pin that only
      // appeared once the panorama existed would leave the crew looking at an
      // empty plan for a minute after a successful capture.
      expect(saved.stitch, SphereStitchState.stitching);
      expect(saved.panoramaPath, isNull);
    });

    test('returns without waiting for the stitch', () async {
      // If `completeSphereCapture` ever awaits the drain, this test hangs
      // rather than fails — so it is bounded. A real stitch is ~60 s; anything
      // near that means the capture path is blocking on it.
      await flow().completeSphereCapture(bundle).timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail(
              'the capture path waited for the stitch. `finish()` hands back a '
              'bundle and the crew keeps walking — see docs/INTEGRATION.md §2.',
            ),
          );

      expect(state().phase, CapturePhase.idle);
    });

    test('the flow is free for the next station immediately', () async {
      await flow().completeSphereCapture(bundle);

      flow().beginNaming(
        mode: CaptureMode.mobile,
        calibrationId: 'prj-4821-l03',
        levelCode: 'L03',
      );
      expect(state().phase, CapturePhase.naming);
    });

    test('nothing is committed from a phase that did not capture', () async {
      flow().discard();
      await flow().completeSphereCapture(bundle);

      expect(repository.savedCaptures, isEmpty);
    });

    test('a partial sphere is saved like any other', () async {
      // `fakeBundle` is deliberately short of its plan — one target, no
      // positions. A capture ended early is a real deliverable, not a failed
      // one: the pipeline stitches what it is given and fills the uncovered
      // poles, and the review screen states the coverage before a minute of
      // stitching is spent on it. Nothing on this path may check for
      // completeness and refuse.
      expect(bundle.positions.length, lessThan(bundle.plan.targets.length));

      await flow().completeSphereCapture(bundle);

      expect(repository.savedCaptures, hasLength(1));
      expect(
        repository.savedCaptures.single.stitch,
        SphereStitchState.stitching,
      );
    });

    test('the upload is not queued until the panorama exists', () async {
      final int before = container.read(uploadQueueProvider).length;
      await flow().completeSphereCapture(bundle);

      // The mock modes estimate their size at capture time. A sphere cannot:
      // the number would be the length of a file that has not been written
      // yet, so the enqueue happens when the stitch lands instead.
      expect(container.read(uploadQueueProvider), hasLength(before));
    });
  });

  group('the marker', () {
    test('a stitched capture carries what the viewer needs', () {
      final CaptureMarker pinned = CaptureMarker(
        id: 'cap-1',
        at: const PlanPoint(1, 2),
        recordedAt: _when,
        name: 'L03_Mobile_2026-09-08_14',
        mode: CaptureMode.mobile,
        sphereSessionId: 'sphere-1',
        stitch: SphereStitchState.stitching,
      );
      expect(pinned.hasPanorama, isFalse);
      expect(pinned.viewablePath, isNull);

      final CaptureMarker previewed = pinned.copyWith(
        previewPath: '/spheres/panoramas/sphere-1_preview.jpg',
        stitch: SphereStitchState.ready,
      );
      // A preview is a complete panorama at a lower resolution, so it is worth
      // opening rather than making the crew wait for the full pass.
      expect(previewed.hasPanorama, isTrue);
      expect(previewed.viewablePath, endsWith('_preview.jpg'));

      final CaptureMarker done = previewed.copyWith(
        panoramaPath: '/spheres/panoramas/sphere-1.jpg',
      );
      // Full resolution wins once it is there.
      expect(done.viewablePath, '/spheres/panoramas/sphere-1.jpg');
    });

    test('the seeded mock captures are untouched by any of this', () {
      final CaptureMarker seeded = CaptureMarker(
        id: 'cap-seed',
        at: const PlanPoint(7.4, 7.3),
        recordedAt: _when,
        name: 'L03_Img_2026-07-03_13',
        mode: CaptureMode.image,
      );
      expect(seeded.stitch, SphereStitchState.none);
      expect(seeded.hasPanorama, isFalse);
    });
  });

  group('SphereCaptureStore', () {
    late SphereCaptureStore store;

    setUp(() {
      store = container.read(sphereCaptureStoreProvider);
    });

    test('a capture survives being read back', () async {
      final CaptureMarker marker = CaptureMarker(
        id: 'cap-1',
        at: const PlanPoint(11.5, 8.25),
        recordedAt: _when,
        name: 'L03_Mobile_2026-09-08_14',
        mode: CaptureMode.mobile,
        sphereSessionId: 'sphere-1',
        panoramaPath: '/spheres/panoramas/sphere-1.jpg',
        previewPath: '/spheres/panoramas/sphere-1_preview.jpg',
        stitch: SphereStitchState.ready,
        reportJson: '{"coverage_fraction":0.99}',
      );
      await store.save('prj-4821-l03', marker);

      // A second store over the same file is the restart.
      final SphereCaptureStore reopened = SphereCaptureStore(store.file);
      await reopened.load();

      final CaptureMarker read =
          reopened.forCalibration('prj-4821-l03').single;
      expect(read.id, 'cap-1');
      expect(read.name, 'L03_Mobile_2026-09-08_14');
      expect(read.at, const PlanPoint(11.5, 8.25));
      expect(read.mode, CaptureMode.mobile);
      expect(read.sphereSessionId, 'sphere-1');
      expect(read.panoramaPath, '/spheres/panoramas/sphere-1.jpg');
      expect(read.previewPath, endsWith('_preview.jpg'));
      expect(read.stitch, SphereStitchState.ready);
      expect(read.reportJson, '{"coverage_fraction":0.99}');
      expect(read.recordedAt, _when);
    });

    test('saving the same id twice replaces rather than duplicates', () async {
      final CaptureMarker marker = CaptureMarker(
        id: 'cap-1',
        at: const PlanPoint(1, 1),
        recordedAt: _when,
        name: 'L03_Mobile_2026-09-08_14',
        mode: CaptureMode.mobile,
        sphereSessionId: 'sphere-1',
        stitch: SphereStitchState.stitching,
      );
      await store.save('prj-4821-l03', marker);
      await store.save(
        'prj-4821-l03',
        marker.copyWith(stitch: SphereStitchState.ready),
      );

      // This is the stitching → ready transition, and it must not leave two
      // pins on the plan at the same point.
      final List<CaptureMarker> saved = store.forCalibration('prj-4821-l03');
      expect(saved, hasLength(1));
      expect(saved.single.stitch, SphereStitchState.ready);
    });

    test('update finds a marker without being told which level it is on',
        () async {
      final CaptureMarker marker = CaptureMarker(
        id: 'cap-1',
        at: const PlanPoint(1, 1),
        recordedAt: _when,
        name: 'L03_Mobile_2026-09-08_14',
        mode: CaptureMode.mobile,
        sphereSessionId: 'sphere-1',
        stitch: SphereStitchState.stitching,
      );
      await store.save('prj-4821-l05', marker);

      // The stitch queue only knows session ids — nothing recorded which level
      // an entry belongs to, least of all one recovered after a kill.
      final String? found = await store.update(
        marker.copyWith(stitch: SphereStitchState.ready),
      );
      expect(found, 'prj-4821-l05');

      // A capture that has since been discarded reports as much rather than
      // resurrecting itself. `_updateMarker` depends on this: a stitch that
      // lands after the operator discarded the capture must not write the pin
      // back onto the plan.
      final String? missing = await store.update(
        CaptureMarker(
          id: 'cap-discarded',
          at: const PlanPoint(1, 1),
          recordedAt: _when,
          name: 'gone',
          mode: CaptureMode.mobile,
          sphereSessionId: 'sphere-gone',
        ),
      );
      expect(missing, isNull);
    });

    test('a corrupt file is treated as absent, not as fatal', () async {
      await store.file.writeAsString('{not json at all');

      final SphereCaptureStore reopened = SphereCaptureStore(store.file);
      await reopened.load();

      // The alternative is an app that will not open its own plan because one
      // marker was written by a build that has since changed shape — and the
      // panoramas are still on disk either way.
      expect(reopened.forCalibration('prj-4821-l03'), isEmpty);
    });

    test('clear empties it, which is what the demo console needs', () async {
      await store.save(
        'prj-4821-l03',
        CaptureMarker(
          id: 'cap-1',
          at: const PlanPoint(1, 1),
          recordedAt: _when,
          name: 'L03_Mobile_2026-09-08_14',
          mode: CaptureMode.mobile,
          sphereSessionId: 'sphere-1',
        ),
      );
      await store.clear();

      expect(store.forCalibration('prj-4821-l03'), isEmpty);
      expect(store.file.existsSync(), isFalse);
    });
  });

  group('StitchJob', () {
    const StitchJob queued = StitchJob(
      sessionId: 'sphere-1',
      captureName: 'L03_Mobile_2026-09-08_14',
      calibrationId: 'prj-4821-l03',
    );

    test('says what it is doing, not just a percentage', () {
      // The stage exists rather than a bare number because a 60-second stitch
      // showing only "47%" is indistinguishable from a hung one.
      final StitchJob running = queued.copyWith(
        stage: StitchStage.blending,
        fraction: 0.47,
        message: 'Blending the seams',
      );
      expect(running.statusLine, 'Blending the seams');
      expect(running.isActive, isTrue);
    });

    test('a thermal pause displaces the stage', () {
      final StitchJob hot = queued.copyWith(
        message: 'Blending the seams',
        pauseReason: 'Paused — the device is too warm',
      );
      // What the crew can act on wins over what the pipeline was doing.
      expect(hot.statusLine, 'Paused — the device is too warm');
      expect(hot.isPaused, isTrue);
    });

    test('a failure displaces everything', () {
      final StitchJob failed = queued.copyWith(
        message: 'Blending the seams',
        pauseReason: 'Paused — the device is too warm',
        error: 'out of memory',
      );
      expect(failed.statusLine, contains('out of memory'));
      expect(failed.isFailed, isTrue);
    });

    test('clearing a pause does not clear the error, and vice versa', () {
      final StitchJob job =
          queued.copyWith(error: 'out of memory', pauseReason: 'too warm');

      expect(job.copyWith(clearPauseReason: true).isFailed, isTrue);
      expect(job.copyWith(clearError: true).isPaused, isTrue);
    });
  });

  group('the queue is actually driven', () {
    // The bug this pins cost a whole capture and was invisible in every other
    // test: `StitchQueue._drain` returns the moment it finds nothing pending,
    // and `enqueue` does not restart it. The drain that ran at boot, over an
    // empty queue, had already finished — so the first capture of a session sat
    // at 0% forever, and then completed on the *next* launch, when `load()`
    // found it pending and `start()` picked it up.
    late _FakeStitcher stitcher;
    late ProviderContainer driven;
    late _RecordingPlanRepository repo;

    setUp(() {
      stitcher = _FakeStitcher();
      repo = _RecordingPlanRepository();
      final List<Override> overrides = sphereStorageOverrides(
        prefix: 'field_capture_drain',
      );
      driven = ProviderContainer(
        overrides: <Override>[
          ...overrides,
          planRepositoryProvider.overrideWithValue(repo),
          stitchQueueProvider.overrideWith((Ref ref) {
            final StitchQueue queue = StitchQueue(
              directory: ref.watch(sphereStorageProvider).queueDirectory,
              stitcherFactory: ({QualityTier? tier}) => stitcher,
              previewTier: null,
            );
            ref.onDispose(() => unawaited(queue.dispose()));
            return queue;
          }),
        ],
      );
      addTearDown(() async {
        await driven.read(stitchQueueProvider).dispose();
        driven.dispose();
      });
    });

    test('a capture enqueued after boot is stitched without a restart',
        () async {
      // Boot the controller and let its initial drain run out over the empty
      // queue — which is exactly the state the bug needed.
      driven.read(stitchJobsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final CaptureFlowController controller =
          driven.read(captureFlowProvider.notifier);
      controller
        ..beginNaming(
          mode: CaptureMode.mobile,
          calibrationId: 'prj-4821-l03',
          levelCode: 'L03',
          now: DateTime(2026, 9, 8, 14, 2),
        )
        ..confirmName()
        ..placeProvisionalPin(const PlanPoint(11.5, 8.25))
        ..confirmStartPin();

      final String sessionId =
          driven.read(captureFlowProvider).draft!.sphereSessionId!;
      final Directory bundleDir =
          driven.read(sphereStorageProvider).bundleDirectory(sessionId);
      await bundleDir.create(recursive: true);

      final CaptureBundle bundle =
          fakeBundle(sessionId: sessionId, directory: bundleDir);
      // The queue reloads the bundle from its manifest before stitching, so the
      // manifest has to be on disk — the real capture session writes it.
      await bundle.save();

      await controller.completeSphereCapture(bundle);

      // The stitch has to start on its own. Nothing here restarts the queue.
      await stitcher.started.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'the queue never worked the entry. `enqueue` does not restart the '
          'drain — the capture path has to call `start()` itself.',
        ),
      );
      expect(stitcher.calls, 1);
    });
  });

  group('retrying a failed stitch', () {
    late SphereCaptureStore store;

    setUp(() async {
      store = container.read(sphereCaptureStoreProvider);
      await store.save(
        'prj-4821-l03',
        CaptureMarker(
          id: 'cap-1',
          at: const PlanPoint(1, 1),
          recordedAt: _when,
          name: 'L03_Mobile_2026-09-08_14',
          mode: CaptureMode.mobile,
          sphereSessionId: 'sphere-1',
          stitch: SphereStitchState.failed,
          stitchError: 'out of memory',
        ),
      );
    });

    test('a retry the queue refuses leaves the pin exactly as it was', () async {
      // Nothing was ever enqueued, so `StitchQueue.retry` returns false. The
      // marker must stay `failed`: flipping it to `stitching` for a retry that
      // never started leaves a badge spinning over the plan that no event will
      // ever clear, and takes the Retry action away with it. The queue is asked
      // before the marker moves, which is what makes that impossible.
      await container.read(stitchJobsProvider.notifier).retry('sphere-1');

      final CaptureMarker marker =
          store.forCalibration('prj-4821-l03').single;
      expect(marker.stitch, SphereStitchState.failed);
      expect(marker.stitchError, 'out of memory');
    });

    test('and it reports the refusal instead of going quiet', () async {
      // The regression guard for a retry that could not work at all: the job
      // map is seeded only from the queue, so after a restart a `failed` marker
      // had no job, and `retry` returned on the first line. The pin offered
      // Retry, the crew tapped it, and nothing happened — no state change, no
      // queue call, no message.
      expect(container.read(stitchJobsProvider), isEmpty);

      await container.read(stitchJobsProvider.notifier).retry('sphere-1');

      final StitchJob? job = container.read(stitchJobsProvider)['sphere-1'];
      expect(job, isNotNull);
      expect(job!.isFailed, isTrue);
      expect(job.captureName, 'L03_Mobile_2026-09-08_14');
      expect(job.calibrationId, 'prj-4821-l03');
      expect(job.statusLine, contains('no longer in the stitch queue'));
    });

    test('an empty session id is not a retry', () async {
      // `_showCapturePreview` passes `sphereSessionId ?? ''`, and a marker with
      // no session id has nothing to retry.
      await container.read(stitchJobsProvider.notifier).retry('');
      expect(container.read(stitchJobsProvider), isEmpty);
    });
  });

  group('the store resolves a level from a session id', () {
    test('which is the only way back for a capture recovered after a kill',
        () async {
      final SphereCaptureStore store =
          container.read(sphereCaptureStoreProvider);
      await store.save(
        'prj-4821-l05',
        CaptureMarker(
          id: 'cap-1',
          at: const PlanPoint(1, 1),
          recordedAt: _when,
          name: 'L05_Mobile_2026-09-08_14',
          mode: CaptureMode.mobile,
          sphereSessionId: 'sphere-1',
        ),
      );

      // The stitch queue persists session ids and nothing else, so without this
      // a resumed capture's upload is attributed to no level at all.
      expect(store.calibrationOf('sphere-1'), 'prj-4821-l05');
      expect(store.calibrationOf('sphere-unknown'), isNull);
    });
  });

  group('storage layout', () {
    test('the panorama lives outside the bundle it came from', () {
      final SphereStorage layout = container.read(sphereStorageProvider);
      final String panorama = layout.panoramaPath('sphere-1');
      final Directory bundle = layout.bundleDirectory('sphere-1');

      // The package's storage policy deletes a bundle once its stitch met its
      // quality targets. A panorama written inside it would go with it.
      expect(panorama.startsWith(bundle.path), isFalse);
    });
  });
}

/// A fixed instant, so a persisted timestamp can be asserted exactly.
final DateTime _when = DateTime.utc(2026, 9, 8, 14, 2);

/// A stitcher that never touches the native library.
///
/// It records that the queue reached it, which is the whole assertion: the
/// question is whether anything drives the drain, not what the pipeline does.
class _FakeStitcher extends SphereStitcher {
  final Completer<void> started = Completer<void>();
  int calls = 0;

  @override
  Future<StitchResult> stitch(
    CaptureBundle bundle, {
    void Function(StitchProgress progress)? onProgress,
    String? outputPath,
    PanoramaMetadata? metadata,
  }) async {
    calls += 1;
    if (!started.isCompleted) started.complete();
    onProgress?.call(
      const StitchProgress(stage: StitchStage.encoding, fraction: 1),
    );
    throw StateError('fake stitcher: not producing a panorama');
  }
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
  Future<void> updateCapture(
    String calibrationId,
    CaptureMarker capture,
  ) async {
    final int index =
        savedCaptures.indexWhere((CaptureMarker c) => c.id == capture.id);
    if (index >= 0) savedCaptures[index] = capture;
  }

  @override
  Future<void> saveTrajectory(String c, Trajectory trajectory) async {
    savedTrajectories.add(trajectory);
  }

  @override
  Future<LevelWorkspaceData> fetchWorkspace(String calibrationId) {
    throw UnimplementedError('not needed for capture-path tests');
  }
}
