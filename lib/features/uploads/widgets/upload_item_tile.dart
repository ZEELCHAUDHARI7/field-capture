import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/status_badge.dart';
import '../../plan/models/plan_marker.dart';
import '../models/upload_item.dart';

/// One row on prototype screen 19 — Upload queue.
///
/// "Each item shows size, duration, progress and — when it fails — why, with a
/// retry countdown rather than a dead end."
class UploadItemTile extends StatelessWidget {
  const UploadItemTile({
    super.key,
    required this.item,
    required this.onPause,
    required this.onResume,
    required this.onRetry,
  });

  final UploadItem item;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return AppCard(
      semanticLabel: '${item.name}, ${_statusLabel()}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _MediaThumbnail(mode: item.mode),
              const SizedBox(width: AppSizes.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.mono.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _metaLine(),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSizes.sm),
              _Trailing(
                item: item,
                onPause: onPause,
                onResume: onResume,
              ),
            ],
          ),
          if (item.status == UploadStatus.uploading) ...<Widget>[
            const SizedBox(height: AppSizes.md),
            Row(
              children: <Widget>[
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppSizes.radiusPill),
                    child: LinearProgressIndicator(
                      value: item.progress,
                      minHeight: 5,
                      backgroundColor: AppColors.outlineSoft,
                    ),
                  ),
                ),
                const SizedBox(width: AppSizes.md),
                Text(
                  Formatters.percent(item.progress),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: AppColors.primary),
                ),
              ],
            ),
          ],
          if (item.status == UploadStatus.failed) ...<Widget>[
            const SizedBox(height: AppSizes.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${item.failureReason ?? 'Upload failed'}'
                    '${item.retryInSeconds == null ? '' : ' · Auto-retry in ${item.retryInSeconds}s'}',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: AppColors.onDangerContainer),
                  ),
                ),
                const SizedBox(width: AppSizes.md),
                SizedBox(
                  height: 38,
                  child: OutlinedButton(
                    onPressed: onRetry,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 38),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSizes.md,
                      ),
                      textStyle: theme.textTheme.labelMedium,
                    ),
                    child: const Text('Retry now'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _metaLine() {
    final String size = Formatters.bytes(item.sizeBytes);
    final String? duration = item.duration == null
        ? null
        : Formatters.elapsed(item.duration!);
    return <String>[
      size,
      if (duration != null) duration,
      item.mode.mediaLabel,
    ].join(' · ');
  }

  String _statusLabel() => switch (item.status) {
        UploadStatus.uploading =>
          'uploading ${Formatters.percent(item.progress)}',
        UploadStatus.waiting => 'waiting',
        UploadStatus.paused => 'paused',
        UploadStatus.failed => 'failed',
        UploadStatus.uploaded => 'uploaded',
      };
}

class _Trailing extends StatelessWidget {
  const _Trailing({
    required this.item,
    required this.onPause,
    required this.onResume,
  });

  final UploadItem item;
  final VoidCallback onPause;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    switch (item.status) {
      case UploadStatus.uploaded:
        return const StatusBadge(
          label: 'Uploaded',
          tone: BadgeTone.success,
          icon: Icons.check,
        );

      case UploadStatus.failed:
        return const StatusBadge(label: 'Failed', tone: BadgeTone.danger);

      case UploadStatus.uploading:
        return _IconAction(
          icon: Icons.pause,
          tooltip: 'Pause upload',
          onPressed: onPause,
        );

      case UploadStatus.waiting:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const StatusBadge(label: 'Waiting'),
            const SizedBox(width: AppSizes.xs),
            _IconAction(
              icon: Icons.pause,
              tooltip: 'Pause upload',
              onPressed: onPause,
            ),
          ],
        );

      case UploadStatus.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const StatusBadge(label: 'Paused', tone: BadgeTone.warning),
            const SizedBox(width: AppSizes.xs),
            _IconAction(
              icon: Icons.play_arrow,
              tooltip: 'Resume upload',
              onPressed: onResume,
            ),
          ],
        );
    }
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppSizes.minTouchTarget,
      width: AppSizes.minTouchTarget,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon),
        iconSize: 20,
        color: AppColors.onSurface,
        tooltip: tooltip,
        style: IconButton.styleFrom(
          side: const BorderSide(color: AppColors.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSizes.radiusButton),
          ),
        ),
      ),
    );
  }
}

class _MediaThumbnail extends StatelessWidget {
  const _MediaThumbnail({required this.mode});

  final CaptureMode mode;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: AppSizes.thumbnail,
      width: AppSizes.thumbnail,
      decoration: BoxDecoration(
        color: AppColors.thumbnailPlaceholder,
        borderRadius: BorderRadius.circular(AppSizes.radiusThumbnail),
      ),
      child: Icon(
        switch (mode) {
          CaptureMode.video => Icons.videocam_outlined,
          CaptureMode.image => Icons.photo_camera_outlined,
          CaptureMode.mobile => Icons.language_outlined,
        },
        size: 20,
        color: AppColors.onSurfaceVariant,
      ),
    );
  }
}
