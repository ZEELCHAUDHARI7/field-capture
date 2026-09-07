import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/status_badge.dart';
import '../../plan/models/plan_marker.dart';

/// One row on prototype screen 16 — Site issues.
///
/// "Severity and category are the only required fields — speed matters on
/// site. Sync state is explicit: local, queued, synced, assigned."
class IssueCard extends StatelessWidget {
  const IssueCard({
    super.key,
    required this.issue,
    required this.gridReference,
    required this.onTap,
  });

  final IssueMarker issue;

  /// Computed from the pin, never typed — see ASSUMPTIONS.md §F3.
  final String gridReference;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return AppCard(
      onTap: onTap,
      semanticLabel: '${issue.title}. '
          '${issue.category.label}, ${issue.severity.label} severity, '
          '${issue.syncState.label}. Grid $gridReference.',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          IssueThumbnail(hasPhoto: issue.hasPhoto),
          const SizedBox(width: AppSizes.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(issue.title, style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSizes.sm),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    StatusBadge(label: issue.category.label),
                    StatusBadge(
                      label: issue.severity.label,
                      tone: severityTone(issue.severity),
                    ),
                    StatusBadge(
                      label: issue.assignee == null
                          ? issue.syncState.label
                          : '${issue.syncState.label} · ${issue.assignee}',
                      tone: syncTone(issue.syncState),
                    ),
                  ],
                ),
                const SizedBox(height: AppSizes.sm),
                Row(
                  children: <Widget>[
                    const Icon(
                      Icons.place_outlined,
                      size: 14,
                      color: AppColors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Pinned on plan · grid $gridReference',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: AppColors.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Severity maps to the semantic containers, not to arbitrary colours.
BadgeTone severityTone(IssueSeverity severity) => switch (severity) {
      IssueSeverity.low => BadgeTone.neutral,
      IssueSeverity.medium => BadgeTone.warning,
      IssueSeverity.high => BadgeTone.danger,
    };

/// Only Synced and Assigned are drawn; the other two follow §B4.
BadgeTone syncTone(IssueSyncState state) => switch (state) {
      IssueSyncState.local => BadgeTone.neutral,
      IssueSyncState.queued => BadgeTone.info,
      IssueSyncState.synced => BadgeTone.success,
      IssueSyncState.assigned => BadgeTone.info,
    };

/// The small grey square on an issue row.
///
/// Real photo thumbnails arrive with the camera integration; until then this
/// says plainly whether a photo is attached rather than faking one.
class IssueThumbnail extends StatelessWidget {
  const IssueThumbnail({super.key, required this.hasPhoto, this.size = 44});

  final bool hasPhoto;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: AppColors.thumbnailPlaceholder,
        borderRadius: BorderRadius.circular(AppSizes.radiusThumbnail),
      ),
      child: Icon(
        hasPhoto ? Icons.image_outlined : Icons.image_not_supported_outlined,
        size: 20,
        color: AppColors.onSurfaceVariant,
      ),
    );
  }
}
