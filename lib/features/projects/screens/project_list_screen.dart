import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/routing/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/brand_mark.dart';
import '../../../core/widgets/connectivity_pill.dart';
import '../../../core/widgets/field_app_bar.dart';
import '../../../core/widgets/state_views.dart';
import '../../uploads/widgets/upload_queue_button.dart';
import '../models/project.dart';
import '../state/projects_controller.dart';
import '../widgets/project_card.dart';

/// Prototype screen 02 — Project list.
///
/// "Every project the user can capture against, with how many calibrations are
/// already offline. Settings and the upload queue live in the header,
/// reachable from anywhere."
class ProjectListScreen extends ConsumerWidget {
  const ProjectListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Project>> projects =
        ref.watch(projectsControllerProvider);

    return Scaffold(
      appBar: FieldAppBar(
        title: 'Projects',
        titleIcon: const BrandMark(size: 30),
        leading: const SizedBox(width: AppSizes.lg),
        actions: <Widget>[
          IconButton(
            onPressed: () => context.push(Routes.settings),
            icon: const Icon(Icons.settings_outlined),
            color: AppColors.onChrome,
            iconSize: 22,
            tooltip: 'Settings',
          ),
          UploadQueueButton(onPressed: () => context.push(Routes.uploads)),
        ],
        bottom: const Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.only(left: AppSizes.lg),
            child: ConnectivityPill(),
          ),
        ),
      ),
      body: projects.when(
        loading: () => const LoadingListView(),
        error: (Object error, StackTrace _) => ErrorStateView(
          title: 'Could not load projects',
          message: 'Your projects are on Asite and the app could not reach it. '
              'Anything already downloaded still works offline.',
          onRetry: () =>
              ref.read(projectsControllerProvider.notifier).refresh(),
        ),
        data: (List<Project> items) {
          if (items.isEmpty) {
            return EmptyStateView(
              icon: Icons.folder_off_outlined,
              title: 'No projects yet',
              message: 'Your Asite account is not on a project that uses Field '
                  'Capture. Ask your site office to add you.',
              actionLabel: 'Check again',
              onAction: () =>
                  ref.read(projectsControllerProvider.notifier).refresh(),
            );
          }

          return RefreshIndicator(
            color: AppColors.primary,
            onRefresh: () =>
                ref.read(projectsControllerProvider.notifier).refresh(),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                AppSizes.screenPadding,
                AppSizes.md,
                AppSizes.screenPadding,
                AppSizes.xxl,
              ),
              itemCount: items.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: AppSizes.cardGap),
              itemBuilder: (BuildContext context, int index) {
                if (index == 0) return const _RefreshHint();
                final Project project = items[index - 1];
                return ProjectCard(
                  project: project,
                  onTap: () =>
                      context.push(Routes.calibrationsFor(project.id)),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _RefreshHint extends StatelessWidget {
  const _RefreshHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSizes.xs),
      child: Center(
        child: Text(
          'Pull to refresh project list',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: AppColors.onSurfaceVariant),
        ),
      ),
    );
  }
}
