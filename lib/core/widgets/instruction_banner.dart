import 'package:flutter/material.dart';

import '../constants/app_sizes.dart';
import '../theme/app_colors.dart';

/// The full-width blue banner that heads every pin mode.
///
/// Square, edge to edge, directly under the camera status strip — it replaces
/// the tab bar rather than floating over the plan, so the crew can see at a
/// glance that the screen is asking for something.
class InstructionBanner extends StatelessWidget {
  const InstructionBanner({
    super.key,
    required this.message,
    this.icon = Icons.location_on_outlined,
    this.recording = false,
  });

  final String message;
  final IconData icon;

  /// Shows the live recording dot — used while a waypoint is being placed,
  /// because "recording continues while the waypoint is placed".
  final bool recording;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: ColoredBox(
        color: AppColors.primary,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSizes.lg,
            AppSizes.md,
            AppSizes.lg,
            AppSizes.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (recording)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: _RecordingDot(),
                )
              else
                Icon(icon, size: 18, color: AppColors.onChrome),
              const SizedBox(width: AppSizes.md),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: AppColors.onChrome,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecordingDot extends StatelessWidget {
  const _RecordingDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 10,
      width: 10,
      decoration: const BoxDecoration(
        color: AppColors.recording,
        shape: BoxShape.circle,
      ),
    );
  }
}
