import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

/// The draggable split between the design model and the captured imagery.
///
/// "Split handle is draggable and reads as a physical wipe." The right pane is
/// clipped rather than faded, and the handle sits on the seam, so the gesture
/// feels like moving a physical edge rather than adjusting an opacity.
class CompareWipe extends StatelessWidget {
  const CompareWipe({
    super.key,
    required this.model,
    required this.captured,
    required this.position,
    required this.onChanged,
  });

  /// The design model at this viewpoint.
  final Widget model;

  /// What the 360° capture recorded at the same viewpoint.
  final Widget captured;

  /// 0 (all captured) to 1 (all model).
  final double position;

  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double seam = (width * position).clamp(0.0, width);

        void dragTo(double dx) => onChanged((dx / width).clamp(0.0, 1.0));

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (DragUpdateDetails d) =>
              dragTo(d.localPosition.dx),
          onTapDown: (TapDownDetails d) => dragTo(d.localPosition.dx),
          child: Stack(
            children: <Widget>[
              Positioned.fill(child: captured),
              // The model is clipped to the left of the seam.
              Positioned.fill(
                child: ClipRect(
                  clipper: _LeftClipper(seam),
                  child: model,
                ),
              ),
              Positioned(
                left: AppSizes.md,
                top: AppSizes.md,
                child: _PaneLabel(
                  label: 'MODEL',
                  onDark: false,
                ),
              ),
              Positioned(
                right: AppSizes.md,
                top: AppSizes.md,
                child: _PaneLabel(
                  label: 'LIVE CAMERA',
                  onDark: true,
                  dot: AppColors.recording,
                ),
              ),
              Positioned(
                left: seam - 1,
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: AppColors.surface),
              ),
              Positioned(
                left: seam - 18,
                top: 0,
                bottom: 0,
                child: Center(child: _Handle()),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LeftClipper extends CustomClipper<Rect> {
  const _LeftClipper(this.seam);

  final double seam;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, 0, seam, size.height);

  @override
  bool shouldReclip(covariant _LeftClipper old) => old.seam != seam;
}

class _PaneLabel extends StatelessWidget {
  const _PaneLabel({
    required this.label,
    required this.onDark,
    this.dot,
  });

  final String label;
  final bool onDark;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSizes.sm, vertical: 5),
      decoration: BoxDecoration(
        color: onDark ? AppColors.capturePill : AppColors.surface,
        borderRadius: BorderRadius.circular(AppSizes.radiusButton),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (dot != null) ...<Widget>[
            Container(
              height: 6,
              width: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: AppTypography.sectionLabel.copyWith(
              fontSize: 10,
              color: onDark ? AppColors.onChrome : AppColors.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Drag to wipe between the model and the capture',
      child: Container(
        height: 36,
        width: 36,
        decoration: const BoxDecoration(
          color: AppColors.surface,
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: AppColors.shadow,
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: const Icon(
          Icons.code,
          size: 17,
          color: AppColors.onSurface,
        ),
      ),
    );
  }
}
