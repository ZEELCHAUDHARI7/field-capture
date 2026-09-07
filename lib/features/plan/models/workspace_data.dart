import 'package:flutter/foundation.dart';

import 'plan_document.dart';
import 'plan_marker.dart';
import 'trajectory.dart';

/// One entry on the level rail.
@immutable
class WorkspaceLevel {
  const WorkspaceLevel({
    required this.calibrationId,
    required this.code,
    required this.name,
    required this.order,
    required this.isAvailableOffline,
  });

  final String calibrationId;

  /// "B1", "L01", "L03", "L05" — what the rail shows.
  final String code;

  /// "Level 03 – Slab".
  final String name;

  /// Basement first, then rising. Drives rail order.
  final int order;

  /// A level whose bundle is not downloaded cannot be opened — the same rule
  /// the calibration list enforces.
  final bool isAvailableOffline;
}

/// Everything the Level Workspace needs, fetched in one call.
///
/// One call rather than four, because the screen is useless without all of it
/// and a site connection is the scarce resource.
@immutable
class LevelWorkspaceData {
  const LevelWorkspaceData({
    required this.calibrationId,
    required this.levelName,
    required this.levelCode,
    required this.projectName,
    required this.document,
    required this.levels,
    required this.captures,
    required this.issues,
    required this.trajectories,
    required this.hasModel,
  });

  final String calibrationId;

  /// "Level 03 – Slab" — the app bar title.
  final String levelName;

  /// "L03" — used in capture names.
  final String levelCode;

  /// "Riverside Quarter — Tower B" — the app bar subtitle.
  final String projectName;

  final PlanDocument document;

  /// Every level of this project, for the rail.
  final List<WorkspaceLevel> levels;

  final List<CaptureMarker> captures;
  final List<IssueMarker> issues;
  final List<Trajectory> trajectories;

  /// "Only levels with a model offer the 3D entry point" — stated.
  final bool hasModel;
}
