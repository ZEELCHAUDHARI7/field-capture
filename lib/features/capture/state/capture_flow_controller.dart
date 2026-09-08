import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sphere_view/sphere_view.dart';

import '../../plan/data/plan_repository.dart';
import '../../plan/models/plan_marker.dart';
import '../../plan/models/plan_space.dart';
import '../../plan/models/trajectory.dart';
import '../../plan/state/workspace_controller.dart';
import '../../uploads/state/upload_queue_controller.dart';
import '../models/capture_draft.dart';
import '../models/capture_naming.dart';
import 'stitch_queue_controller.dart';

/// Owns the whole capture flow, across three routes and six drawn states.
///
/// Every transition goes through a method here, and every method checks the
/// phase it is leaving. Screens read the phase and render; they never mutate
/// the draft themselves. That is what keeps a half-recorded walk from leaking
/// when the user backs out of a route.
class CaptureFlowController extends Notifier<CaptureFlow> {
  Timer? _ticker;

  @override
  CaptureFlow build() {
    ref.onDispose(_stopTicker);
    return const CaptureFlow.idle();
  }

  // ---------------------------------------------------------------------------
  // Naming
  // ---------------------------------------------------------------------------

  /// Opens the naming sheet. "Every capture is named before it starts."
  void beginNaming({
    required CaptureMode mode,
    required String calibrationId,
    required String levelCode,
    Iterable<String> existingNames = const <String>[],
    DateTime? now,
  }) {
    if (state.isActive) return;

    state = CaptureFlow(
      phase: CapturePhase.naming,
      draft: CaptureDraft(
        mode: mode,
        calibrationId: calibrationId,
        levelCode: levelCode,
        name: CaptureNaming.build(
          levelCode: levelCode,
          mode: mode,
          now: now ?? DateTime.now(),
          existingNames: existingNames,
        ),
      ),
    );
  }

  void rename(String name) {
    final CaptureDraft? draft = state.draft;
    if (draft == null || state.phase != CapturePhase.naming) return;
    state = CaptureFlow(phase: state.phase, draft: draft.copyWith(name: name));
  }

  /// "Next — pin location".
  void confirmName() {
    final CaptureDraft? draft = state.draft;
    if (draft == null || state.phase != CapturePhase.naming) return;
    if (CaptureNaming.validate(draft.name) != null) return;

    state = CaptureFlow(
      phase: CapturePhase.pinningStart,
      draft: draft.copyWith(name: draft.name.trim()),
    );
  }

  // ---------------------------------------------------------------------------
  // Pin modes
  // ---------------------------------------------------------------------------

  /// A tap on the plan drops the crosshair. Nothing is committed until the
  /// confirm button is pressed, "so a mis-tap costs nothing".
  void placeProvisionalPin(PlanPoint point) {
    final CaptureDraft? draft = state.draft;
    if (draft == null || !state.phase.isPinning) return;
    state = CaptureFlow(
      phase: state.phase,
      draft: draft.copyWith(provisionalPin: point),
    );
  }

  /// "Start Walking" for video; the equivalent confirm for the other modes.
  void confirmStartPin() {
    final CaptureDraft? draft = state.draft;
    if (draft == null || state.phase != CapturePhase.pinningStart) return;
    final PlanPoint? pin = draft.provisionalPin;
    if (pin == null) return;

    final CaptureDraft placed =
        draft.copyWith(startPin: pin, clearProvisionalPin: true);

    switch (draft.mode) {
      case CaptureMode.video:
        state = CaptureFlow(
          phase: CapturePhase.recording,
          draft: placed.copyWith(startedAt: DateTime.now()),
        );
        _startTicker();
      case CaptureMode.mobile:
        // The session id is minted here, before the capture screen opens,
        // because it names the bundle directory on disk. A capture the app is
        // killed during is only findable afterwards if the name of the folder
        // it was writing into was decided before it started.
        state = CaptureFlow(
          phase: CapturePhase.sphereCapture,
          draft: placed.copyWith(
            startedAt: DateTime.now(),
            sphereSessionId: 'sphere-${DateTime.now().microsecondsSinceEpoch}',
          ),
        );
      case CaptureMode.image:
        state = CaptureFlow(
          phase: CapturePhase.shooting,
          draft: placed.copyWith(startedAt: DateTime.now()),
        );
    }
  }

