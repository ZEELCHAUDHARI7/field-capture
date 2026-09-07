import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/routing/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/field_app_bar.dart';
import '../../../core/widgets/state_views.dart';
import '../../plan/models/trajectory.dart';
import '../../plan/models/workspace_data.dart';
import '../../plan/state/workspace_controller.dart';
import '../widgets/trajectory_thumbnail.dart';

/// Prototype screen 13 — 3D view · pick a trajectory.
///
/// "This is not free roam — pick a captured trajectory to walk it in the model
/// at eye height, or define a new path." The list mirrors the plan's trails, so
/// selection is unambiguous.
class TrajectoryPickerScreen extends ConsumerWidget {
  const TrajectoryPickerScreen({super.key, required this.calibrationId});

  final String calibrationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<LevelWorkspaceData> data =
        ref.watch(workspaceDataProvider(calibrationId));

    return Scaffold(
      backgroundColor: AppColors.chrome,
      appBar: FieldAppBar(
        title: '3D Perspective',
        subtitle: data.valueOrNull == null
            ? null
            : '${data.valueOrNull!.levelName} · movement bound to trajectories',
      ),
      body: data.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.captureActive),
        ),
        error: (Object error, StackTrace _) => Padding(
          padding: const EdgeInsets.all(AppSizes.screenPadding),
          child: ErrorStateView(
            title: 'Could not open this level',
            message: 'The calibration bundle could not be read.',
            onRetry: () => ref
                .read(workspaceDataProvider(calibrationId).notifier)
                .refresh(),
          ),
        ),
        data: (LevelWorkspaceData workspace) => _Body(workspace: workspace),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.workspace});

  final LevelWorkspaceData workspace;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // "Only levels with a model offer the 3D entry point" — but the workspace
    // can still be reached directly, so the state is handled rather than
    // assumed away.
    if (!workspace.hasModel) {
      return _DarkNotice(
        icon: Icons.view_in_ar_outlined,
        title: 'No model for this level',
        message: '${workspace.levelName} has no 3D model published. Captures '
            'and issues still work on the plan.',
      );
    }

    final List<Trajectory> walks = <Trajectory>[...workspace.trajectories]
      ..sort((Trajectory a, Trajectory b) =>
          b.recordedAt.compareTo(a.recordedAt));

    if (walks.isEmpty) {
      return const _DarkNotice(
        icon: Icons.timeline_outlined,
        title: 'No walks recorded yet',
        message: 'Record a 360° video walk on this level and it becomes a path '
            'you can fly here.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSizes.screenPadding,
        AppSizes.lg,
        AppSizes.screenPadding,
        AppSizes.xxl,
      ),
      children: <Widget>[
        Text(
          'This is not free roam — pick a captured trajectory to walk it in '
          'the model at eye height, or define a new path.',
          style: theme.textTheme.bodyLarge
              ?.copyWith(color: AppColors.onChromeMuted),
        ),
        const SizedBox(height: AppSizes.lg),
        for (final Trajectory walk in walks) ...<Widget>[
          _TrajectoryRow(
            trajectory: walk,
            onTap: () => context.push(
              Routes.perspectiveWalkFor(workspace.calibrationId, walk.id),
            ),
          ),
          const SizedBox(height: AppSizes.cardGap),
        ],
        const SizedBox(height: AppSizes.xs),
        _DefineNewTrajectory(onTap: () => _notYet(context)),
      ],
    );
  }

  /// "+ Define new trajectory" is drawn with no destination and no described
  /// flow anywhere in the deck. ASSUMPTIONS.md §I5.
  void _notYet(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'Defining a path without walking it is not specified yet.',
          ),
        ),
      );
  }
}

class _TrajectoryRow extends StatelessWidget {
  const _TrajectoryRow({required this.trajectory, required this.onTap});

  final Trajectory trajectory;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int waypoints = trajectory.waypointCount;

    return Semantics(
      button: true,
      label: '${trajectory.name}, $waypoints waypoints, '
          '${trajectory.lengthMetres.round()} metres',
      child: Material(
        color: AppColors.chromeElevated,
        borderRadius: BorderRadius.circular(AppSizes.radiusCard),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppSizes.radiusCard),
          child: Padding(
            padding: const EdgeInsets.all(AppSizes.md),
            child: Row(
              children: <Widget>[
                TrajectoryThumbnail(trajectory: trajectory),
                const SizedBox(width: AppSizes.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        trajectory.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.mono.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.onChrome,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$waypoints waypoint${waypoints == 1 ? '' : 's'} · '
                        '${trajectory.lengthMetres.round()} m · '
                        '${_when(trajectory.recordedAt)}',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: AppColors.onChromeMuted),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  color: AppColors.onChromeMuted,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The deck says "Today" and "Earlier" rather than a date.
  String _when(DateTime moment) {
    final DateTime now = DateTime.now();
    final bool isToday = moment.year == now.year &&
        moment.month == now.month &&
        moment.day == now.day;
    return isToday ? 'Today' : 'Earlier';
  }
}

class _DefineNewTrajectory extends StatelessWidget {
  const _DefineNewTrajectory({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppSizes.radiusCard),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSizes.radiusCard),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSizes.radiusCard),
            border: Border.all(color: AppColors.capturePillBorder),
          ),
          child: Container(
            height: 56,
            alignment: Alignment.center,
            child: Text(
              '+ Define new trajectory',
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: AppColors.onChrome),
            ),
          ),
        ),
      ),
    );
  }
}

class _DarkNotice extends StatelessWidget {
  const _DarkNotice({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 34, color: AppColors.onChromeMuted),
            const SizedBox(height: AppSizes.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: AppColors.onChrome),
            ),
            const SizedBox(height: AppSizes.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.onChromeMuted),
            ),
          ],
        ),
      ),
    );
  }
}
