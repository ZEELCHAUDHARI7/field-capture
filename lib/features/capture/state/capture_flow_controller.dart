import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../plan/data/plan_repository.dart';
import '../../plan/models/plan_marker.dart';
import '../../plan/models/plan_space.dart';
import '../../plan/models/trajectory.dart';
import '../../plan/state/workspace_controller.dart';
import '../../uploads/state/upload_queue_controller.dart';
import '../models/capture_draft.dart';
import '../models/capture_naming.dart';

/// Owns the whole capture flow, across three routes and six drawn states.
///
/// Every transition goes through a method here, and every method checks the
/// phase it is leaving. Screens read the phase and render; they never mutate
/// the draft themselves. That is what keeps a half-recorded walk from leaking
/// when the user backs out of a route.
class CaptureFlowController extends Notifier<CaptureFlow> {
  Timer? _ticker;
  Timer? _sweep;

  /// The four guided steps of a mobile sweep. Only the first is drawn in the
  /// prototype; the deck shows four step dots, so there are four steps.
  /// ASSUMPTIONS.md §G4.
  static const List<String> mobileSteps = <String>[
    'Sweep up — floor to ceiling',
    'Sweep down — ceiling to floor',
    'Rotate left — hold the phone steady',
    'Rotate right — close the sphere',
  ];

  @override
  CaptureFlow build() {
    ref.onDispose(_stopTimers);
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
        state = CaptureFlow(
          phase: CapturePhase.mobileSweep,
          draft: placed.copyWith(startedAt: DateTime.now()),
        );
        _startSweep();
      case CaptureMode.image:
        // A 360° still is pin, shoot, save — the prototype draws no shooting
        // screen for it. ASSUMPTIONS.md §C7 is still open.
        state = CaptureFlow(phase: CapturePhase.saving, draft: placed);
        unawaited(_commit());
    }
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

  /// Cancel from the naming sheet or a pin mode, and Discard from recording.
  /// "Cancel returns to the dock with nothing recorded."
  void discard() {
    _stopTimers();
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

  /// PHASE 3 MOCK. A real sweep advances on what the phone's camera and LiDAR
  /// actually see; there is no device sensor behind this, so progress runs on a
  /// timer. ASSUMPTIONS.md §G4.
  void _startSweep() {
    _sweep?.cancel();
    _sweep = Timer.periodic(const Duration(milliseconds: 260), (_) {
      final CaptureDraft? draft = state.draft;
      if (draft == null || state.phase != CapturePhase.mobileSweep) return;

      final double next = (draft.mobileProgress + 0.02).clamp(0.0, 1.0);
      final int step =
          (next * mobileSteps.length).floor().clamp(0, mobileSteps.length - 1);

      if (next >= 1) {
        _sweep?.cancel();
        state = CaptureFlow(
          phase: CapturePhase.saving,
          draft: draft.copyWith(mobileProgress: 1, mobileStep: step),
        );
        unawaited(_commit());
        return;
      }

      state = CaptureFlow(
        phase: CapturePhase.mobileSweep,
        draft: draft.copyWith(mobileProgress: next, mobileStep: step),
      );
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _stopTimers() {
    _stopTicker();
    _sweep?.cancel();
    _sweep = null;
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

    _stopTimers();
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

  /// PHASE 3 MOCK. Real sizes come from the camera. These are scaled from the
  /// figures the prototype's upload queue shows: ~36 MB per minute of 360°
  /// video, 28 MB per still, 46 MB per mobile sphere.
  int _estimateSize(CaptureDraft draft) => switch (draft.mode) {
        CaptureMode.video =>
          (36 * 1000 * 1000 * (draft.elapsed.inSeconds / 60).clamp(0.2, 60))
              .round(),
        CaptureMode.image => 28 * 1000 * 1000,
        CaptureMode.mobile => 46 * 1000 * 1000,
      };
}

/// Whether this phone can run Mobile Capture.
///
/// The prototype says the mode is "gated on device capability, with a clear
/// message when unsupported", but never draws that message and names no
/// capability test. Nothing here queries the device — override this provider
/// to see the unsupported screen. ASSUMPTIONS.md §G7.
final mobileCaptureSupportedProvider = Provider<bool>((ref) => true);

final captureFlowProvider =
    NotifierProvider<CaptureFlowController, CaptureFlow>(
  CaptureFlowController.new,
);
