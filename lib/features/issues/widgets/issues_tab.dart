import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/state_views.dart';
import '../../plan/models/plan_marker.dart';
import '../../plan/models/workspace_data.dart';
import '../state/issue_report_controller.dart';
import 'issue_card.dart';
import 'issue_detail_sheet.dart';

/// Prototype screen 16 — Site Issues.
///
/// "Issues raised against this calibration, pinned on the plan and listed by
/// severity and sync state. The issues tab shares the plan so location is never
/// abstract."
class IssuesTab extends ConsumerWidget {
  const IssuesTab({super.key, required this.workspace});

  final LevelWorkspaceData workspace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // High severity first, then newest — what a site manager scans for.
    final List<IssueMarker> issues = <IssueMarker>[...workspace.issues]
      ..sort((IssueMarker a, IssueMarker b) {
        final int bySeverity =
            b.severity.index.compareTo(a.severity.index);
        if (bySeverity != 0) return bySeverity;
        return b.recordedAt.compareTo(a.recordedAt);
      });

    return ColoredBox(
      color: AppColors.background,
      child: Column(
        children: <Widget>[
          Expanded(
            child: issues.isEmpty
                ? const EmptyStateView(
                    icon: Icons.check_circle_outline,
                    title: 'No issues on this level',
                    message: 'Anything blocking work here can be raised '
                        'against the plan, with or without signal.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                      AppSizes.screenPadding,
                      AppSizes.lg,
                      AppSizes.screenPadding,
                      AppSizes.lg,
                    ),
                    itemCount: issues.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSizes.cardGap),
                    itemBuilder: (BuildContext context, int index) {
                      final IssueMarker issue = issues[index];
                      final String reference =
                          workspace.document.grid.referenceFor(issue.at);
                      return IssueCard(
                        issue: issue,
                        gridReference: reference,
                        onTap: () => IssueDetailSheet.show(
                          context,
                          issue: issue,
                          gridReference: reference,
                          levelName: workspace.levelName,
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSizes.screenPadding,
              0,
              AppSizes.screenPadding,
              AppSizes.lg,
            ),
            child: AppButton(
              label: 'Report an issue',
              icon: Icons.warning_amber_rounded,
              onPressed: () => ref
                  .read(issueReportProvider.notifier)
                  .begin(workspace.calibrationId),
            ),
          ),
        ],
      ),
    );
  }
}
