import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/connectivity_pill.dart';
import '../../../core/widgets/field_app_bar.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/switch_tile.dart';
import '../../../shared/connectivity/connectivity_controller.dart';
import '../../../shared/connectivity/connectivity_status.dart';
import '../../settings/state/settings_controller.dart';
import '../models/upload_item.dart';
import '../state/upload_queue_controller.dart';
import '../widgets/upload_item_tile.dart';

/// Prototype screen 19 — Upload queue.
///
/// "Everything captured sits here until it lands. Each item shows size,
/// duration, progress and — when it fails — why, with a retry countdown rather
/// than a dead end."
class UploadQueueScreen extends ConsumerWidget {
  const UploadQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<UploadItem> items = ref.watch(uploadQueueProvider);
    final UploadSummary summary = ref.watch(uploadSummaryProvider);
    final AppSettings settings = ref.watch(settingsProvider);
    final ConnectivityStatus connectivity =
        ref.watch(connectivityControllerProvider);
    final UploadQueueController controller =
        ref.read(uploadQueueProvider.notifier);

    final int pending = items.where((UploadItem i) => i.isOutstanding).length;

    return Scaffold(
      appBar: FieldAppBar(
        title: 'Upload queue',
        subtitle: pending == 0
            ? 'Everything has landed'
            : '$pending pending · uploads to the same calibration',
        trailing: const ConnectivityPill(compact: true),
      ),
      body: items.isEmpty
          ? const EmptyStateView(
              icon: Icons.cloud_done_outlined,
              title: 'Nothing waiting',
              message: 'Captures appear here the moment they are saved, and '
                  'upload themselves when the connection allows.',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSizes.screenPadding,
                AppSizes.lg,
                AppSizes.screenPadding,
                AppSizes.xxl,
              ),
              children: <Widget>[
                _SummaryCard(summary: summary, wifiOnly: settings.uploadOnWifiOnly),
                const SizedBox(height: AppSizes.cardGap),
                SwitchTile(
                  title: 'Upload on Wi-Fi only',
                  description:
                      'Uploads start automatically on a stable connection.',
                  value: settings.uploadOnWifiOnly,
                  onChanged: (bool value) => _setWifiOnly(context, ref, value),
                ),
                if (connectivity.isOffline) ...<Widget>[
                  const SizedBox(height: AppSizes.cardGap),
                  const _OfflineNotice(),
                ],
                const SizedBox(height: AppSizes.lg),
                for (final UploadItem item in items) ...<Widget>[
                  UploadItemTile(
                    item: item,
                    onPause: () => controller.pause(item.id),
                    onResume: () => controller.resume(item.id),
                    onRetry: () => controller.retry(item.id),
                  ),
                  const SizedBox(height: AppSizes.cardGap),
                ],
              ],
            ),
    );
  }

  /// "Cellular upload is an explicit opt-in" — so switching Wi-Fi-only OFF is
  /// the decision that needs confirming, not switching it on. The prototype
  /// does not draw this dialog; ASSUMPTIONS.md §H3.
  Future<void> _setWifiOnly(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    if (value) {
      ref.read(settingsProvider.notifier).setUploadOnWifiOnly(true);
      return;
    }

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Upload over mobile data?'),
        content: const Text(
          'Captures are large — a single walk can be several hundred '
          'megabytes. This will use your mobile allowance.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep Wi-Fi only'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Use mobile data'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      ref.read(settingsProvider.notifier).setUploadOnWifiOnly(false);
    }
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary, required this.wifiOnly});

  final UploadSummary summary;
  final bool wifiOnly;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  summary.isIdle
                      ? 'All ${summary.total} uploaded'
                      : 'Uploading ${summary.position} of ${summary.total}',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Text(
                Formatters.percent(summary.progress),
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: AppColors.primary),
              ),
            ],
          ),
          const SizedBox(height: AppSizes.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppSizes.radiusPill),
            child: LinearProgressIndicator(
              value: summary.progress,
              minHeight: 6,
              backgroundColor: AppColors.outlineSoft,
            ),
          ),
          const SizedBox(height: AppSizes.md),
          Text(
            summary.isIdle
                ? 'Nothing left to send'
                : '${Formatters.bytes(summary.remainingBytes)} remaining · '
                    '${wifiOnly ? 'Wi-Fi only' : 'Wi-Fi or mobile data'}',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// "Offline is a normal state in this product, not an error state" — so this
/// explains rather than alarms.
class _OfflineNotice extends StatelessWidget {
  const _OfflineNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSizes.md),
      decoration: BoxDecoration(
        color: AppColors.warningContainer,
        borderRadius: BorderRadius.circular(AppSizes.radiusCard),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.cloud_off_outlined,
            size: 18,
            color: AppColors.onWarningContainer,
          ),
          const SizedBox(width: AppSizes.sm),
          Expanded(
            child: Text(
              'No signal. Everything here is safe on this device and will '
              'upload on its own when the connection returns.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.onWarningContainer),
            ),
          ),
        ],
      ),
    );
  }
}
