import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_button.dart';
import '../../../shared/camera/camera_controller.dart';
import '../../../shared/camera/camera_session.dart';
import '../models/capture_draft.dart';
import '../state/capture_flow_controller.dart';
import '../widgets/capture_chrome.dart';

/// Prototype screen 08 — Recording a walk.
///
/// "During a video walk the screen goes to camera chrome: elapsed time, a live
/// recording indicator, and the walk name. Waypoints can be dropped without
/// leaving the recording."
///
/// The screen owns no state. It renders the capture flow and pops itself the
/// moment the flow leaves the recording phase, so the machine — not the
/// navigator — decides what is happening.
class RecordingScreen extends ConsumerWidget {
  const RecordingScreen({super.key});

  /// Below this, the storage warning appears. The prototype says "storage
  /// warnings surface here, before the card fills" without naming a threshold.
  /// ASSUMPTIONS.md §G5.
  static const int lowStorageBytes = 8 * 1000 * 1000 * 1000;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CaptureFlow flow = ref.watch(captureFlowProvider);
    final CaptureFlowController controller =
        ref.read(captureFlowProvider.notifier);
    final CameraSession camera = ref.watch(cameraSessionProvider);

    // The flow left the recording phase — the walk was stopped, discarded, or
    // a waypoint was requested. Hand the screen back.
    ref.listen<CaptureFlow>(captureFlowProvider,
        (CaptureFlow? previous, CaptureFlow next) {
      if (next.phase != CapturePhase.recording && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });

    final CaptureDraft? draft = flow.draft;
    if (draft == null || flow.phase != CapturePhase.recording) {
      return const _EmptyCaptureScaffold();
    }

    final int freeBytes = camera is CameraConnected
        ? camera.storageFreeBytes
        : 0;
    final bool lowStorage = freeBytes > 0 && freeBytes < lowStorageBytes;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: PopScope(
        // Back must not silently abandon a recording in progress.
        canPop: false,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (!didPop) _confirmDiscard(context, controller);
        },
        child: Scaffold(
          backgroundColor: AppColors.captureBackdrop,
          body: Stack(
            children: <Widget>[
              const Positioned.fill(child: LivePreviewBackdrop()),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(AppSizes.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Wrap(
                        spacing: AppSizes.sm,
                        runSpacing: AppSizes.sm,
                        children: <Widget>[
                          CapturePill(
                            label: Formatters.elapsed(draft.elapsed),
                            leadingDot: AppColors.recording,
                            monospace: true,
                          ),
                          if (camera is CameraConnected)
                            CapturePill(
                              label: '${camera.model} · ${camera.serial}',
                              monospace: true,
                            ),
                          if (camera is CameraConnected)
                            CapturePill(
                              label: '${camera.batteryPercent}%',
                              icon: Icons.battery_std_outlined,
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSizes.sm),
                      Row(
                        children: <Widget>[
                          CapturePill(
                            label: '${Formatters.bytes(freeBytes)} free',
                            icon: Icons.sd_storage_outlined,
                          ),
                          if (lowStorage) ...<Widget>[
                            const SizedBox(width: AppSizes.sm),
                            const _StorageWarning(),
                          ],
                        ],
                      ),
                      const Spacer(),
                      Text(
                        draft.name,
                        style: AppTypography.mono.copyWith(
                          fontSize: 12,
                          color: AppColors.alpha(AppColors.onChrome, 0.75),
                        ),
                      ),
                      const SizedBox(height: AppSizes.lg),
                      _RecordingControls(
                        onDiscard: () => _confirmDiscard(context, controller),
                        onStop: controller.stopWalking,
                        onWaypoint: controller.requestWaypoint,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "Confirmation is the only place a walk is discarded" — so Discard asks
  /// first. The prototype does not draw this dialog; ASSUMPTIONS.md §G6.
  Future<void> _confirmDiscard(
    BuildContext context,
    CaptureFlowController controller,
  ) async {
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Discard this walk?'),
        content: const Text(
          'The recording and every waypoint dropped so far are lost. '
          'Nothing is uploaded.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep recording'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: AppColors.onDangerContainer,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );

    if (discard ?? false) controller.discard();
  }
}

class _RecordingControls extends StatelessWidget {
  const _RecordingControls({
    required this.onDiscard,
    required this.onStop,
    required this.onWaypoint,
  });

  final VoidCallback onDiscard;
  final VoidCallback onStop;
  final VoidCallback onWaypoint;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: _ChromeButton(
            label: 'Discard',
            onPressed: onDiscard,
          ),
        ),
        const SizedBox(width: AppSizes.md),
        Expanded(
          flex: 2,
          child: AppButton(
            label: 'Stop Walking',
            icon: Icons.stop_rounded,
            variant: AppButtonVariant.recording,
            onPressed: onStop,
          ),
        ),
        const SizedBox(width: AppSizes.md),
        Expanded(
          child: _ChromeButton(
            label: 'Waypoint',
            icon: Icons.flag_outlined,
            onPressed: onWaypoint,
          ),
        ),
      ],
    );
  }
}

class _ChromeButton extends StatelessWidget {
  const _ChromeButton({
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.capturePill,
      borderRadius: BorderRadius.circular(AppSizes.radiusButton),
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppSizes.radiusButton),
          border: Border.all(color: AppColors.capturePillBorder),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppSizes.radiusButton),
          child: Container(
            height: 60,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 18, color: AppColors.onChrome),
                  const SizedBox(height: 4),
                ],
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: AppColors.onChrome),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StorageWarning extends StatelessWidget {
  const _StorageWarning();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: AppSizes.md),
      decoration: BoxDecoration(
        color: AppColors.alpha(AppColors.recording, 0.18),
        borderRadius: BorderRadius.circular(AppSizes.radiusPill),
        border: Border.all(color: AppColors.recording),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.warning_amber_rounded,
            size: 14,
            color: AppColors.recording,
          ),
          const SizedBox(width: 6),
          Text(
            'Storage low',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppColors.recording,
                ),
          ),
        ],
      ),
    );
  }
}

/// Reached only if the route is opened without a capture in flight — a deep
/// link, or a restart mid-walk. Says so rather than showing empty chrome.
class _EmptyCaptureScaffold extends StatelessWidget {
  const _EmptyCaptureScaffold();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.captureBackdrop,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'No capture in progress',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: AppColors.onChrome),
              ),
              const SizedBox(height: AppSizes.sm),
              Text(
                'Start one from the capture dock on a level.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppColors.onChromeMuted),
              ),
              const SizedBox(height: AppSizes.xl),
              AppButton(
                label: 'Back to the plan',
                expanded: false,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
