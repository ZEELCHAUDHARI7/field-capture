import 'dart:ui';

import 'package:flutter/foundation.dart';

/// A point in **plan space** — metres from the plan's top-left origin.
///
/// The prototype is explicit about this: "Pin coordinates are plan-space, so
/// they survive zoom and pan." Nothing in this app stores a pin in screen
/// pixels; [PlanTransform] converts, in both directions, at paint time.
@immutable
class PlanPoint {
  const PlanPoint(this.x, this.y);

  /// Metres east of the plan origin.
  final double x;

  /// Metres south of the plan origin.
  final double y;

  PlanPoint operator +(PlanPoint other) =>
      PlanPoint(x + other.x, y + other.y);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlanPoint && other.x == x && other.y == y);

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'PlanPoint(${x.toStringAsFixed(2)}, '
      '${y.toStringAsFixed(2)})';
}

/// The structural grid printed on the calibration, and the thing that turns a
/// pin into a human reference like `B-2`.
///
/// The prototype states the reference is "derived from the pin, not typed by
/// the user", but never says how. ASSUMED: lettered rows run horizontally,
/// numbered columns run vertically, both evenly spaced, and a point takes the
/// label of the nearest gridline in each axis. See ASSUMPTIONS.md §B3.
@immutable
class PlanGrid {
  const PlanGrid({
    required this.columnOrigin,
    required this.columnSpacing,
    required this.columnCount,
    required this.rowOrigin,
    required this.rowSpacing,
    required this.rowCount,
  });

  /// x of column 1, in metres.
  final double columnOrigin;
  final double columnSpacing;
  final int columnCount;

  /// y of row A, in metres.
  final double rowOrigin;
  final double rowSpacing;
  final int rowCount;

  double columnX(int index) => columnOrigin + columnSpacing * index;

  double rowY(int index) => rowOrigin + rowSpacing * index;

  /// "A", "B", "C"… for rows.
  String rowLabel(int index) => String.fromCharCode(65 + index);

  /// "1", "2", "3"… for columns.
  String columnLabel(int index) => '${index + 1}';

  /// The grid reference nearest to [point] — "B-2".
  String referenceFor(PlanPoint point) {
    final int column = _nearestIndex(
      value: point.x,
      origin: columnOrigin,
      spacing: columnSpacing,
      count: columnCount,
    );
    final int row = _nearestIndex(
      value: point.y,
      origin: rowOrigin,
      spacing: rowSpacing,
      count: rowCount,
    );
    return '${rowLabel(row)}-${columnLabel(column)}';
  }

  static int _nearestIndex({
    required double value,
    required double origin,
    required double spacing,
    required int count,
  }) {
    final int raw = ((value - origin) / spacing).round();
    return raw.clamp(0, count - 1);
  }
}

/// Maps plan metres to canvas pixels and back.
///
/// Contain-fit with a margin, aligned to the top of the viewport — which is how
/// the prototype frames the plan sheet, with grey showing below it rather than
/// the sheet floating in the middle.
@immutable
class PlanTransform {
  const PlanTransform({required this.scale, required this.origin});

  /// Pixels per metre.
  final double scale;

  /// Canvas position of the plan's (0, 0).
  final Offset origin;

  factory PlanTransform.fit({
    required Size viewport,
    required Size planSize,
    double margin = 12,
  }) {
    if (planSize.width <= 0 || planSize.height <= 0) {
      return const PlanTransform(scale: 1, origin: Offset.zero);
    }

    final double availableWidth = (viewport.width - margin * 2).clamp(1, 1e6);
    final double availableHeight = (viewport.height - margin * 2).clamp(1, 1e6);

    final double scale = _min(
      availableWidth / planSize.width,
      availableHeight / planSize.height,
    );

    final double drawnWidth = planSize.width * scale;
    return PlanTransform(
      scale: scale,
      origin: Offset((viewport.width - drawnWidth) / 2, margin),
    );
  }

  Offset toCanvas(PlanPoint point) =>
      Offset(origin.dx + point.x * scale, origin.dy + point.y * scale);

  PlanPoint toPlan(Offset canvas) => PlanPoint(
        (canvas.dx - origin.dx) / scale,
        (canvas.dy - origin.dy) / scale,
      );

  /// Metres converted to pixels, for stroke widths expressed in plan units.
  double metres(double value) => value * scale;

  static double _min(double a, double b) => a < b ? a : b;
}
