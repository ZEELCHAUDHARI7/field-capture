import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/connectivity_pill.dart';
import '../../../shared/camera/camera_controller.dart';
import '../../../shared/camera/camera_session.dart';

/// The strip under the app bar: the camera chip on the left, connectivity on
/// the right.
///
/// The chip is the pre-flight check — "the camera chip reports pairing and
/// battery". When the camera drops it turns red and becomes the reconnect
/// affordance: "Camera offline — tap to reconnect".
class CameraStatusBar extends ConsumerWidget {
  const CameraStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CameraSession session = ref.watch(cameraSessionProvider);

    return ColoredBox(
      color: AppColors.chrome,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSizes.lg,
          0,
          AppSizes.md,
          AppSizes.md,
        ),
        child: Row(
          children: <Widget>[
            Expanded(child: _CameraChip(session: session)),
            const SizedBox(width: AppSizes.sm),
            const ConnectivityPill(compact: true),
          ],
        ),
      ),
    );
  }
}

class _CameraChip extends ConsumerWidget {
  const _CameraChip({required this.session});

  final CameraSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CameraSessionController controller =
        ref.read(cameraSessionProvider.notifier);

    final (Color background, Color dot, String label, bool mono) =
        switch (session) {
      CameraConnected(
        :final String model,
        :final String serial,
        :final int batteryPercent,
      ) =>
        (
          const Color(0xFF0F2F33),
          AppColors.liveDot,
          '$model · $serial · $batteryPercent%',
          true,
        ),
      CameraDisconnected() => (
          const Color(0xFF2E202F),
          AppColors.recording,
          'Camera offline — tap to reconnect',
          false,
        ),
      CameraReconnecting() => (
          AppColors.chromeElevated,
          AppColors.warning,
          'Reconnecting…',
          false,
        ),
    };

    return Semantics(
      button: !session.isConnected,
      label: session is CameraDisconnected
          ? '360 camera offline. Tap to reconnect.'
          : label,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(AppSizes.radiusPill),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppSizes.radiusPill),
          onTap: session is CameraDisconnected ? controller.reconnect : null,
          // QA hook: long-press drops the camera so the lost state is
          // reachable without unplugging hardware. Removed with the mock.
          onLongPress: controller.simulateToggle,
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: AppSizes.md),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  height: 8,
                  width: 8,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: AppSizes.sm),
                const Icon(
                  Icons.adjust,
                  size: 15,
                  color: AppColors.onChrome,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono
                        ? AppTypography.mono.copyWith(
                            fontSize: 12,
                            color: AppColors.onChrome,
                          )
                        : Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: AppColors.onChrome,
                              fontWeight: FontWeight.w600,
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
