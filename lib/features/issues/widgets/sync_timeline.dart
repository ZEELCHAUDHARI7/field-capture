import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../plan/models/plan_marker.dart';

/// One step in an issue's life.
class SyncStep {
  const SyncStep({
    required this.title,
    required this.detail,
    required this.reached,
  });

  final String title;
  final String detail;

  /// Reached steps get a filled green dot; the rest are hollow and grey.
  final bool reached;
}

/// The read-only timeline on prototype screen 17 — Issue detail.
///
/// "The detail sheet carries the issue through its life: who it went to, where
/// it is on the grid, when it was raised, and what happens next." It is
/// explicitly **read-only**: "Assignment is read-only offline; it syncs when
/// signal returns."
class SyncTimeline extends StatelessWidget {
  const SyncTimeline({super.key, required this.issue});

  final IssueMarker issue;

  List<SyncStep> get steps {
    final int reachedTo = switch (issue.syncState) {
      IssueSyncState.local => 0,
      IssueSyncState.queued => 0,
      IssueSyncState.synced => 1,
      IssueSyncState.assigned => 2,
    };

    return <SyncStep>[
      SyncStep(
        title: 'Saved on this device',
        detail: Formatters.relative(issue.recordedAt),
        reached: true,
      ),
      SyncStep(
        title: 'Synced to Asite Field',
        detail: issue.syncState == IssueSyncState.queued
            ? 'Queued — will upload with its plan pin'
            : 'Uploaded with its plan pin',
        reached: reachedTo >= 1,
      ),
      SyncStep(
        title: issue.assignee == null
            ? 'Assigned in Asite Field'
            : 'Assigned to ${issue.assignee}',
        detail: 'Managed in Asite Field',
        reached: reachedTo >= 2,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<SyncStep> items = steps;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < items.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _Rail(
                  reached: items[i].reached,
                  isLast: i == items.length - 1,
                ),
                const SizedBox(width: AppSizes.md),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: i == items.length - 1 ? 0 : AppSizes.lg,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          items[i].title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: items[i].reached
                                ? AppColors.onSurface
                                : AppColors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          items[i].detail,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: AppColors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.reached, required this.isLast});

  final bool reached;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final Color colour =
        reached ? AppColors.success : AppColors.outline;

    return SizedBox(
      width: 12,
      child: Column(
        children: <Widget>[
          const SizedBox(height: 4),
          Container(
            height: 10,
            width: 10,
            decoration: BoxDecoration(
              color: reached ? colour : AppColors.surface,
              shape: BoxShape.circle,
              border: Border.all(color: colour, width: 1.5),
            ),
          ),
          if (!isLast)
            Expanded(
              child: Container(
                width: 1.5,
                margin: const EdgeInsets.symmetric(vertical: 3),
                color: AppColors.outline,
              ),
            ),
        ],
      ),
    );
  }
}
