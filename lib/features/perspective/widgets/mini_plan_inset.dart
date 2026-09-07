import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../plan/models/plan_document.dart';
import '../../plan/models/plan_space.dart';
import '../../plan/models/trajectory.dart';

/// The small plan card in the corner of the 3D view.
///
/// "Position is always shown on the mini plan for orientation." It carries the
/// level outline, the walk being flown, and a heading cone showing where the
/// viewer is looking — the last of which is what makes yaw legible.
class MiniPlanInset extends StatelessWidget {
  const MiniPlanInset({
    super.key,
    required this.document,
    required this.trajectory,
    required this.position,
    required this.yaw,
    this.size = 96,
  });

  final PlanDocument document;
  final Trajectory trajectory;
  final PlanPoint position;
  final double yaw;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Mini plan showing your position on the level',
      child: Container(
        height: size,
        width: size,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppSizes.radiusCard),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: AppColors.shadow,
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: CustomPaint(
          painter: _MiniPlanPainter(
            document: document,
            trajectory: trajectory,
            position: position,
            yaw: yaw,
          ),
        ),
      ),
    );
  }
}

class _MiniPlanPainter extends CustomPainter {
  const _MiniPlanPainter({
    required this.document,
    required this.trajectory,
    required this.position,
    required this.yaw,
  });

  final PlanDocument document;
  final Trajectory trajectory;
  final PlanPoint position;
  final double yaw;

  @override
  void paint(Canvas canvas, Size size) {
    final PlanTransform transform = PlanTransform.fit(
      viewport: size,
      planSize: document.size,
      margin: 2,
    );

    // Outline and interior walls only — grid, labels and pins would be noise
    // at this size.
    final Paint wall = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = AppColors.onSurfaceVariant;

    _polyline(canvas, document.outline, transform, wall);

    if (document.source case GeometryPlanSource(:final PlanGeometry geometry)) {
      final Paint interior = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = AppColors.outline;
      for (final PlanPolyline line in geometry.walls) {
        _polyline(canvas, line.points, transform, interior);
      }
    }

    // The walk being flown.
    final List<PlanPoint> path = trajectory.path;
    if (path.length >= 2) {
      _polyline(
        canvas,
        path,
        transform,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..color = AppColors.alpha(AppColors.captureActive, 0.7),
      );
    }

    // Where the viewer is, and which way they face.
    final Offset here = transform.toCanvas(position);
    _paintHeadingCone(canvas, here);
    canvas
      ..drawCircle(here, 4, Paint()..color = AppColors.surface)
      ..drawCircle(here, 3, Paint()..color = AppColors.captureActive);
  }

  void _paintHeadingCone(Canvas canvas, Offset centre) {
    const double reach = 16;
    const double spread = 0.42; // radians either side

    final Path cone = Path()..moveTo(centre.dx, centre.dy);
    for (double a = -spread; a <= spread; a += spread / 4) {
      cone.lineTo(
        centre.dx + reach * math.cos(yaw + a),
        centre.dy + reach * math.sin(yaw + a),
      );
    }
    cone.close();

    canvas.drawPath(
      cone,
      Paint()..color = AppColors.alpha(AppColors.captureActive, 0.28),
    );
  }

  void _polyline(
    Canvas canvas,
    List<PlanPoint> points,
    PlanTransform transform,
    Paint paint,
  ) {
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

  @override
  bool shouldRepaint(covariant _MiniPlanPainter old) =>
      old.position != position ||
      old.yaw != yaw ||
      old.trajectory != trajectory ||
      old.document != document;
}
