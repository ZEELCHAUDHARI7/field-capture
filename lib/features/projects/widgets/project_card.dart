import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../models/project.dart';

/// One row on prototype screen 02 — Project list.
class ProjectCard extends StatelessWidget {
  const ProjectCard({super.key, required this.project, required this.onTap});

  final Project project;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool synced = project.syncState == ProjectSyncState.synced;

    return AppCard(
      onTap: onTap,
      semanticLabel: '${project.name}, ${project.reference}, '
          '${Formatters.offlineCount(project.calibrationsOffline)}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(project.name, style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSizes.xs),
                Row(
                  children: <Widget>[
                    Text(
                      project.reference,
                      style: AppTypography.mono.copyWith(
                        fontSize: 12,
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      '  ·  ${project.location}',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: AppSizes.sm),
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.download_for_offline_outlined,
                      size: 15,
                      color: project.calibrationsOffline > 0
                          ? AppColors.success
                          : AppColors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        Formatters.offlineCount(project.calibrationsOffline),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: project.calibrationsOffline > 0
                              ? AppColors.success
                              : AppColors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                if (project.lastSyncedAt != null) ...<Widget>[
                  const SizedBox(height: 2),
                  // ASSUMED — the prototype's copy promises a sync stamp on
                  // each row, but none is drawn. See ASSUMPTIONS.md.
                  Text(
                    'Synced ${Formatters.relative(project.lastSyncedAt!).toLowerCase()}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSizes.md),
          _SyncGlyph(synced: synced),
          const SizedBox(width: AppSizes.xs),
          const Icon(
            Icons.chevron_right,
            size: 20,
            color: AppColors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _SyncGlyph extends StatelessWidget {
  const _SyncGlyph({required this.synced});
  final bool synced;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: synced ? 'Up to date' : 'Not synced',
      child: Container(
        height: 30,
        width: 30,
        decoration: BoxDecoration(
          color: synced ? AppColors.successContainer : AppColors.outlineSoft,
          shape: BoxShape.circle,
        ),
        child: Icon(
          synced ? Icons.check : Icons.refresh,
          size: 17,
          color: synced ? AppColors.success : AppColors.onSurfaceVariant,
        ),
      ),
    );
  }
}
