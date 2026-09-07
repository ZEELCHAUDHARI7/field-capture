import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../models/plan_document.dart';
import '../models/plan_marker.dart';
import '../models/plan_space.dart';
import '../models/trajectory.dart';

/// Draws the calibrated plan sheet: grid, walls, columns, cores, zone names,
/// the coverage overlay and the dashed trajectory trails.
///
/// Pins are NOT painted here — they are widgets in an overlay above the canvas,
/// so they stay a constant size as the plan zooms and keep a full 48px touch
/// target under gloves.
class PlanPainter extends CustomPainter {
  const PlanPainter({
    required this.document,
    required this.transform,
    required this.trajectories,
    required this.captures,
    required this.showCoverage,
    required this.mutedIds,
    required this.textScale,
    this.liveTrajectory,
  });

  final PlanDocument document;
  final PlanTransform transform;
  final List<Trajectory> trajectories;
  final List<CaptureMarker> captures;
  final bool showCoverage;

  /// Trajectories and captures from earlier visits, drawn faded so today reads
  /// first — "earlier captures are drawn muted" (stated).
  final Set<String> mutedIds;

  final double textScale;

  /// The walk being recorded right now, drawn in the live-capture blue.
  final Trajectory? liveTrajectory;

  static const double _mutedOpacity = 0.35;

  @override
  void paint(Canvas canvas, Size size) {
    _paintSheet(canvas);
    _paintGrid(canvas);

    switch (document.source) {
      case GeometryPlanSource(:final PlanGeometry geometry):
        _paintGeometry(canvas, geometry);
      case RasterPlanSource(:final ui.Image image):
        _paintRaster(canvas, image);
    }

    _paintOutline(canvas);

    if (showCoverage) _paintCoverage(canvas);
    _paintTrails(canvas);
    _paintLiveTrail(canvas);
  }