  /// The shutter on the Image screen.
  ///
  /// Image used to go straight from the pin to saved, so the mode named on the
  /// deck's own dock had no screen behind it. The deck draws no shooting step,
  /// so this is the smallest honest one: frame, shoot, save. ASSUMPTIONS.md §G9.
  void captureStill() {
    final CaptureDraft? draft = state.draft;
    if (draft == null || state.phase != CapturePhase.shooting) return;
    state = CaptureFlow(phase: CapturePhase.saving, draft: draft);
    unawaited(_commit());
  }

  /// "Waypoint" on the recording screen. Recording continues throughout.
  void requestWaypoint() {
    final CaptureDraft? draft = state.draft;
    if (draft == null || state.phase != CapturePhase.recording) return;
    state = CaptureFlow(phase: CapturePhase.pinningWaypoint, draft: draft);
  }

  /// "Back to recording — no waypoint".
  void cancelWaypoint() {
    final CaptureDraft? draft = state.draft;
    if (draft == null || state.phase != CapturePhase.pinningWaypoint) return;
    state = CaptureFlow(
      phase: CapturePhase.recording,
      draft: draft.copyWith(clearProvisionalPin: true),
    );
  }

  void confirmWaypoint() {
    final CaptureDraft? draft = state.draft;
    if (draft == null || state.phase != CapturePhase.pinningWaypoint) return;
    final PlanPoint? pin = draft.provisionalPin;
    if (pin == null) return;

    state = CaptureFlow(
      phase: CapturePhase.recording,
      draft: draft.copyWith(
        waypoints: <PlanPoint>[...draft.waypoints, pin],
        clearProvisionalPin: true,
      ),
    );
  }

  /// "Stop Walking" — the walk closes and asks for its end pin.
  void stopWalking() {
    final CaptureDraft? draft = state.draft;
    if (draft == null || state.phase != CapturePhase.recording) return;
    _stopTicker();
    state = CaptureFlow(phase: CapturePhase.pinningEnd, draft: draft);
  }

  /// "Save capture" — the only place the full path is confirmed.
  void confirmEndPin() {
    final CaptureDraft? draft = state.draft;
    if (draft == null || state.phase != CapturePhase.pinningEnd) return;
    final PlanPoint? pin = draft.provisionalPin;
    if (pin == null) return;

    state = CaptureFlow(
      phase: CapturePhase.saving,
      draft: draft.copyWith(endPin: pin, clearProvisionalPin: true),
    );
    unawaited(_commit());
  }

  // ---------------------------------------------------------------------------
  // The sphere capture
  // ---------------------------------------------------------------------------

  /// The guided capture finished and the operator kept it.
  ///
  /// Three things happen, and none of them waits for a stitch: the pin is
  /// written to the plan in its `stitching` state, the bundle goes in the
  /// queue, and the flow goes idle so the crew can walk to the next station.
  ///
  /// Awaiting the stitch here would still work — the panoramas would come out,
  /// correct, in order, with the user standing still between them. That failure
  /// is invisible in a test and obvious on a site, which is why
  /// `test/stitch_queue_test.dart` pins it.
  Future<void> completeSphereCapture(CaptureBundle bundle) async {
    final CaptureDraft? draft = state.draft;
    if (draft == null || state.phase != CapturePhase.sphereCapture) return;
    final PlanPoint? at = draft.startPin;
    if (at == null) return;

    state = CaptureFlow(phase: CapturePhase.saving, draft: draft);

    final CaptureMarker marker = CaptureMarker(
      id: 'cap-${DateTime.now().microsecondsSinceEpoch}',
      at: at,
      recordedAt: draft.startedAt ?? DateTime.now(),
      name: draft.name,
      mode: draft.mode,
      sphereSessionId: bundle.sessionId,
      stitch: SphereStitchState.stitching,
    );

    await ref.read(planRepositoryProvider).saveCapture(
          draft.calibrationId,
          marker,
        );

    await ref.read(stitchJobsProvider.notifier).enqueue(
          bundle: bundle,
          captureName: draft.name,
          calibrationId: draft.calibrationId,
        );

    // The pin is on the plan from here. The upload is enqueued when the stitch
    // lands, because that is the first moment the real byte count exists.
    ref.invalidate(workspaceDataProvider(draft.calibrationId));
    state = const CaptureFlow.idle();
  }

