import 'package:flutter/material.dart';

import '../constants/app_sizes.dart';
import '../theme/app_colors.dart';

/// The dark rounded pill used for Coverage, 3D and (from Phase 5) Compare.
///
/// Two visual states: active is solid navy with white content; inactive is a
/// white pill with dark content, so both read against the plan behind them.
class PillToggle extends StatelessWidget {
  const PillToggle({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.active = true,
    this.accent = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  final bool active;

  /// Uses the primary blue instead of navy — the prototype's active Compare
  /// pill. Unused until Phase 5 but the variant belongs with the widget.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final Color background = active
        ? (accent ? AppColors.primary : AppColors.chrome)
        : AppColors.surface;
    final Color foreground =
        active ? AppColors.onChrome : AppColors.onSurface;

    return Semantics(
      button: true,
      toggled: active,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(AppSizes.radiusPill),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppSizes.radiusPill),
          child: Container(
            height: 36,
            constraints: const BoxConstraints(minWidth: AppSizes.minTouchTarget),
            padding: const EdgeInsets.symmetric(horizontal: AppSizes.md),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 16, color: foreground),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
