import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/chip_selector.dart';
import '../../../core/widgets/field_app_bar.dart';
import '../../../core/widgets/switch_tile.dart';
import '../../../shared/camera/camera_controller.dart';
import '../../../shared/camera/camera_session.dart';
import '../../../shared/connectivity/connectivity_controller.dart';
import '../../../shared/connectivity/connectivity_status.dart';
import '../../../shared/demo/demo_controls.dart';
import '../../../shared/storage/sphere_storage.dart';
import '../../capture/state/capture_flow_controller.dart';
import '../../capture/state/stitch_queue_controller.dart';
import '../../issues/state/issue_report_controller.dart';
import '../../plan/data/plan_repository.dart';
import '../../plan/data/sphere_capture_store.dart';
import '../../uploads/state/upload_queue_controller.dart';

/// The demo console. Not a prototype screen — it exists because eight states
/// the app can already render had no way in.
///
/// Connectivity was a tap on the status pill and camera loss a *long-press* on
/// the camera chip; the data faults were constructor arguments reachable only
/// by editing `main.dart` and restarting. None of that can be driven in front
/// of an audience, so every hidden hook is surfaced here as a labelled control.
///
/// This is the one screen allowed to reach across features: being the console
/// for all of them is its whole job. It comes out with the mocks.
class DemoControlsScreen extends ConsumerWidget {
  const DemoControlsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DemoControls demo = ref.watch(demoControlsProvider);
    final DemoControlsController controller =
        ref.read(demoControlsProvider.notifier);
    final ConnectivityStatus connectivity =
        ref.watch(connectivityControllerProvider);
    final CameraSession camera = ref.watch(cameraSessionProvider);

