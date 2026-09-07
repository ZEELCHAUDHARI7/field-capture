import 'package:flutter/foundation.dart';

import 'plan_space.dart';

/// One node on a recorded walk.
enum TrajectoryNodeKind {
  /// The pin dropped before recording started.
  start,

  /// Dropped mid-walk to mark where the crew actually was.
  waypoint,

  /// Dropped when the walk was closed.
  end,
}

@immutable
class TrajectoryNode {
  const TrajectoryNode({
    required this.kind,
    required this.at,
    this.sequence,
  });

  final TrajectoryNodeKind kind;
  final PlanPoint at;

  /// 1, 2, 3… for waypoints. Null for start and end, which are drawn S and E.
  final int? sequence;

  String get label => switch (kind) {
        TrajectoryNodeKind.start => 'S',
        TrajectoryNodeKind.end => 'E',
        TrajectoryNodeKind.waypoint => '${sequence ?? 0}',
      };
}

/// A recorded 360° video walk: an ordered path across the plan.
///
/// "Waypoints are what make the trajectory reconstructable later" — so the
/// nodes are the record, and the dashed trail between them is derived.
@immutable
class Trajectory {
  const Trajectory({
    required this.id,
    required this.name,
    required this.nodes,
    required this.recordedAt,
    required this.lengthMetres,
  });

  final String id;

  /// `L03_Walk_2026-07-03_09`.
  final String name;

  /// Ordered start → waypoints → end. A partial walk may have no end node.
  final List<TrajectoryNode> nodes;

  final DateTime recordedAt;

  /// "23 m" on the 3D trajectory picker.
  final double lengthMetres;

  int get waypointCount => nodes
      .where((TrajectoryNode n) => n.kind == TrajectoryNodeKind.waypoint)
      .length;

  List<PlanPoint> get path =>
      nodes.map((TrajectoryNode n) => n.at).toList(growable: false);
}
