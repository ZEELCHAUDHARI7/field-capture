import 'package:flutter/material.dart';

import '../constants/app_sizes.dart';
import '../theme/app_colors.dart';

/// How a selected chip is filled.
///
/// The prototype uses both: primary blue for category and capture quality,
/// navy for severity. Same widget, two palettes.
enum ChipSelectorTone { primary, chrome }

/// A single-select row of chips — "Category and severity are chips, not
/// dropdowns — one tap each."
///
/// Used four times: issue category, issue severity, capture resolution and
/// frame rate.
class ChipSelector<T> extends StatelessWidget {
  const ChipSelector({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
    this.tone = ChipSelectorTone.primary,
    this.enabled = true,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  final ChipSelectorTone tone;

  /// Capture quality is "from the connected camera's capabilities", so the
  /// chips go flat when no camera is paired.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSizes.sm,
      runSpacing: AppSizes.sm,
      children: <Widget>[
        for (final T value in values)
          _Chip(
            label: labelOf(value),
            isSelected: value == selected,
            tone: tone,
            enabled: enabled,
            onTap: () => onChanged(value),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.isSelected,
    required this.tone,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final ChipSelectorTone tone;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color fill = switch ((isSelected, enabled, tone)) {
      (false, _, _) => AppColors.surface,
      (true, false, _) => AppColors.outlineSoft,
      (true, true, ChipSelectorTone.primary) => AppColors.primary,
      (true, true, ChipSelectorTone.chrome) => AppColors.chrome,
    };

    final Color foreground = isSelected
        ? (enabled ? AppColors.onPrimary : AppColors.onSurfaceVariant)
        : (enabled ? AppColors.onSurface : AppColors.onSurfaceVariant);

    return Semantics(
      button: true,
      selected: isSelected,
      enabled: enabled,
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(AppSizes.radiusPill),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(AppSizes.radiusPill),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppSizes.radiusPill),
              border: isSelected
                  ? null
                  : Border.all(color: AppColors.outline),
            ),
            child: Container(
              height: AppSizes.chipHeight,
              constraints: const BoxConstraints(minWidth: 72),
              padding: const EdgeInsets.symmetric(horizontal: AppSizes.lg),
              alignment: Alignment.center,
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
