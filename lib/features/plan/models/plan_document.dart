import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'plan_space.dart';

/// Where the plan artwork comes from.
///
/// This is the swap point named in ASSUMPTIONS.md §B2. The prototype's plan is
/// a synthetic drawing and "real plan raster import" is listed as a next step,
/// so Phase 2 ships [GeometryPlanSource]. When Asite confirms the bundle
/// format, add the real source here — the painter switches on this type and
/// nothing else in the app changes.
sealed class PlanSource {
  const PlanSource();
}

/// The assumed production source (decision D3): a raster shipped inside the
/// calibration bundle, positioned by the plan-space transform.
class RasterPlanSource extends PlanSource {
  const RasterPlanSource(this.image);
  final ui.Image image;
}

/// Phase 2 stand-in: vector primitives drawn in code, shaped like the
/// prototype's floor plan so the workspace can be built and reviewed before
/// the bundle format is settled.
class GeometryPlanSource extends PlanSource {
  const GeometryPlanSource(this.geometry);
  final PlanGeometry geometry;
}

/// One calibrated level: its extent, its structural grid, and its artwork.
@immutable
class PlanDocument {
  const PlanDocument({
    required this.widthMetres,
    required this.heightMetres,
    required this.grid,
    required this.source,
    required this.outline,
  });

  final double widthMetres;
  final double heightMetres;
  final PlanGrid grid;
  final PlanSource source;

  /// The slab edge. Drawn heavier than interior walls.
  final List<PlanPoint> outline;

  ui.Size get size => ui.Size(widthMetres, heightMetres);
}

/// Vector primitives for [GeometryPlanSource].
@immutable
class PlanGeometry {
  const PlanGeometry({
    this.walls = const <PlanPolyline>[],
    this.columns = const <PlanPoint>[],
    this.stairs = const <PlanRect>[],
    this.voids = const <PlanRect>[],
    this.doors = const <PlanDoor>[],
    this.labels = const <PlanLabel>[],
  });

  final List<PlanPolyline> walls;

  /// Structural columns, drawn as filled squares.
  final List<PlanPoint> columns;

  /// Stair cores — a rectangle with treads.
  final List<PlanRect> stairs;

  /// Shafts and voids — a rectangle crossed through.
  final List<PlanRect> voids;

  final List<PlanDoor> doors;

  /// Zone names — "ZONE C".
  final List<PlanLabel> labels;
}

@immutable
class PlanPolyline {
  const PlanPolyline(this.points);
  final List<PlanPoint> points;
}

@immutable
class PlanRect {
  const PlanRect(this.topLeft, this.bottomRight);
  final PlanPoint topLeft;
  final PlanPoint bottomRight;

  double get width => bottomRight.x - topLeft.x;
  double get height => bottomRight.y - topLeft.y;
}

/// A door swing: a quarter-arc hinged at [hinge].
@immutable
class PlanDoor {
  const PlanDoor({
    required this.hinge,
    required this.radius,
    required this.startAngle,
    required this.sweep,
  });

  final PlanPoint hinge;
  final double radius;

  /// Radians, measured as Canvas measures them.
  final double startAngle;
  final double sweep;
}

@immutable
class PlanLabel {
  const PlanLabel(this.at, this.text);
  final PlanPoint at;
  final String text;
}
