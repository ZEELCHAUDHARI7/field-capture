import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../plan/models/plan_marker.dart';
import '../../plan/models/plan_space.dart';
import '../../plan/models/trajectory.dart';

/// Where a capture is in its life.
///
/// The prototype spreads one flow across six drawn states (naming, start pin,
/// recording, waypoint, end pin, mobile sweep) that all belong to a single
/// capture. Making that flow an explicit machine — rather than leaving it
/// implicit in navigation — is the thing that stops half-recorded walks from
/// leaking between screens.
///
/// Legal transitions:
///
///   idle ──beginNaming──▶ naming ──confirmName──▶ pinningStart
///                            │                        │
///                         cancel                   cancel
///                            ▼                        ▼
///                          idle                     idle
///
///   pinningStart ──confirm──▶  video  : recording
///                              image  : saving
///                              mobile : sphereCapture
///
///   recording ──requestWaypoint──▶ pinningWaypoint ──confirm/cancel──▶ recording
///   recording ──stopWalking──────▶ pinningEnd ──confirmEndPin──▶ saving ──▶ idle
///   sphereCapture ──(bundle saved)──▶ saving ──▶ idle
///   any ──discard──▶ idle
enum CapturePhase {
  idle,

  /// The naming sheet is open over the plan.
  naming,

  /// "Zoom in and tap the exact point where recording begins."
  pinningStart,

  /// Full-screen camera chrome; the timer is running.
  recording,

  /// Back on the plan mid-walk. Recording continues.
  pinningWaypoint,

  /// "Walk finished — tap the point where you stopped."
  pinningEnd,

  /// The real guided sphere capture, owned by `sphere_view`: coaching, then
  /// the ~29-position guided capture, then its review screen. Nothing about the
  /// progress of it is state here — the package's session reports it.
  sphereCapture,

  /// A 360° still is framed and shot. The deck names Image on the dock but
  /// draws no shooting step for it — ASSUMPTIONS.md §G9.
  shooting,

  /// Writing to the local store and the upload queue.
  saving;

  /// Phases where the workspace collapses its chrome and the plan takes over.
  bool get isPinning =>
      this == CapturePhase.pinningStart ||
      this == CapturePhase.pinningWaypoint ||
      this == CapturePhase.pinningEnd;

  bool get isActive => this != CapturePhase.idle;
}

/// The capture being assembled. One at a time — a crew records one walk.
@immutable
class CaptureDraft {
  const CaptureDraft({
    required this.mode,
    required this.calibrationId,
    required this.levelCode,
    required this.name,
    this.startPin,
    this.waypoints = const <PlanPoint>[],
    this.endPin,
    this.provisionalPin,
    this.startedAt,
    this.elapsed = Duration.zero,
    this.sphereSessionId,
  });

  final CaptureMode mode;
  final String calibrationId;
  final String levelCode;

  /// `L03_Img_2026-07-03_13` — pre-filled, editable in the naming sheet.
  final String name;

  final PlanPoint? startPin;
  final List<PlanPoint> waypoints;
  final PlanPoint? endPin;

  /// The crosshair the user has tapped but not confirmed. "Crosshair plus a
  /// confirm button rather than tap-to-place, so a mis-tap costs nothing."
  final PlanPoint? provisionalPin;

  /// Wall-clock start. Elapsed is derived from this rather than counted, so
  /// "recording survives the app going background — the timer is authoritative".
  final DateTime? startedAt;

  final Duration elapsed;

  /// The `sphere_view` session id, minted when the pin is confirmed.
  ///
  /// It is the draft's business rather than the capture screen's because it
  /// names the bundle directory on disk, and a directory that outlives the
  /// screen has to be identified by something that was decided before the
  /// screen opened — that is what makes a capture the app was killed during
  /// findable afterwards.
  final String? sphereSessionId;

  /// The number the waypoint banner announces next.
  int get nextWaypointNumber => waypoints.length + 1;

  /// The trail drawn on the plan while the walk is in progress.
  Trajectory? get liveTrajectory {
    if (startPin == null) return null;
    return Trajectory(
      id: 'draft',
      name: name,
      recordedAt: startedAt ?? DateTime.now(),
      lengthMetres: pathLengthMetres,
      nodes: <TrajectoryNode>[
        TrajectoryNode(kind: TrajectoryNodeKind.start, at: startPin!),
        for (int i = 0; i < waypoints.length; i++)
          TrajectoryNode(
            kind: TrajectoryNodeKind.waypoint,
            at: waypoints[i],
            sequence: i + 1,
          ),
        if (endPin != null)
          TrajectoryNode(kind: TrajectoryNodeKind.end, at: endPin!),
      ],
    );
  }

  /// Straight-line distance through the placed pins. The real figure would
  /// come from the camera's own track; this is the best the plan can say.
  double get pathLengthMetres {
    final List<PlanPoint> path = <PlanPoint>[
      if (startPin != null) startPin!,
      ...waypoints,
      if (endPin != null) endPin!,
    ];
    double total = 0;
    for (int i = 0; i < path.length - 1; i++) {
      final double dx = path[i + 1].x - path[i].x;
      final double dy = path[i + 1].y - path[i].y;
      total += math.sqrt(dx * dx + dy * dy);
    }
    return total;
  }

  CaptureDraft copyWith({
    String? name,
    PlanPoint? startPin,
    List<PlanPoint>? waypoints,
    PlanPoint? endPin,
    PlanPoint? provisionalPin,
    bool clearProvisionalPin = false,
    DateTime? startedAt,
    Duration? elapsed,
    String? sphereSessionId,
  }) {
    return CaptureDraft(
      mode: mode,
      calibrationId: calibrationId,
      levelCode: levelCode,
      name: name ?? this.name,
      startPin: startPin ?? this.startPin,
      waypoints: waypoints ?? this.waypoints,
      endPin: endPin ?? this.endPin,
      provisionalPin:
          clearProvisionalPin ? null : (provisionalPin ?? this.provisionalPin),
      startedAt: startedAt ?? this.startedAt,
      elapsed: elapsed ?? this.elapsed,
      sphereSessionId: sphereSessionId ?? this.sphereSessionId,
    );
  }
}

/// The controller's whole state: a phase, and the draft it applies to.
@immutable
class CaptureFlow {
  const CaptureFlow({required this.phase, this.draft});

  const CaptureFlow.idle()
      : phase = CapturePhase.idle,
        draft = null;

  final CapturePhase phase;
  final CaptureDraft? draft;

  bool get isActive => phase.isActive;

  /// True when this flow belongs to the calibration currently on screen.
  bool ownedBy(String calibrationId) =>
      draft != null && draft!.calibrationId == calibrationId;
}
