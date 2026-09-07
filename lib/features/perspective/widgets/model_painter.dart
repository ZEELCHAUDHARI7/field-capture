import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../plan/models/plan_document.dart';
import '../../plan/models/plan_space.dart';
import '../models/perspective_camera.dart';
import '../models/perspective_source.dart';

/// Renders the level in perspective from the camera's position.
///
/// A painter's-algorithm renderer: every wall becomes a quad, quads sort back
/// to front by distance, near-plane clipping happens in camera space before
/// anything is projected. No 3D engine and no dependency — see
/// `PerspectiveSource` for why, and ASSUMPTIONS.md §I1.
class ModelPainter extends CustomPainter {
  const ModelPainter({
    required this.source,
    required this.camera,
  });

  final PerspectiveSource source;
  final PerspectiveCamera camera;

  /// Surfaces further than this fade into the background rather than ending at
  /// a hard edge.
  static const double _fogStart = 6;
  static const double _fogEnd = 26;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBackdrop(canvas, size);

    switch (source) {
      case ExtrudedPlanSource(
          :final PlanDocument document,
          :final double wallHeightMetres
        ):
        _paintFloor(canvas, size);
        _paintExtrudedPlan(canvas, document, wallHeightMetres);
      case ModelPerspectiveSource():
        _paintNoRenderer(canvas, size);
    }
  }

  // ---------------------------------------------------------------------------
  // Ground and sky
  // ---------------------------------------------------------------------------

  void _paintBackdrop(Canvas canvas, Size size) {
    final double horizon = camera.horizonY.clamp(0.0, size.height);

    canvas
      ..drawRect(
        Rect.fromLTRB(0, 0, size.width, horizon),
        Paint()..color = const Color(0xFFEDEFF2),
      )
      ..drawRect(
        Rect.fromLTRB(0, horizon, size.width, size.height),
        Paint()..color = const Color(0xFFD6DBE0),
      );
  }

  /// A metre grid on the slab, which is what gives the walk a sense of speed.
  void _paintFloor(Canvas canvas, Size size) {
    final Paint line = Paint()
      ..color = AppColors.alpha(AppColors.onSurface, 0.10)
      ..strokeWidth = 1;

    const double reach = 18;
    final double ox = camera.position.x;
    final double oy = camera.position.y;

    final int minX = (ox - reach).floor();
    final int maxX = (ox + reach).ceil();
    final int minY = (oy - reach).floor();
    final int maxY = (oy + reach).ceil();

    for (int x = minX; x <= maxX; x++) {
      _drawGroundSegment(
        canvas,
        PlanPoint(x.toDouble(), minY.toDouble()),
        PlanPoint(x.toDouble(), maxY.toDouble()),
        line,
      );
    }
    for (int y = minY; y <= maxY; y++) {
      _drawGroundSegment(
        canvas,
        PlanPoint(minX.toDouble(), y.toDouble()),
        PlanPoint(maxX.toDouble(), y.toDouble()),
        line,
      );
    }
  }

  void _drawGroundSegment(
    Canvas canvas,
    PlanPoint a,
    PlanPoint b,
    Paint paint,
  ) {
    final (CameraPoint, CameraPoint)? clipped =
        camera.clipToNearPlane(camera.toCamera(a), camera.toCamera(b));
    if (clipped == null) return;

    final Offset? p1 = camera.projectCamera(clipped.$1, 0);
    final Offset? p2 = camera.projectCamera(clipped.$2, 0);
    if (p1 == null || p2 == null) return;

    canvas.drawLine(p1, p2, paint);
  }

  // ---------------------------------------------------------------------------
  // Walls
  // ---------------------------------------------------------------------------

  void _paintExtrudedPlan(
    Canvas canvas,
    PlanDocument document,
    double wallHeight,
  ) {
    final List<_Surface> surfaces = <_Surface>[];

    void addSegment(PlanPoint a, PlanPoint b, {required bool structural}) {
      final CameraPoint ca = camera.toCamera(a);
      final CameraPoint cb = camera.toCamera(b);
      final (CameraPoint, CameraPoint)? clipped =
          camera.clipToNearPlane(ca, cb);
      if (clipped == null) return;

      final Offset? bottomA = camera.projectCamera(clipped.$1, 0);
      final Offset? bottomB = camera.projectCamera(clipped.$2, 0);
      final Offset? topA = camera.projectCamera(clipped.$1, wallHeight);
      final Offset? topB = camera.projectCamera(clipped.$2, wallHeight);
      if (bottomA == null || bottomB == null || topA == null || topB == null) {
        return;
      }

      surfaces.add(
        _Surface(
          path: Path()
            ..moveTo(bottomA.dx, bottomA.dy)
            ..lineTo(bottomB.dx, bottomB.dy)
            ..lineTo(topB.dx, topB.dy)
            ..lineTo(topA.dx, topA.dy)
            ..close(),
          depth: (clipped.$1.forward + clipped.$2.forward) / 2,
          // Faces square to the view catch more light than raking ones — a
          // cheap stand-in for shading that stops every wall reading flat.
          facing: _facing(clipped.$1, clipped.$2),
          structural: structural,
        ),
      );
    }

    void addPolyline(List<PlanPoint> points, {required bool structural}) {
      for (int i = 0; i < points.length - 1; i++) {
        addSegment(points[i], points[i + 1], structural: structural);
      }
    }

    addPolyline(document.outline, structural: true);

    switch (document.source) {
      case GeometryPlanSource(:final PlanGeometry geometry):
        for (final PlanPolyline wall in geometry.walls) {
          addPolyline(wall.points, structural: false);
        }
        for (final PlanRect core in geometry.stairs) {
          addPolyline(_rectRing(core), structural: true);
        }
        for (final PlanRect shaft in geometry.voids) {
          addPolyline(_rectRing(shaft), structural: true);
        }
        for (final PlanPoint column in geometry.columns) {
          addPolyline(_columnRing(column), structural: true);
        }
      case RasterPlanSource():
        // A raster plan carries no geometry to extrude. Nothing to draw but
        // the floor — see ASSUMPTIONS.md §I1.
        break;
    }

    surfaces.sort((_Surface a, _Surface b) => b.depth.compareTo(a.depth));

    for (final _Surface surface in surfaces) {
      canvas
        ..drawPath(surface.path, Paint()..color = _fill(surface))
        ..drawPath(
          surface.path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = AppColors.alpha(
              AppColors.onSurface,
              0.12 * _visibility(surface.depth),
            ),
        );
    }
  }

  Color _fill(_Surface surface) {
    // Base tone: structure reads a shade darker than partitions.
    const Color lit = Color(0xFFF4F6F8);
    const Color shade = Color(0xFFC9D0D7);

    final double t = (1 - surface.facing).clamp(0.0, 1.0);
    final Color base = Color.lerp(lit, shade, t * 0.85)!;
    final Color toned = surface.structural
        ? Color.lerp(base, shade, 0.25)!
        : base;

    return Color.lerp(
      const Color(0xFFD6DBE0),
      toned,
      _visibility(surface.depth),
    )!;
  }

  /// 1 near, 0 at the fog limit.
  double _visibility(double depth) {
    if (depth <= _fogStart) return 1;
    if (depth >= _fogEnd) return 0.12;
    final double t = (depth - _fogStart) / (_fogEnd - _fogStart);
    return 1 - t * 0.88;
  }

  /// How square-on the surface is: 1 facing the camera, 0 edge-on.
  double _facing(CameraPoint a, CameraPoint b) {
    final double dx = b.right - a.right;
    final double dy = b.forward - a.forward;
    final double length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) return 0;
    // The wall's normal against the view axis.
    return (dx / length).abs();
  }

  List<PlanPoint> _rectRing(PlanRect rect) => <PlanPoint>[
        rect.topLeft,
        PlanPoint(rect.bottomRight.x, rect.topLeft.y),
        rect.bottomRight,
        PlanPoint(rect.topLeft.x, rect.bottomRight.y),
        rect.topLeft,
      ];

  List<PlanPoint> _columnRing(PlanPoint centre) {
    const double half = 0.28;
    return <PlanPoint>[
      PlanPoint(centre.x - half, centre.y - half),
      PlanPoint(centre.x + half, centre.y - half),
      PlanPoint(centre.x + half, centre.y + half),
      PlanPoint(centre.x - half, centre.y + half),
      PlanPoint(centre.x - half, centre.y - half),
    ];
  }

  /// Shown if a real model source is ever set without a renderer behind it.
  void _paintNoRenderer(Canvas canvas, Size size) {
    final TextPainter painter = TextPainter(
      text: const TextSpan(
        text: 'No renderer for this model format yet',
        style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 13),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 48);

    painter.paint(
      canvas,
      Offset(
        (size.width - painter.width) / 2,
        (size.height - painter.height) / 2,
      ),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant ModelPainter old) =>
      old.source != source ||
      old.camera.position != camera.position ||
      old.camera.yaw != camera.yaw ||
      old.camera.viewport != camera.viewport;
}

class _Surface {
  const _Surface({
    required this.path,
    required this.depth,
    required this.facing,
    required this.structural,
  });

  final Path path;
  final double depth;
  final double facing;
  final bool structural;
}
