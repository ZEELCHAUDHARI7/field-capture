import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/field_app_bar.dart';
import '../../../core/widgets/pill_toggle.dart';
import '../../../core/widgets/state_views.dart';
import '../../capture/widgets/capture_chrome.dart';
import '../../plan/models/plan_space.dart';
import '../../plan/models/trajectory.dart';
import '../../plan/models/workspace_data.dart';
import '../../plan/state/workspace_controller.dart';
import '../models/perspective_camera.dart';
import '../models/perspective_source.dart';
import '../models/trajectory_walk.dart';
import '../state/perspective_controller.dart';
import '../widgets/compare_wipe.dart';
import '../widgets/mini_plan_inset.dart';
import '../widgets/model_painter.dart';
import '../widgets/scrub_bar.dart';

/// Prototype screens 14 and 15 — walk the trajectory, and the compare wipe.
///
/// "Scrubbing the trajectory moves the viewpoint along the recorded walk with
/// the 360° frame behind it — the closest thing to being back on site."
///
/// Compare is deliberately a mode of this screen rather than a route, because
/// the deck is explicit: "Compare is a mode, not a separate screen — the
/// viewpoint is preserved."
class PerspectiveWalkScreen extends ConsumerWidget {
  const PerspectiveWalkScreen({
    super.key,
    required this.calibrationId,
    required this.trajectoryId,
  });

  final String calibrationId;
  final String trajectoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<LevelWorkspaceData> data =
        ref.watch(workspaceDataProvider(calibrationId));

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: AppColors.chrome,
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
          data: (LevelWorkspaceData workspace) {
            Trajectory? trajectory;
            for (final Trajectory candidate in workspace.trajectories) {
              if (candidate.id == trajectoryId) {
                trajectory = candidate;
                break;
              }
            }

            if (trajectory == null) {
              return _MissingTrajectory(onBack: () => Navigator.of(context).pop());
            }

            return _Walk(workspace: workspace, trajectory: trajectory);
          },
        ),
      ),
    );
  }
}

class _Walk extends ConsumerWidget {
  const _Walk({required this.workspace, required this.trajectory});

  final LevelWorkspaceData workspace;
  final Trajectory trajectory;

  /// How far a full-width drag turns the view. A whole screen sweep is most of
  /// a half turn, which keeps fine aim possible without endless dragging.
  static const double _radiansPerScreenWidth = math.pi * 0.9;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PerspectiveState view = ref.watch(perspectiveProvider(trajectory.id));
    final PerspectiveController controller =
        ref.read(perspectiveProvider(trajectory.id).notifier);

    final TrajectoryWalk walk = TrajectoryWalk(trajectory);
    final PlanPoint position = walk.positionAt(view.fraction);
    final double yaw = walk.bearingAt(view.fraction) + view.yawOffset;

    final PerspectiveSource source =
        ExtrudedPlanSource(document: workspace.document);

    return Column(
      children: <Widget>[
        FieldAppBar(
          title: '3D Perspective',
          subtitle: '${workspace.levelName} · movement bound to trajectories',
          trailing: PillToggle(
            label: 'Compare',
            icon: Icons.compare_arrows,
            active: view.compare,
            accent: view.compare,
            onPressed: controller.toggleCompare,
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Size viewport =
                  Size(constraints.maxWidth, constraints.maxHeight);

              final PerspectiveCamera camera = PerspectiveCamera(
                position: position,
                yaw: yaw,
                viewport: viewport,
              );

              final Widget model = CustomPaint(
                painter: ModelPainter(source: source, camera: camera),
                size: viewport,
              );

              return Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: view.compare
                        ? CompareWipe(
                            model: model,
                            captured: const LivePreviewBackdrop(
                              label: 'CAPTURED 360° FRAME',
                            ),
                            position: view.wipe,
                            onChanged: controller.setWipe,
                          )
                        : GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragUpdate: (DragUpdateDetails d) =>
                                controller.turnBy(
                              -d.delta.dx /
                                  viewport.width *
                                  _radiansPerScreenWidth,
                            ),
                            child: model,
                          ),
                  ),

                  // The hint only makes sense when dragging does something.
                  if (!view.compare)
                    const Positioned(
                      left: 0,
                      right: 0,
                      top: AppSizes.md,
                      child: Center(child: _LookHint()),
                    ),

                  Positioned(
                    left: AppSizes.md,
                    bottom: AppSizes.md,
                    child: MiniPlanInset(
                      document: workspace.document,
                      trajectory: trajectory,
                      position: position,
                      yaw: yaw,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        ScrubBar(
          trajectoryName: trajectory.name,
          travelledMetres: walk.travelledMetres(view.fraction),
          totalMetres: walk.recordedLength,
          fraction: view.fraction,
          onChanged: controller.scrubTo,
        ),
      ],
    );
  }
}

class _LookHint extends StatelessWidget {
  const _LookHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSizes.md,
        vertical: 7,
      ),
      decoration: BoxDecoration(
        color: AppColors.alpha(AppColors.chrome, 0.72),
        borderRadius: BorderRadius.circular(AppSizes.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.screen_rotation_alt_outlined,
            size: 15,
            color: AppColors.onChrome,
          ),
          const SizedBox(width: 6),
          Text(
            'Rotate the phone to look — drag to simulate',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: AppColors.onChrome),
          ),
        ],
      ),
    );
  }
}

class _MissingTrajectory extends StatelessWidget {
  const _MissingTrajectory({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'That walk is no longer on this level',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: AppColors.onChrome),
            ),
            const SizedBox(height: AppSizes.sm),
            Text(
              'It may have been discarded since this screen was opened.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.onChromeMuted),
            ),
            const SizedBox(height: AppSizes.xl),
            TextButton(
              onPressed: onBack,
              child: const Text('Pick another walk'),
            ),
          ],
        ),
      ),
    );
  }
}
