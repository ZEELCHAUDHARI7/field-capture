import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../plan/models/plan_space.dart';
import '../../plan/models/trajectory.dart';

/// The small white sketch of a walk's shape on a picker row.
///
/// Drawn from the trajectory's own pins rather than shipped as an image, so
/// "the trajectory list mirrors the plan trails" is true by construction — the
/// thumbnail cannot drift from the path it stands for.
class TrajectoryThumbnail extends StatelessWidget {
  const TrajectoryThumbnail({
    super.key,
    required this.trajectory,
    this.size = 48,
  });

  final Trajectory trajectory;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSizes.radiusThumbnail),
      ),
      child: CustomPaint(
        painter: _TrailSketchPainter(trajectory.path),
      ),
    );
  }
}

class _TrailSketchPainter extends CustomPainter {
  const _TrailSketchPainter(this.path);

  final List<PlanPoint> path;

  @override
  void paint(Canvas canvas, Size size) {
    if (path.length < 2) return;

    // Fit the walk's own bounding box into the tile, keeping its proportions.
    double minX = path.first.x, maxX = path.first.x;
    double minY = path.first.y, maxY = path.first.y;
    for (final PlanPoint p in path) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }

    const double pad = 10;
    final double spanX = (maxX - minX).abs();
    final double spanY = (maxY - minY).abs();
    final double extent = spanX > spanY ? spanX : spanY;
    final double scale =
        extent == 0 ? 1 : (size.width - pad * 2) / extent;

    Offset place(PlanPoint p) => Offset(
          pad + (p.x - minX) * scale + (extent - spanX) * scale / 2,
          pad + (p.y - minY) * scale + (extent - spanY) * scale / 2,
        );

    final Path sketch = Path()
      ..moveTo(place(path.first).dx, place(path.first).dy);
    for (final PlanPoint p in path.skip(1)) {
      final Offset o = place(p);
      sketch.lineTo(o.dx, o.dy);
    }

    canvas
      ..drawPath(
        sketch,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = AppColors.primary,
      )
      ..drawCircle(place(path.first), 2.5, Paint()..color = AppColors.primary)
      ..drawCircle(place(path.last), 2.5, Paint()..color = AppColors.success);
  }

  @override
  bool shouldRepaint(covariant _TrailSketchPainter old) => old.path != path;
}
