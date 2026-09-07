import 'package:flutter/material.dart';

import '../constants/app_sizes.dart';
import '../theme/app_colors.dart';

/// The list card used by projects, calibrations, issues and upload items.
///
/// Flat by design: a 1px border, no shadow. That is what the prototype draws,
/// and it keeps cards legible in direct sunlight.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(AppSizes.cardPadding),
    this.borderColor = AppColors.outline,
    this.backgroundColor = AppColors.surface,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final Color borderColor;
  final Color backgroundColor;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.circular(AppSizes.radiusCard);

    return Semantics(
      label: semanticLabel,
      button: onTap != null,
      child: Material(
        color: backgroundColor,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        // Ink must wrap InkWell, not the other way round, or the splash paints
        // over the border instead of under it.
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: borderColor,
              width: AppSizes.borderWidth,
            ),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