    return Scaffold(
      appBar: const FieldAppBar(
        title: 'Demo controls',
        subtitle: 'Not part of the product — ships with the mocks',
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSizes.screenPadding,
          AppSizes.lg,
          AppSizes.screenPadding,
          AppSizes.xxl,
        ),
        children: <Widget>[
          _FaultBanner(count: demo.activeFaults),
          const SizedBox(height: AppSizes.xl),

          const _SectionLabel('Connection'),
          _ChipRow<ConnectivityStatus>(
            title: 'Connectivity',
            description: 'The pill on every screen. Offline is a normal state '
                'in this product, so the capture path is unaffected.',
            values: ConnectivityStatus.values,
            selected: connectivity,
            labelOf: (ConnectivityStatus s) =>
                s == ConnectivityStatus.syncing ? 'Syncing' : s.label,
            onChanged: (ConnectivityStatus s) => ref
                .read(connectivityControllerProvider.notifier)
                .setStatus(s),
          ),
          const SizedBox(height: AppSizes.cardGap),
          _ChipRow<bool>(
            title: '360° camera',
            description: 'Dropping it turns the chip red, brings up the help '
                'card and refuses Video and Image — Mobile Capture stays live.',
            values: const <bool>[true, false],
            selected: camera.isConnected,
            labelOf: (bool connected) => connected ? 'Paired' : 'Lost',
            onChanged: (bool connected) {
              final CameraSessionController session =
                  ref.read(cameraSessionProvider.notifier);
              if (connected) {
                unawaited(session.reconnect());
              } else {
                session.simulateDisconnect();
              }
            },
          ),

          const SizedBox(height: AppSizes.xl),
          const _SectionLabel('Data faults'),
          _ChipRow<DataFault>(
            title: 'Project list',
            description: 'Loading, empty and error — none of which the deck '
                'draws, all of which the screen handles.',
            values: DataFault.values,
            selected: demo.projects,
            labelOf: (DataFault f) => f.label,
            onChanged: controller.setProjects,
          ),
          const SizedBox(height: AppSizes.cardGap),
          _ChipRow<DataFault>(
            title: 'Calibration list',
            description: 'Same three, per project.',
            values: DataFault.values,
            selected: demo.calibrations,
            labelOf: (DataFault f) => f.label,
            onChanged: controller.setCalibrations,
          ),
          const SizedBox(height: AppSizes.cardGap),
          SwitchTile(
            title: 'Plan fails to load',
            description: 'The Level Workspace error state. A calibration with '
                'no plan is not a calibration, so there is no empty variant.',
            value: demo.planFails,
            onChanged: controller.setPlanFails,
          ),
          const SizedBox(height: AppSizes.cardGap),
          SwitchTile(
            title: 'Downloads drop at 62%',
            description: 'A bundle download fails part-way and offers to '
                'resume, which is the number the deck fails its own upload at.',
            value: demo.downloadsFail,
            onChanged: controller.setDownloadsFail,
          ),

          const SizedBox(height: AppSizes.xl),
          const _SectionLabel('Capture'),
          SwitchTile(
            title: 'This phone supports Mobile Capture',
            description: 'Off refuses the capture the way a device without a '
                'gyroscope would. The real probe still runs underneath — this '
                'only overrides its answer, so the refusal states are reachable '
                'without a second tablet.',
            value: demo.mobileCaptureSupported,
            onChanged: controller.setMobileCaptureSupported,
          ),

          const SizedBox(height: AppSizes.xl),
          const _SectionLabel('Uploads'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Fail the item in flight',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSizes.xs),
                Text(
                  'Drops whichever capture is uploading and starts its retry '
                  'countdown.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.onSurfaceVariant),
                ),
                const SizedBox(height: AppSizes.md),
                AppButton(
                  label: 'Fail the active upload',
                  variant: AppButtonVariant.secondary,
                  onPressed: () {
                    ref.read(uploadQueueProvider.notifier).simulateFailure();
                    _say(context, 'Active upload marked failed.');
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSizes.xxxl),
          const _SectionLabel('Start over'),
          AppCard(
            borderColor: AppColors.outline,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Reset to the seed',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSizes.xs),
                Text(
                  'Clears every fault above and throws away every capture, '
                  'issue and walk recorded since launch. Run it before a demo, '
                  'not during one.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.onSurfaceVariant),
                ),
                const SizedBox(height: AppSizes.md),
                AppButton(
                  label: 'Reset all demo data',
                  variant: AppButtonVariant.destructive,
                  onPressed: () => _confirmReset(context, ref),
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSizes.md),
          AppCard(
            borderColor: AppColors.outline,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Delete the captured 360s',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSizes.xs),
                Text(
                  'Separate from the reset above, because these are real files '
                  'rather than mock objects: every panorama and every capture '
                  'bundle on this device, which is a few hundred megabytes per '
                  'sphere. Nothing is uploaded, so this cannot be undone.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.onSurfaceVariant),
                ),
                const SizedBox(height: AppSizes.md),
                AppButton(
                  label: 'Delete every captured 360',
                  variant: AppButtonVariant.destructive,
                  onPressed: () => _confirmDeleteSpheres(context, ref),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Deletes the panoramas, the bundles and the markers that point at them.
  Future<void> _confirmDeleteSpheres(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete every captured 360?'),
        content: const Text(
          'Every stitched panorama and every capture bundle is removed from '
          'this device, and their pins come off the plan. This cannot be '
          'undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep them'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: AppColors.onDangerContainer,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;

    // The queue is stopped first, so nothing writes a panorama back into a
    // directory that is being emptied.
    await ref.read(stitchQueueProvider).stop();
    await ref.read(sphereCaptureStoreProvider).clear();
    await ref.read(sphereStorageProvider).deleteEverything();
    ref.invalidate(stitchJobsProvider);
    ref.invalidate(planRepositoryProvider);

    if (!context.mounted) return;
    _say(context, 'Every captured 360 deleted.');
  }

  static void _say(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Destructive, so it asks — the same rule Settings applies to auto-delete.
  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Reset all demo data?'),
        content: const Text(
          'Every capture, issue and walk recorded since launch is discarded, '
          'and every fault switched off. This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: AppColors.onDangerContainer,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      // Bumping the generation rebuilds every repository, which is what
      // discards the saved captures, issues and walks. The rest is state that
      // lives outside a repository and has to be named.
      ref.read(demoControlsProvider.notifier).reset();
      ref
          .read(connectivityControllerProvider.notifier)
          .setStatus(ConnectivityStatus.syncing);
      ref.invalidate(cameraSessionProvider);
      ref.invalidate(uploadQueueProvider);
      ref.invalidate(captureFlowProvider);
      ref.invalidate(issueReportProvider);

      if (!context.mounted) return;
      _say(context, 'Back to the seed.');
    }
  }
}

/// Says at a glance whether the app is in a state a demo should start from.
class _FaultBanner extends StatelessWidget {
  const _FaultBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final bool clean = count == 0;
    return AppCard(
      backgroundColor:
          clean ? AppColors.successContainer : AppColors.warningContainer,
      borderColor: clean ? AppColors.success : AppColors.warning,
      child: Row(
        children: <Widget>[
          Icon(
            clean ? Icons.check_circle_outline : Icons.warning_amber_rounded,
            size: 20,
            color: clean ? AppColors.success : AppColors.onWarningContainer,
          ),
          const SizedBox(width: AppSizes.md),
          Expanded(
            child: Text(
              clean
                  ? 'No faults active — the state a demo should open in.'
                  : '$count fault${count == 1 ? '' : 's'} active. Reset before '
                      'you present.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: clean
                        ? AppColors.onSuccessContainer
                        : AppColors.onWarningContainer,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A titled card whose control is a row of chips.
class _ChipRow<T> extends StatelessWidget {
  const _ChipRow({
    required this.title,
    required this.description,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final String title;
  final String description;
  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSizes.xs),
          Text(
            description,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: AppSizes.md),
          ChipSelector<T>(
            values: values,
            selected: selected,
            labelOf: labelOf,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSizes.md),
      child: Text(
        text.toUpperCase(),
        style: AppTypography.sectionLabel
            .copyWith(color: AppColors.onSurfaceVariant),
      ),
    );
  }
}
