import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import 'plan_view_controller.dart';

/// Zoom in, zoom out, fit to level.
///
/// Rebuilds with the transform so the buttons dim at the ends of the zoom
/// range rather than silently doing nothing.
class MapControls extends StatelessWidget {
  const MapControls({super.key, required this.controller});

  final PlanViewController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller.transformation,
      builder: (BuildContext context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _ControlButton(
              icon: Icons.add,
              tooltip: 'Zoom in',
              onPressed: controller.canZoomIn ? controller.zoomIn : null,
            ),
            const SizedBox(height: AppSizes.sm),
            _ControlButton(
              icon: Icons.remove,
              tooltip: 'Zoom out',
              onPressed: controller.canZoomOut ? controller.zoomOut : null,
            ),
            const SizedBox(height: AppSizes.sm),
            _ControlButton(
              icon: Icons.crop_free,
              tooltip: 'Fit level to screen',
              onPressed: controller.isFitted ? null : controller.fit,
            ),
          ],
        );
      },
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSizes.radiusButton),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppSizes.radiusButton),
          child: SizedBox(
            height: AppSizes.minTouchTarget,
            width: AppSizes.minTouchTarget,
            child: Icon(
              icon,
              size: 20,
              color:
                  enabled ? AppColors.onSurface : AppColors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