  /// Cancel from the naming sheet or a pin mode, and Discard from recording.
  /// "Cancel returns to the dock with nothing recorded."
  void discard() {
    _stopTicker();
    state = const CaptureFlow.idle();
  }

  // ---------------------------------------------------------------------------
  // Timers
  // ---------------------------------------------------------------------------

  /// Elapsed is recomputed from the wall clock rather than incremented, so a
  /// backgrounded app resumes with the right figure — "the timer is
  /// authoritative".
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final CaptureDraft? draft = state.draft;
      final DateTime? startedAt = draft?.startedAt;
      if (draft == null || startedAt == null) return;
      if (state.phase != CapturePhase.recording &&
          state.phase != CapturePhase.pinningWaypoint) {
        return;
      }
      state = CaptureFlow(
        phase: state.phase,
        draft: draft.copyWith(elapsed: DateTime.now().difference(startedAt)),
      );
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  // ---------------------------------------------------------------------------
  // Commit
  // ---------------------------------------------------------------------------

  /// Writes the capture to the calibration's local store and pushes it onto the
  /// upload queue. Nothing here touches the network: "nothing in the capture
  /// path requires a round trip to Asite".
  Future<void> _commit() async {
    final CaptureDraft? draft = state.draft;
    if (draft == null) return;

    _stopTicker();
    final PlanRepository repository = ref.read(planRepositoryProvider);

    if (draft.mode == CaptureMode.video) {
      final Trajectory? trajectory = draft.liveTrajectory;
      if (trajectory != null) {
        await repository.saveTrajectory(
          draft.calibrationId,
          Trajectory(
            id: 'traj-${DateTime.now().microsecondsSinceEpoch}',
            name: draft.name,
            nodes: trajectory.nodes,
            recordedAt: draft.startedAt ?? DateTime.now(),
            lengthMetres: draft.pathLengthMetres,
          ),
        );
      }
    } else {
      final PlanPoint? at = draft.startPin;
      if (at != null) {
        await repository.saveCapture(
          draft.calibrationId,
          CaptureMarker(
            id: 'cap-${DateTime.now().microsecondsSinceEpoch}',
            at: at,
            recordedAt: draft.startedAt ?? DateTime.now(),
            name: draft.name,
            mode: draft.mode,
          ),
        );
      }
    }

    ref.read(uploadQueueProvider.notifier).enqueue(
          name: draft.name,
          calibrationId: draft.calibrationId,
          mode: draft.mode,
          sizeBytes: _estimateSize(draft),
          duration: draft.mode == CaptureMode.video ? draft.elapsed : null,
        );

    // Bring the new pin onto the plan.
    ref.invalidate(workspaceDataProvider(draft.calibrationId));

    state = const CaptureFlow.idle();
  }

  /// PHASE 3 MOCK, for the two modes that still are one. Real sizes come from
  /// the camera. These are scaled from the figures the prototype's upload queue
  /// shows: ~36 MB per minute of 360° video, 28 MB per still.
  ///
  /// Mobile Capture is no longer here: a stitched panorama is a file, and the
  /// queue is given its actual length in
  /// `StitchJobsController._onStitched`.
  int _estimateSize(CaptureDraft draft) => switch (draft.mode) {
        CaptureMode.video =>
          (36 * 1000 * 1000 * (draft.elapsed.inSeconds / 60).clamp(0.2, 60))
              .round(),
        CaptureMode.image => 28 * 1000 * 1000,
        CaptureMode.mobile => 0,
      };
}

final captureFlowProvider =
    NotifierProvider<CaptureFlowController, CaptureFlow>(
  CaptureFlowController.new,
);
