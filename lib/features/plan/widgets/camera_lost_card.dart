import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_button.dart';

/// The inline help card shown when the 360° camera drops off Wi-Fi.
///
/// "The help card is dismissible and does not block the plan" — so it sits over
/// the plan with a close affordance, not as a modal.
class CameraLostCard extends StatelessWidget {
  const CameraLostCard({
    super.key,
    required this.onReconnect,
    required this.onDismiss,
    this.reconnecting = false,
  });

  final VoidCallback onReconnect;
  final VoidCallback onDismiss;
  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(AppSizes.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSizes.radiusCard),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: AppColors.shadow,
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: AppColors.onDangerContainer,
              ),
              const SizedBox(width: AppSizes.sm),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(
                        text: '360° camera not connected. ',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: 'Video and image capture are unavailable — '
                            'Mobile Capture still works on this phone.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSizes.xs),
              SizedBox(
                height: 32,
                width: 32,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close),
                  color: AppColors.onSurfaceVariant,
                  tooltip: 'Dismiss',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSizes.md),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: 'Reconnect camera',
              expanded: false,
              busy: reconnecting,
              onPressed: onReconnect,
            ),
          ),
        ],
      ),
    );
  }
}