  /// The in-progress walk. Solid rather than dashed and in the brighter blue,
  /// because it is the thing the crew is doing right now.
  void _paintLiveTrail(Canvas canvas) {
    final Trajectory? live = liveTrajectory;
    if (live == null) return;

    final List<PlanPoint> path = live.path;
    if (path.length < 2) return;

    final Paint paint = Paint()
      ..color = AppColors.captureActive
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < path.length - 1; i++) {
      _dashedLine(
        canvas,
        transform.toCanvas(path[i]),
        transform.toCanvas(path[i + 1]),
        paint,
        dash: 6,
        gap: 3,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Sheet and grid
  // ---------------------------------------------------------------------------

  Rect get _sheetRect => Rect.fromPoints(
        transform.toCanvas(const PlanPoint(0, 0)),
        transform.toCanvas(
          PlanPoint(document.widthMetres, document.heightMetres),
        ),
      );

  void _paintSheet(Canvas canvas) {
    canvas.drawRect(
      _sheetRect,
      Paint()..color = AppColors.surface,
    );
  }

  void _paintGrid(Canvas canvas) {
    final PlanGrid grid = document.grid;
    final Paint line = Paint()
      ..color = AppColors.outline
      ..strokeWidth = 1;

    for (int i = 0; i < grid.columnCount; i++) {
      final double x = transform.toCanvas(PlanPoint(grid.columnX(i), 0)).dx;
      _dashedLine(
        canvas,
        Offset(x, _sheetRect.top + 6),
        Offset(x, _sheetRect.bottom - 6),
        line,
      );
    }

    for (int i = 0; i < grid.rowCount; i++) {
      final double y = transform.toCanvas(PlanPoint(0, grid.rowY(i))).dy;
      _dashedLine(
        canvas,
        Offset(_sheetRect.left + 6, y),
        Offset(_sheetRect.right - 6, y),
        line,
      );
      _gridBubble(
        canvas,
        Offset(_sheetRect.left + 14, y),
        grid.rowLabel(i),
      );
    }
  }

  /// The small lettered circles down the left edge of the prototype's sheet.
  void _gridBubble(Canvas canvas, Offset centre, String label) {
    const double radius = 7;
    canvas
      ..drawCircle(centre, radius, Paint()..color = AppColors.surface)
      ..drawCircle(
        centre,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = AppColors.outline,
      );

    _text(
      canvas,
      label,
      centre,
      fontSize: 7,
      color: AppColors.onSurfaceVariant,
      align: _TextAlign.centre,
    );
  }

  // ---------------------------------------------------------------------------
  // Plan artwork
  // ---------------------------------------------------------------------------

  /// The production path once calibrations ship raster plans (D3).
  void _paintRaster(Canvas canvas, ui.Image image) {
    paintImage(
      canvas: canvas,
      rect: _sheetRect,
      image: image,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }

  void _paintGeometry(Canvas canvas, PlanGeometry geometry) {
    final Paint wall = Paint()
      ..color = AppColors.onSurface
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;

    for (final PlanPolyline polyline in geometry.walls) {
      _polyline(canvas, polyline.points, wall);
    }

    for (final PlanDoor door in geometry.doors) {
      final Offset hinge = transform.toCanvas(door.hinge);
      final double r = transform.metres(door.radius);
      canvas.drawArc(
        Rect.fromCircle(center: hinge, radius: r),
        door.startAngle,
        door.sweep,
        false,
        Paint()
          ..color = AppColors.outline
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }

    for (final PlanRect stair in geometry.stairs) {
      _paintStair(canvas, stair);
    }

    for (final PlanRect shaft in geometry.voids) {
      _paintVoid(canvas, shaft);
    }

    final Paint column = Paint()..color = AppColors.onSurface;
    final double columnSize = transform.metres(0.55).clamp(3.0, 14.0);
    for (final PlanPoint point in geometry.columns) {
      final Offset centre = transform.toCanvas(point);
      canvas.drawRect(
        Rect.fromCenter(center: centre, width: columnSize, height: columnSize),
        column,
      );
    }

    for (final PlanLabel label in geometry.labels) {
      _text(
        canvas,
        label.text,
        transform.toCanvas(label.at),
        fontSize: 7.5,
        color: AppColors.onSurfaceVariant,
        letterSpacing: 1.2,
        align: _TextAlign.centre,
      );
    }
  }

  void _paintStair(Canvas canvas, PlanRect stair) {
    final Rect rect = _rect(stair);
    final Paint stroke = Paint()
      ..color = AppColors.onSurface
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    canvas.drawRect(rect, stroke);

    final Paint tread = Paint()
      ..color = AppColors.onSurfaceVariant
      ..strokeWidth = 0.8;
    const int treads = 7;
    for (int i = 1; i < treads; i++) {
      final double y = rect.top + rect.height * i / treads;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), tread);
    }

    // The stair's own flight, drawn as a narrow inner block.
    canvas.drawRect(
      Rect.fromLTRB(
        rect.left + rect.width * 0.32,
        rect.top + rect.height * 0.18,
        rect.left + rect.width * 0.68,
        rect.top + rect.height * 0.42,
      ),
      Paint()..color = AppColors.onSurface,
    );
  }

  void _paintVoid(Canvas canvas, PlanRect shaft) {
    final Rect rect = _rect(shaft);
    final Paint stroke = Paint()
      ..color = AppColors.onSurface
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    canvas
      ..drawRect(rect, stroke)
      ..drawLine(rect.topLeft, rect.bottomRight, stroke)
      ..drawLine(rect.topRight, rect.bottomLeft, stroke);
  }

  void _paintOutline(Canvas canvas) {
    _polyline(
      canvas,
      document.outline,
      Paint()
        ..color = AppColors.onSurface
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.miter
        ..style = PaintingStyle.stroke,
    );
  }

  // ---------------------------------------------------------------------------
  // Coverage
  // ---------------------------------------------------------------------------

  /// ASSUMED. The prototype names a coverage layer and toggles it, but the
  /// rendering is not legible in the deck. Interpreted as "what has been
  /// documented": a soft disc around each capture point and a soft corridor
  /// along each recorded walk. See ASSUMPTIONS.md §F4.
  void _paintCoverage(Canvas canvas) {
    canvas.save();
    canvas.clipRect(_sheetRect);

    const double radiusMetres = 3.4;

    for (final CaptureMarker capture in captures) {
      final bool muted = mutedIds.contains(capture.id);
      canvas.drawCircle(
        transform.toCanvas(capture.at),
        transform.metres(radiusMetres),
        Paint()
          ..color = AppColors.alpha(
            AppColors.primary,
            muted ? 0.05 : 0.12,
          ),
      );
    }

    for (final Trajectory trajectory in trajectories) {
      final bool muted = mutedIds.contains(trajectory.id);
      final List<PlanPoint> path = trajectory.path;
      if (path.length < 2) continue;

      final Path corridor = Path();
      corridor.moveTo(
        transform.toCanvas(path.first).dx,
        transform.toCanvas(path.first).dy,
      );
      for (final PlanPoint point in path.skip(1)) {
        final Offset o = transform.toCanvas(point);
        corridor.lineTo(o.dx, o.dy);
      }

      canvas.drawPath(
        corridor,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = transform.metres(radiusMetres * 2)
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = AppColors.alpha(
            AppColors.primary,
            muted ? 0.05 : 0.12,
          ),
      );
    }

    canvas.restore();
  }

  // ---------------------------------------------------------------------------
  // Trails
  // ---------------------------------------------------------------------------

  void _paintTrails(Canvas canvas) {
    for (final Trajectory trajectory in trajectories) {
      final List<PlanPoint> path = trajectory.path;
      if (path.length < 2) continue;

      final bool muted = mutedIds.contains(trajectory.id);
      final Paint paint = Paint()
        ..color = AppColors.alpha(
          AppColors.primary,
          muted ? _mutedOpacity : 0.85,
        )
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;

      for (int i = 0; i < path.length - 1; i++) {
        _dashedLine(
          canvas,
          transform.toCanvas(path[i]),
          transform.toCanvas(path[i + 1]),
          paint,
          dash: 5,
          gap: 4,
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Primitives
  // ---------------------------------------------------------------------------

  Rect _rect(PlanRect rect) => Rect.fromPoints(
        transform.toCanvas(rect.topLeft),
        transform.toCanvas(rect.bottomRight),
      );

  void _polyline(Canvas canvas, List<PlanPoint> points, Paint paint) {
    if (points.length < 2) return;
    final Path path = Path();
    final Offset first = transform.toCanvas(points.first);
    path.moveTo(first.dx, first.dy);
    for (final PlanPoint point in points.skip(1)) {
      final Offset o = transform.toCanvas(point);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(path, paint);
  }

  void _dashedLine(
    Canvas canvas,
    Offset from,
    Offset to,
    Paint paint, {
    double dash = 3,
    double gap = 3,
  }) {
    final double total = (to - from).distance;
    if (total <= 0) return;
    final Offset step = (to - from) / total;

    double travelled = 0;
    while (travelled < total) {
      final double end = (travelled + dash).clamp(0.0, total);
      canvas.drawLine(
        from + step * travelled,
        from + step * end,
        paint,
      );
      travelled = end + gap;
    }
  }

  void _text(
    Canvas canvas,
    String value,
    Offset at, {
    required double fontSize,
    required Color color,
    double letterSpacing = 0,
    _TextAlign align = _TextAlign.topLeft,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: color,
          fontSize: fontSize * textScale,
          fontWeight: FontWeight.w600,
          letterSpacing: letterSpacing,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final Offset origin = align == _TextAlign.centre
        ? at - Offset(painter.width / 2, painter.height / 2)
        : at;
    painter.paint(canvas, origin);
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant PlanPainter old) {
    return old.document != document ||
        old.transform.scale != transform.scale ||
        old.transform.origin != transform.origin ||
        old.trajectories != trajectories ||
        old.captures != captures ||
        old.showCoverage != showCoverage ||
        old.mutedIds != mutedIds ||
        old.textScale != textScale ||
        old.liveTrajectory != liveTrajectory;
  }
}

enum _TextAlign { topLeft, centre }
