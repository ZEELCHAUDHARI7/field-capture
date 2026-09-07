import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../models/calibration.dart';
import 'download_state_widget.dart';

/// One row on prototype screen 03 — Calibration list.
class CalibrationCard extends StatelessWidget {
  const CalibrationCard({
    super.key,
    required this.calibration,
    required this.onOpen,
    required this.onDownload,
  });

  final Calibration calibration;

  /// Only fires when the bundle is available offline. Opening an undownloaded
  /// calibration is blocked with a message — stated in the prototype.
  final VoidCallback onOpen;

  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DownloadState download = calibration.download;

    return AppCard(
      onTap: onOpen,
      semanticLabel: '${calibration.name}, '
          '${Formatters.bytes(calibration.sizeBytes)}, '
          '${_stateLabel(download)}',
      child: Row(
        children: <Widget>[
          const _PlanThumbnail(),
          const SizedBox(width: AppSizes.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(calibration.name, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  '${Formatters.bytes(calibration.sizeBytes)} · '
                  'updated ${Formatters.dayMonth(calibration.updatedAt)}',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: AppColors.onSurfaceVariant),
                ),
                if (download is Downloaded) ...<Widget>[
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      const Icon(
                        Icons.check,
                        size: 15,
                        color: AppColors.success,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Available offline',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: AppColors.success),
                      ),
                    ],
                  ),
                ],
                if (download is DownloadFailed) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    download.reason,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: AppColors.onDangerContainer),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSizes.md),
          DownloadStateWidget(
            state: download,
            sizeBytes: calibration.sizeBytes,
            onDownload: onDownload,
          ),
        ],
      ),
    );
  }

  String _stateLabel(DownloadState state) => switch (state) {
        Downloaded() => 'available offline',
        NotDownloaded() => 'not downloaded',
        Downloading(:final double progress) =>
          'downloading ${Formatters.percent(progress)}',
        DownloadFailed() => 'download failed',
      };
}

/// The small plan glyph on each row.
///
/// ASSUMED — the prototype shows a generic line drawing of a floor plan. Real
/// plan thumbnails arrive with the bundle format decision (see ASSUMPTIONS.md).
class _PlanThumbnail extends StatelessWidget {
  const _PlanThumbnail();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AppSizes.thumbnail,
      width: AppSizes.thumbnail,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSizes.radiusThumbnail),
        border: Border.all(color: AppColors.outline),
      ),
      child: const Icon(
        Icons.grid_on_outlined,
        size: 22,
        color: AppColors.onSurfaceVariant,
      ),
    );
  }
}
