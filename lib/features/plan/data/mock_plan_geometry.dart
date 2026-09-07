import 'dart:math' as math;

import '../models/plan_document.dart';
import '../models/plan_space.dart';

/// A stand-in floor plan, drawn in code.
///
/// This exists because the prototype's plan is itself a synthetic drawing and
/// "real plan raster import" is listed as a next step on page 1 — so there is
/// no artwork to import yet. The shape follows the deck's Level 03 drawing:
/// a slab with a stair core and a shaft top-right, three zones, a structural
/// grid lettered A–D by row and numbered 1–3 by column.
///
/// Coordinates are metres. The sheet is 26 m × 32 m, which matches the aspect
/// ratio of the plan sheet drawn in the prototype.
///
/// When Asite confirms the bundle format, this file is deleted and the
/// repository returns a [RasterPlanSource] instead. Nothing else changes.
abstract final class MockPlanGeometry {
  static const double sheetWidth = 26;
  static const double sheetHeight = 32;

  /// Rows A–D run horizontally; columns 1–3 run vertically.
  ///
  /// The spacing here is what makes `PlanGrid.referenceFor` return **B-2** for
  /// the scaffold-strike issue, matching the reference printed on the deck's
  /// Site Issues screen.
  static const PlanGrid grid = PlanGrid(
    columnOrigin: 5,
    columnSpacing: 6.5,
    columnCount: 3,
    rowOrigin: 6,
    rowSpacing: 7.5,
    rowCount: 4,
  );

  /// The slab edge.
  static const List<PlanPoint> outline = <PlanPoint>[
    PlanPoint(3.5, 3),
    PlanPoint(22.5, 3),
    PlanPoint(22.5, 31),
    PlanPoint(3.5, 31),
    PlanPoint(3.5, 3),
  ];

  static PlanDocument document() {
    return const PlanDocument(
      widthMetres: sheetWidth,
      heightMetres: sheetHeight,
      grid: grid,
      outline: outline,
      source: GeometryPlanSource(_geometry),
    );
  }

  static const PlanGeometry _geometry = PlanGeometry(
    walls: <PlanPolyline>[
      // Top-left room.
      PlanPolyline(<PlanPoint>[PlanPoint(9.5, 3), PlanPoint(9.5, 12)]),
      PlanPolyline(<PlanPoint>[PlanPoint(3.5, 12), PlanPoint(12.2, 12)]),
      // Corridor spine across the B grid line.
      PlanPolyline(<PlanPoint>[PlanPoint(14.4, 12), PlanPoint(22.5, 12)]),
      PlanPolyline(<PlanPoint>[PlanPoint(14.4, 12), PlanPoint(14.4, 8)]),
      PlanPolyline(<PlanPoint>[PlanPoint(14.4, 8), PlanPoint(22.5, 8)]),
      // Lower zones.
      PlanPolyline(<PlanPoint>[PlanPoint(9.5, 19), PlanPoint(22.5, 19)]),
      PlanPolyline(<PlanPoint>[PlanPoint(9.5, 19), PlanPoint(9.5, 31)]),
      PlanPolyline(<PlanPoint>[PlanPoint(16.5, 19), PlanPoint(16.5, 31)]),
    ],
    columns: <PlanPoint>[
      PlanPoint(5, 6),
      PlanPoint(11.5, 6),
      PlanPoint(18, 6),
      PlanPoint(5, 13.5),
      PlanPoint(11.5, 13.5),
      PlanPoint(18, 13.5),
      PlanPoint(5, 21),
      PlanPoint(11.5, 21),
      PlanPoint(18, 21),
      PlanPoint(5, 28.5),
      PlanPoint(11.5, 28.5),
      PlanPoint(18, 28.5),
    ],
    stairs: <PlanRect>[
      PlanRect(PlanPoint(16.5, 3.4), PlanPoint(22.1, 8)),
    ],
    voids: <PlanRect>[
      PlanRect(PlanPoint(17.2, 9.6), PlanPoint(21.4, 13.4)),
    ],
    doors: <PlanDoor>[
      // The swing drawn between the top-left room and the corridor.
      PlanDoor(
        hinge: PlanPoint(12.2, 12),
        radius: 2.2,
        startAngle: -math.pi / 2,
        sweep: math.pi / 2,
      ),
    ],
    labels: <PlanLabel>[
      PlanLabel(PlanPoint(6.4, 16.4), 'ZONE A'),
      PlanLabel(PlanPoint(17.6, 16.4), 'ZONE B'),
      PlanLabel(PlanPoint(13.2, 24.6), 'ZONE C'),
    ],
  );
}
