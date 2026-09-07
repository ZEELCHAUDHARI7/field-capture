import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../models/workspace_data.dart';

/// The vertical level switch — B1 / L01 / L03 / L05.
///
/// Sits top-left with the coverage toggle, "out of the thumb arc" as the
/// prototype puts it: a mis-tap here would throw away the plan you are
/// standing on.
class LevelRail extends StatelessWidget {
  const LevelRail({
    super.key,
    required this.levels,
    required this.currentCalibrationId,
    required this.onSelect,
    required this.onBlocked,
  });

  final List<WorkspaceLevel> levels;
  final String currentCalibrationId;
  final ValueChanged<WorkspaceLevel> onSelect;

  /// A level whose bundle is not downloaded cannot be opened — same rule the
  /// calibration list enforces.
  final ValueChanged<WorkspaceLevel> onBlocked;

  @override
  Widget build(BuildContext context) {
    final List<WorkspaceLevel> ordered = <WorkspaceLevel>[...levels]
      ..sort((WorkspaceLevel a, WorkspaceLevel b) => a.order.compareTo(b.order));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final WorkspaceLevel level in ordered)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSizes.sm),
            child: _LevelButton(
              level: level,
              isCurrent: level.calibrationId == currentCalibrationId,
              onTap: () => level.isAvailableOffline
                  ? onSelect(level)
                  : onBlocked(level),
            ),
          ),
      ],
    );
  }
}

class _LevelButton extends StatelessWidget {
  const _LevelButton({
    required this.level,
    required this.isCurrent,
    required this.onTap,
  });

  final WorkspaceLevel level;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool available = level.isAvailableOffline;

    final Color background = isCurrent
        ? AppColors.primary
        : AppColors.surface;
    final Color foreground = isCurrent
        ? AppColors.onPrimary
        : (available ? AppColors.onSurface : AppColors.onSurfaceVariant);

    return Semantics(
      button: true,
      selected: isCurrent,
      label: available
          ? '${level.name}${isCurrent ? ', current level' : ''}'
          : '${level.name}, not downloaded',
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(AppSizes.radiusButton),
        child: InkWell(
          onTap: isCurrent ? null : onTap,
          borderRadius: BorderRadius.circular(AppSizes.radiusButton),
          child: Container(
            height: AppSizes.minTouchTarget,
            width: AppSizes.minTouchTarget,
            alignment: Alignment.center,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Text(
                  level.code,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                if (!available)
                  Positioned(
                    right: 4,
                    top: 5,
                    child: Icon(
                      Icons.download_outlined,
                      size: 11,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
