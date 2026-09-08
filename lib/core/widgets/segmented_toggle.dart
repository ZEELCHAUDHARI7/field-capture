import 'package:flutter/material.dart';

import '../constants/app_sizes.dart';
import '../theme/app_colors.dart';
import 'min_tap_target.dart';

/// A two-or-more-way segmented control on a white track.
///
/// The prototype uses it once, for the coverage history filter: "a two-state
/// filter rather than a date picker — it is a field decision."
class SegmentedToggle<T> extends StatelessWidget {
  const SegmentedToggle({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return MinTapTarget.vertical(
      child: Container(
        height: 36,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppSizes.radiusPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final T value in values)
              _Segment<T>(
                label: labelOf(value),
                isSelected: value == selected,
                onTap: () => onChanged(value),
              ),
          ],
        ),
      ),
    );
  }
}

class _Segment<T> extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isSelected,
      child: Material(
        color: isSelected ? AppColors.chrome : Colors.transparent,
        borderRadius: BorderRadius.circular(AppSizes.radiusPill),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppSizes.radiusPill),
          child: Container(
            constraints: const BoxConstraints(
              minWidth: AppSizes.minTouchTarget,
            ),
            padding: const EdgeInsets.symmetric(horizontal: AppSizes.md),
            alignment: Alignment.center,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: isSelected
                        ? AppColors.onChrome
                        : AppColors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ),
      ),
    );
  }
}
