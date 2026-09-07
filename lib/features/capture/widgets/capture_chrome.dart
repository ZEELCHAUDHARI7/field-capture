import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

/// One of the small dark status pills on a full-screen capture screen:
/// elapsed time, camera identity, battery, free space.
class CapturePill extends StatelessWidget {
  const CapturePill({
    super.key,
    required this.label,
    this.icon,
    this.leadingDot,
    this.monospace = false,
  });

  final String label;
  final IconData? icon;

  /// The live recording indicator.
  final Color? leadingDot;

  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: AppSizes.md),
      decoration: BoxDecoration(
        color: AppColors.capturePill,
        borderRadius: BorderRadius.circular(AppSizes.radiusPill),
        border: Border.all(color: AppColors.capturePillBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (leadingDot != null) ...<Widget>[
            Container(
              height: 8,
              width: 8,
              decoration: BoxDecoration(
                color: leadingDot,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSizes.sm),
          ],
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14, color: AppColors.onChrome),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: monospace
                ? AppTypography.mono
                    .copyWith(fontSize: 12.5, color: AppColors.onChrome)
                : Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppColors.onChrome,
                      fontWeight: FontWeight.w600,
                    ),
          ),
        ],
      ),
    );
  }
}

/// The stand-in for the camera's live feed.
///
/// PHASE 3 MOCK. There is no 360° camera SDK and no phone-camera preview here —
/// the prototype itself draws a placeholder reading "LIVE 360° PREVIEW", and
/// this reproduces it faithfully rather than pretending to a feed. Replacing it
/// means swapping this one widget for the camera texture.
class LivePreviewBackdrop extends StatelessWidget {
  const LivePreviewBackdrop({super.key, this.label = 'LIVE 360° PREVIEW'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _PreviewGridPainter(),
      child: Center(
        child: Text(
          label,
          style: AppTypography.sectionLabel.copyWith(
            color: AppColors.alpha(AppColors.onChrome, 0.28),
            fontSize: 12,
            letterSpacing: 3,
          ),
        ),
      ),
    );
  }
}

class _PreviewGridPainter extends CustomPainter {
  const _PreviewGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = AppColors.captureBackdrop,
    );

    final Paint line = Paint()
      ..color = AppColors.alpha(AppColors.capturePillBorder, 0.55)
      ..strokeWidth = 1;

    const double step = 44;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewGridPainter oldDelegate) => false;
}

/// A ring that reads how much of the sphere is still missing.
class CaptureProgressRing extends StatelessWidget {
  const CaptureProgressRing({super.key, required this.progress, this.size = 76});

  final double progress;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Sweep ${(progress * 100).round()} percent complete',
      child: SizedBox(
        height: size,
        width: size,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            SizedBox(
              height: size,
              width: size,
              child: CircularProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                strokeWidth: 6,
                backgroundColor: AppColors.capturePillBorder,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppColors.captureActive,
                ),
              ),
            ),
            Text(
              '${(progress.clamp(0.0, 1.0) * 100).round()}%',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppColors.onChrome,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
