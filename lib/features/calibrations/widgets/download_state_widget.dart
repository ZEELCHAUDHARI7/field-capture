import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/calibration.dart';

/// The trailing control on a calibration row, which is one of four things
/// depending on the bundle's download state.
///
/// Prototype screen 03 draws three of them; DownloadFailed is ASSUMED.
class DownloadStateWidget extends StatelessWidget {
  const DownloadStateWidget({
    super.key,
    required this.state,
    required this.sizeBytes,
    required this.onDownload,
  });

  final DownloadState state;
  final int sizeBytes;

  /// Starts a download, or resumes a failed one.
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    switch (state) {
      case Downloaded():
        return const Icon(
          Icons.chevron_right,
          size: 20,
          color: AppColors.onSurfaceVariant,
        );

      case NotDownloaded():
        return _DownloadButton(
          label: Formatters.bytes(sizeBytes),
          onPressed: onDownload,
        );

      case Downloading(:final double progress):
        return SizedBox(
          width: 84,
          child: Semantics(
            label: 'Downloading, ${Formatters.percent(progress)}',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppSizes.radiusPill),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 5,
                    backgroundColor: AppColors.outlineSoft,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  Formatters.percent(progress),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: AppColors.primary),
                ),
              ],
            ),
          ),
        );

      case DownloadFailed(:final double resumeFrom):
        return _DownloadButton(
          label: 'Resume',
          icon: Icons.refresh,
          onPressed: onDownload,
          semanticLabel:
              'Download failed at ${Formatters.percent(resumeFrom)}. Resume.',
        );
    }
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({
    required this.label,
    required this.onPressed,
    this.icon = Icons.download_outlined,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData icon;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      child: SizedBox(
        height: AppSizes.minTouchTarget,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 17),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(horizontal: AppSizes.md),
            side: const BorderSide(color: AppColors.primary),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppSizes.radiusButton),
            ),
            textStyle: Theme.of(context).textTheme.labelMedium,
          ),
        ),
      ),
    );
  }
}
