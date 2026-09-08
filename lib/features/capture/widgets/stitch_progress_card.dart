import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../models/stitch_job.dart';

/// What a stitch is doing, over the plan, without stopping anybody using it.
///
/// Deliberately not a dialog. A stitch takes up to a minute and a site walk has
/// thirty stations, so a modal here is half an hour of standing still — the
/// crew is meant to be walking to the next station while this runs. The pin is
/// already on the plan; this only says how the panorama behind it is getting on.
///
/// Styled on [CameraLostCard], which is this codebase's existing answer to
/// "something floats over the plan and does not block it".
class StitchProgressCard extends StatelessWidget {
  const StitchProgressCard({
    super.key,
    required this.job,
    required this.onDismiss,
    required this.onRetry,
    this.onView,
  });

  final StitchJob job;

  /// Takes the card away. The panorama and the queue entry are untouched.
  final VoidCallback onDismiss;

  /// Puts a failed entry back with a fresh attempt budget. Offered rather than
  /// automatic: a queue that retries forever is a tablet that gets warm in a
  /// bag, and the useful moment is after the device has cooled or after
  /// whatever was competing for memory has been closed.
  final VoidCallback onRetry;

  /// Opens whatever is viewable — the preview while the full pass is still
  /// running, the panorama once it lands.
  final VoidCallback? onView;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool failed = job.isFailed;

    return Container(
      padding: const EdgeInsets.all(AppSizes.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSizes.radiusCard),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: AppColors.shadow,
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Semantics(
        liveRegion: true,
        label: failed
            ? '${job.captureName}, stitch failed'
            : '${job.captureName}, stitching, '
                '${Formatters.percent(job.fraction)}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  failed
                      ? Icons.warning_amber_rounded
                      : Icons.blur_circular_outlined,
                  size: 20,
                  color: failed
                      ? AppColors.onDangerContainer
                      : AppColors.primary,
                ),
                const SizedBox(width: AppSizes.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        job.captureName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.mono.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        job.statusLine,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: failed
                              ? AppColors.onDangerContainer
                              : AppColors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!failed && !job.done)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSizes.sm),
                    child: Text(
                      Formatters.percent(job.fraction),
                      style: AppTypography.mono.copyWith(fontSize: 12),
                    ),
                  ),
                IconButton(
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Dismiss',
                  constraints: const BoxConstraints(
                    minWidth: AppSizes.minTouchTarget,
                    minHeight: AppSizes.minTouchTarget,
                  ),
                ),
              ],
            ),
            if (!failed) ...<Widget>[
              const SizedBox(height: AppSizes.sm),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppSizes.radiusPill),
                child: LinearProgressIndicator(
                  // Null while the entry is queued behind another one: an
                  // indeterminate bar is honest about "not started", where 0%
                  // reads as "started and stuck".
                  value: job.done
                      ? 1
                      : (job.fraction > 0 ? job.fraction : null),
                  minHeight: 5,
                  backgroundColor: AppColors.capturePillBorder,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    AppColors.captureActive,
                  ),
                ),
              ),
            ],
            // Gated on there being something to open, not on the preview
            // having landed. The preview pass is allowed to fail silently — it
            // is a convenience, not the deliverable — and when it does, the
            // full panorama still arrives and must still be reachable.
            if (failed || onView != null) ...<Widget>[
              const SizedBox(height: AppSizes.sm),
              Row(
                children: <Widget>[
                  if (failed)
                    TextButton(
                      onPressed: onRetry,
                      child: const Text('Retry the stitch'),
                    ),
                  if (onView != null)
                    TextButton(
                      onPressed: onView,
                      child: Text(
                        job.done ? 'View the panorama' : 'View the preview',
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
