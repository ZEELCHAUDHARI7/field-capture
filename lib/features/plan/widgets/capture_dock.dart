import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../models/plan_marker.dart';

/// The dark dock holding the three capture modes.
///
/// Video and Image need the 360° camera and go flat and unlabelled-bright when
/// it drops. Mobile Capture never needed it, so it stays fully enabled — that
/// contrast is the whole point of the camera-lost state.
class CaptureDock extends StatelessWidget {
  const CaptureDock({
    super.key,
    required this.cameraConnected,
    required this.onSelect,
    required this.onBlocked,
  });

  final bool cameraConnected;
  final ValueChanged<CaptureMode> onSelect;

  /// Tapping a camera-dependent mode while the camera is offline. The
  /// prototype says these modes "stay visible but refuse politely".
  final ValueChanged<CaptureMode> onBlocked;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.chrome,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSizes.md,
            AppSizes.md,
            AppSizes.md,
            AppSizes.md,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: _DockTile(
                  mode: CaptureMode.video,
                  icon: Icons.videocam_outlined,
                  enabled: cameraConnected,
                  onSelect: onSelect,
                  onBlocked: onBlocked,
                ),
              ),
              const SizedBox(width: AppSizes.sm),
              Expanded(
                child: _DockTile(
                  mode: CaptureMode.image,
                  icon: Icons.photo_camera_outlined,
                  enabled: cameraConnected,
                  onSelect: onSelect,
                  onBlocked: onBlocked,
                ),
              ),
              const SizedBox(width: AppSizes.sm),
              Expanded(
                child: _DockTile(
                  mode: CaptureMode.mobile,
                  icon: Icons.language_outlined,
                  enabled: true,
                  badge: 'LiDAR',
                  onSelect: onSelect,
                  onBlocked: onBlocked,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DockTile extends StatelessWidget {
  const _DockTile({
    required this.mode,
    required this.icon,
    required this.enabled,
    required this.onSelect,
    required this.onBlocked,
    this.badge,
  });

  final CaptureMode mode;
  final IconData icon;
  final bool enabled;
  final String? badge;
  final ValueChanged<CaptureMode> onSelect;
  final ValueChanged<CaptureMode> onBlocked;

  @override
  Widget build(BuildContext context) {
    final Color foreground =
        enabled ? AppColors.onChrome : AppColors.onChromeMuted;

    return Semantics(
      button: true,
      enabled: enabled,
      label: enabled
          ? mode.label
          : '${mode.label}, unavailable while the camera is offline',
      child: Material(
        color: enabled
            ? AppColors.chromeElevated
            : AppColors.alpha(AppColors.chromeElevated, 0.45),
        borderRadius: BorderRadius.circular(AppSizes.radiusCard),
        child: InkWell(
          // Still tappable when disabled — the prototype refuses with a
          // message rather than swallowing the tap.
          onTap: () => enabled ? onSelect(mode) : onBlocked(mode),
          borderRadius: BorderRadius.circular(AppSizes.radiusCard),
          child: Container(
            height: 70,
            alignment: Alignment.center,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: <Widget>[
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(icon, size: 22, color: foreground),
                    const SizedBox(height: 6),
                    Text(
                      mode.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .labelMedium
                          ?.copyWith(color: foreground),
                    ),
                  ],
                ),
                if (badge != null)
                  Positioned(
                    top: -2,
                    right: -2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius:
                            BorderRadius.circular(AppSizes.radiusPill),
                      ),
                      child: Text(
                        badge!,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(
                              color: AppColors.onPrimary,
                              fontSize: 9.5,
                            ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
