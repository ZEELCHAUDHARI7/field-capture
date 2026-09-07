import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../models/plan_marker.dart';
import '../models/trajectory.dart';

/// Pin sizes. Constant in screen pixels — pins do not scale with the plan, so
/// they stay tappable at every zoom level.
abstract final class PinMetrics {
  static const double node = 26;
  static const double capture = 30;
  static const double issue = 26;

  /// The whole pin sits inside a 48px hit area, per the prototype's stated
  /// touch-target floor.
  static const double hitArea = AppSizes.minTouchTarget;
}

/// Start (S), waypoint (n) and end (E) pins on a recorded walk.
class TrajectoryPin extends StatelessWidget {
  const TrajectoryPin({
    super.key,
    required this.node,
    this.muted = false,
    this.active = false,
    this.onTap,
  });

  final TrajectoryNode node;
  final bool muted;

  /// The walk being recorded right now. Drawn in the brighter live-capture
  /// blue so a crew can tell it from walks already saved.
  final bool active;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final _PinPalette palette = switch (node.kind) {
      TrajectoryNodeKind.start => _PinPalette(
          fill: active ? AppColors.captureActive : AppColors.primary,
          foreground: AppColors.onPrimary,
        ),
      TrajectoryNodeKind.end => const _PinPalette(
          fill: AppColors.success,
          foreground: AppColors.onPrimary,
        ),
      TrajectoryNodeKind.waypoint => _PinPalette(
          fill: active ? AppColors.captureActive : AppColors.surface,
          foreground:
              active ? AppColors.onPrimary : AppColors.primary,
          border: active ? AppColors.surface : AppColors.primary,
        ),
    };

    return _PinTapTarget(
      onTap: onTap,
      semanticLabel: switch (node.kind) {
        TrajectoryNodeKind.start => 'Walk start',
        TrajectoryNodeKind.end => 'Walk end',
        TrajectoryNodeKind.waypoint => 'Waypoint ${node.sequence}',
      },
      child: Opacity(
        opacity: muted ? 0.45 : 1,
        child: Container(
          height: PinMetrics.node,
          width: PinMetrics.node,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: palette.fill,
            shape: BoxShape.circle,
            border: Border.all(
              color: palette.border ?? AppColors.surface,
              width: 2,
            ),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: AppColors.shadow,
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Text(
            node.label,
            style: TextStyle(
              color: palette.foreground,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// A 360° capture point: a rounded blue chip with a camera glyph and a pointer
/// beneath it, anchored at the exact plan position.
class CapturePin extends StatelessWidget {
  const CapturePin({
    super.key,
    required this.marker,
    this.muted = false,
    this.onTap,
  });

  final CaptureMarker marker;
  final bool muted;
  final VoidCallback? onTap;

  /// The pointer tip is what sits on the plan point, so the badge floats above.
  static const double pointerHeight = 7;
  static const double totalHeight = PinMetrics.capture + pointerHeight;

  @override
  Widget build(BuildContext context) {
    final IconData icon = switch (marker.mode) {
      CaptureMode.video => Icons.videocam_outlined,
      CaptureMode.image => Icons.photo_camera_outlined,
      CaptureMode.mobile => Icons.language_outlined,
    };

    return _PinTapTarget(
      onTap: onTap,
      semanticLabel: '${marker.mode.mediaLabel} capture, ${marker.name}',
      child: Opacity(
        opacity: muted ? 0.45 : 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              height: PinMetrics.capture,
              width: PinMetrics.capture,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.surface, width: 2),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: AppColors.shadow,
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              child: Icon(icon, size: 15, color: AppColors.onPrimary),
            ),
            const _Pointer(color: AppColors.primary),
          ],
        ),
      ),
    );
  }
}

/// An issue pin: the prototype's amber diamond with an exclamation mark.
class IssuePin extends StatelessWidget {
  const IssuePin({
    super.key,
    required this.marker,
    this.muted = false,
    this.onTap,
  });

  final IssueMarker marker;
  final bool muted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _PinTapTarget(
      onTap: onTap,
      semanticLabel: '${marker.severity.name} severity issue: ${marker.title}',
      child: Opacity(
        opacity: muted ? 0.45 : 1,
        child: SizedBox(
          height: PinMetrics.issue,
          width: PinMetrics.issue,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Transform.rotate(
                angle: 0.7853981633974483, // 45°
                child: Container(
                  height: PinMetrics.issue * 0.74,
                  width: PinMetrics.issue * 0.74,
                  decoration: BoxDecoration(
                    color: AppColors.warning,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppColors.surface, width: 2),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: AppColors.shadow,
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
              const Text(
                '!',
                style: TextStyle(
                  color: AppColors.surface,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The crosshair dropped by a tap in a pin mode, before it is confirmed.
///
/// Deliberately not a finished pin: the prototype uses "crosshair plus a
/// confirm button rather than tap-to-place, so a mis-tap costs nothing", and
/// this has to read as provisional at a glance.
class ProvisionalPin extends StatelessWidget {
  const ProvisionalPin({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        height: PinMetrics.hitArea,
        width: PinMetrics.hitArea,
        child: CustomPaint(painter: const _CrosshairPainter()),
      ),
    );
  }
}

class _CrosshairPainter extends CustomPainter {
  const _CrosshairPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Offset centre = Offset(size.width / 2, size.height / 2);
    const double radius = 13;

    final Paint halo = Paint()..color = AppColors.alpha(AppColors.surface, 0.85);
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = AppColors.captureActive;

    canvas
      ..drawCircle(centre, radius, halo)
      ..drawCircle(centre, radius, stroke)
      ..drawLine(centre - const Offset(radius + 5, 0),
          centre - const Offset(radius - 3, 0), stroke)
      ..drawLine(centre + const Offset(radius - 3, 0),
          centre + const Offset(radius + 5, 0), stroke)
      ..drawLine(centre - const Offset(0, radius + 5),
          centre - const Offset(0, radius - 3), stroke)
      ..drawLine(centre + const Offset(0, radius - 3),
          centre + const Offset(0, radius + 5), stroke)
      ..drawCircle(centre, 3, Paint()..color = AppColors.captureActive);
  }

  @override
  bool shouldRepaint(covariant _CrosshairPainter oldDelegate) => false;
}

/// Keeps every pin inside a 48px target without changing how it looks.
class _PinTapTarget extends StatelessWidget {
  const _PinTapTarget({
    required this.child,
    required this.semanticLabel,
    this.onTap,
  });

  final Widget child;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: onTap != null,
      child: SizedBox(
        height: PinMetrics.hitArea,
        width: PinMetrics.hitArea,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

class _Pointer extends StatelessWidget {
  const _Pointer({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(10, CapturePin.pointerHeight),
      painter: _PointerPainter(color),
    );
  }
}

class _PointerPainter extends CustomPainter {
  const _PointerPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PointerPainter old) => old.color != color;
}

class _PinPalette {
  const _PinPalette({
    required this.fill,
    required this.foreground,
    this.border,
  });

  final Color fill;
  final Color foreground;
  final Color? border;
}
