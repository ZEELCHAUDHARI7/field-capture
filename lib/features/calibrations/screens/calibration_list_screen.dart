import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/routing/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/connectivity_pill.dart';
import '../../../core/widgets/field_app_bar.dart';
import '../../../core/widgets/state_views.dart';
import '../../projects/models/project.dart';
import '../../projects/state/projects_controller.dart';
import '../models/calibration.dart';
import '../state/calibrations_controller.dart';
import '../widgets/calibration_card.dart';

/// Prototype screen 03 — Calibration list.
///
/// "Calibrations are read-only bundles authored on Asite web. Each one
/// downloads explicitly, with size and progress shown, because site
/// connectivity is the scarce resource."
class CalibrationListScreen extends ConsumerWidget {
  const CalibrationListScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Project? project = ref.watch(projectByIdProvider(projectId));
    final AsyncValue<List<Calibration>> calibrations =
        ref.watch(calibrationsControllerProvider(projectId));
    final CalibrationsController controller =
        ref.read(calibrationsControllerProvider(projectId).notifier);

    return Scaffold(
      appBar: FieldAppBar(
        title: project?.name ?? 'Calibrations',
        subtitle: 'Calibrations · plans for offline capture',
        trailing: const ConnectivityPill(compact: true),
      ),
      body: calibrations.when(
        loading: () => const LoadingListView(rowHeight: 80),
        error: (Object error, StackTrace _) => ErrorStateView(
          title: 'Could not load calibrations',
          message: 'The app could not reach Asite. Bundles already downloaded '
              'are still available for capture.',
          onRetry: controller.refresh,
        ),
        data: (List<Calibration> items) {
          if (items.isEmpty) {
            return EmptyStateView(
              icon: Icons.layers_outlined,
              title: 'No calibrations yet',
              message: 'This project has no published plans. Calibrations are '
                  'authored on Asite web and appear here once published.',
              actionLabel: 'Check again',
              onAction: controller.refresh,
            );
          }

          return RefreshIndicator(
            color: AppColors.primary,
            onRefresh: controller.refresh,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                AppSizes.screenPadding,
                AppSizes.lg,
                AppSizes.screenPadding,
                AppSizes.xxl,
              ),
              itemCount: items.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppSizes.cardGap),
              itemBuilder: (BuildContext context, int index) {
                final Calibration calibration = items[index];
                return CalibrationCard(
                  calibration: calibration,
                  onDownload: () => controller.startDownload(calibration.id),
                  onOpen: () => _open(context, controller, calibration),
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// "Opening an undownloaded calibration is blocked with a toast, not a
  /// silent failure." — stated in the prototype.
  void _open(
    BuildContext context,
    CalibrationsController controller,
    Calibration calibration,
  ) {
    if (calibration.isAvailableOffline) {
      context.push(Routes.workspaceFor(calibration.id));
      return;
    }

    final DownloadState download = calibration.download;
    final String message = download is Downloading
        ? '${calibration.name} is still downloading.'
        : 'Download ${calibration.name} before capturing against it.';

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: download is Downloading
              ? null
              : SnackBarAction(
                  label: 'Download',
                  onPressed: () => controller.startDownload(calibration.id),
                ),
        ),
      );
  }
}
