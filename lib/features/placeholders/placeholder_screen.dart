import 'package:flutter/material.dart';

import '../../core/constants/app_sizes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/widgets/app_card.dart';
import '../../core/widgets/field_app_bar.dart';

/// Stands in for the seven routes Phase 1 does not build.
///
/// Every route in the app resolves to something, so navigation is never a dead
/// end and the Phase 1 build is walkable end to end. Each placeholder names the
/// prototype pages it will implement and the phase that delivers it, which
/// doubles as the build's own progress board.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.phase,
    required this.prototypePages,
    required this.summary,
    this.subtitle,
  });

  final String title;
  final String? subtitle;

  /// "Phase 2", "Phase 5".
  final String phase;

  /// The prototype page numbers this screen covers.
  final String prototypePages;

  final String summary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: FieldAppBar(title: title, subtitle: subtitle),
      body: Padding(
        padding: const EdgeInsets.all(AppSizes.screenPadding),
        child: AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSizes.sm,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.infoContainer,
                      borderRadius: BorderRadius.circular(AppSizes.radiusPill),
                    ),
                    child: Text(
                      phase.toUpperCase(),
                      style: AppTypography.sectionLabel
                          .copyWith(color: AppColors.onInfoContainer),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'PDF $prototypePages',
                    style: AppTypography.mono.copyWith(
                      fontSize: 12,
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSizes.md),
              Text('Not built yet', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSizes.sm),
              Text(
                summary,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
