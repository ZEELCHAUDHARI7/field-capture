import 'package:flutter/material.dart';

import '../constants/app_sizes.dart';
import '../theme/app_colors.dart';

/// The tone of a badge or chip, mapped to the prototype's container colours.
enum BadgeTone {
  /// Grey. "Access", "Waiting", "Other".
  neutral,

  /// Light blue. "Assigned · D. Okafor", info banners.
  info,

  /// Soft green. "Synced", "Uploaded", "Available offline".
  success,

  /// Soft amber. "Medium", "Offline". ASSUMED — no amber chip is drawn.
  warning,

  /// Soft red. "High", "Failed".
  danger,
}

/// A small, non-interactive status pill: severity, sync state, upload state.
///
/// For a chip the user can tap, use ChipSelector instead.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    this.tone = BadgeTone.neutral,
    this.icon,
  });

  final String label;
  final BadgeTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final _BadgeColors colors = _colorsFor(tone);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: icon == null ? AppSizes.sm : 6,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(AppSizes.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 13, color: colors.foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: colors.foreground),
          ),
        ],
      ),
    );
  }

  _BadgeColors _colorsFor(BadgeTone tone) {
    switch (tone) {
      case BadgeTone.neutral:
        return const _BadgeColors(
          AppColors.neutralContainer,
          AppColors.onNeutralContainer,
        );
      case BadgeTone.info:
        return const _BadgeColors(
          AppColors.infoContainer,
          AppColors.onInfoContainer,
        );
      case BadgeTone.success:
        return const _BadgeColors(
          AppColors.successContainer,
          AppColors.onSuccessContainer,
        );
      case BadgeTone.warning:
        return const _BadgeColors(
          AppColors.warningContainer,
          AppColors.onWarningContainer,
        );
      case BadgeTone.danger:
        return const _BadgeColors(
          AppColors.dangerContainer,
          AppColors.onDangerContainer,
        );
    }
  }
}

class _BadgeColors {
  const _BadgeColors(this.background, this.foreground);
  final Color background;
  final Color foreground;
}
