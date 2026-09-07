import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/status_badge.dart';
import '../../plan/models/plan_marker.dart';
import 'issue_card.dart';
import 'sync_timeline.dart';

/// Prototype screen 17 — Issue detail.
///
/// Read-only by design: "Assignment and workflow happen in Asite Field. This
/// app captures and raises issues only."
class IssueDetailSheet extends StatelessWidget {
  const IssueDetailSheet({
    super.key,
    required this.issue,
    required this.gridReference,
    required this.levelName,
  });

  final IssueMarker issue;
  final String gridReference;
  final String levelName;

  static Future<void> show(
    BuildContext context, {
    required IssueMarker issue,
    required String gridReference,
    required String levelName,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      barrierColor: AppColors.scrim,
      builder: (BuildContext context) => IssueDetailSheet(
        issue: issue,
        gridReference: gridReference,
        levelName: levelName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSizes.xl,
            AppSizes.sm,
            AppSizes.xl,
            AppSizes.xl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _PhotoPanel(hasPhoto: issue.hasPhoto),
              const SizedBox(height: AppSizes.lg),
              Text(issue.title, style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSizes.md),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  StatusBadge(label: issue.category.label),
                  StatusBadge(
                    label: issue.severity.label,
                    tone: severityTone(issue.severity),
                  ),
                ],
              ),
              const SizedBox(height: AppSizes.md),
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.place_outlined,
                    size: 15,
                    color: AppColors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      'Grid $gridReference · $levelName · '
                      '${Formatters.relative(issue.recordedAt)}',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: AppColors.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSizes.lg),
              const Divider(),
              const SizedBox(height: AppSizes.lg),
              Text(
                'SYNC STATUS — READ-ONLY',
                style: AppTypography.sectionLabel
                    .copyWith(color: AppColors.onSurfaceVariant),
              ),
              const SizedBox(height: AppSizes.md),
              SyncTimeline(issue: issue),
              const SizedBox(height: AppSizes.lg),
              const _AsiteFieldNotice(),
              const SizedBox(height: AppSizes.lg),
              AppButton(
                label: 'Close',
                variant: AppButtonVariant.neutral,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoPanel extends StatelessWidget {
  const _PhotoPanel({required this.hasPhoto});

  final bool hasPhoto;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 150,
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.thumbnailPlaceholder,
        borderRadius: BorderRadius.circular(AppSizes.radiusCard),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            hasPhoto
                ? Icons.image_outlined
                : Icons.image_not_supported_outlined,
            size: 20,
            color: AppColors.onSurfaceVariant,
          ),
          const SizedBox(width: AppSizes.sm),
          Text(
            hasPhoto ? 'Photo attached' : 'No photo attached',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _AsiteFieldNotice extends StatelessWidget {
  const _AsiteFieldNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSizes.md),
      decoration: BoxDecoration(
        color: AppColors.infoContainer,
        borderRadius: BorderRadius.circular(AppSizes.radiusButton),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.info_outline,
            size: 17,
            color: AppColors.onInfoContainer,
          ),
          const SizedBox(width: AppSizes.sm),
          Expanded(
            child: Text(
              'Assignment and workflow happen in Asite Field. This app '
              'captures and raises issues only.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.onInfoContainer),
            ),
          ),
        ],
      ),
    );
  }
}
