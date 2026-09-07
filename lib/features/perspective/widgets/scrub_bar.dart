import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

/// The bottom bar of the 3D walk: what is being flown, how far along, and the
/// scrub itself.
///
/// One of the two axes the prototype allows. The labels are drawn as
/// START · SCRUB ALONG TRAJECTORY · END, which is worth keeping verbatim —
/// it tells the user this is the whole of their freedom of movement.
class ScrubBar extends StatelessWidget {
  const ScrubBar({
    super.key,
    required this.trajectoryName,
    required this.travelledMetres,
    required this.totalMetres,
    required this.fraction,
    required this.onChanged,
  });

  final String trajectoryName;
  final double travelledMetres;
  final double totalMetres;
  final double fraction;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return ColoredBox(
      color: AppColors.chrome,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSizes.lg,
            AppSizes.md,
            AppSizes.lg,
            AppSizes.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      trajectoryName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.mono.copyWith(
                        fontSize: 12.5,
                        color: AppColors.onChrome,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSizes.md),
                  Text(
                    '${travelledMetres.round()} m of ${totalMetres.round()} m',
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: AppColors.onChrome),
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  activeTrackColor: AppColors.captureActive,
                  inactiveTrackColor: AppColors.capturePillBorder,
                  thumbColor: AppColors.surface,
                  overlayColor: AppColors.alpha(AppColors.captureActive, 0.18),
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 9),
                ),
                child: Slider(
                  value: fraction.clamp(0.0, 1.0),
                  onChanged: onChanged,
                  // Every metre of a 23 m walk is a meaningful stop.
                  divisions: totalMetres < 2 ? null : totalMetres.round(),
                  semanticFormatterCallback: (double v) =>
                      '${(v * totalMetres).round()} of '
                      '${totalMetres.round()} metres',
                ),
              ),
              Row(
                children: <Widget>[
                  _Label('START'),
                  const Spacer(),
                  _Label('SCRUB ALONG TRAJECTORY'),
                  const Spacer(),
                  _Label('END'),
                ],
              ),
              const SizedBox(height: AppSizes.xs),
            ],
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTypography.sectionLabel.copyWith(
        fontSize: 9.5,
        color: AppColors.onChromeMuted,
      ),
    );
  }
}
