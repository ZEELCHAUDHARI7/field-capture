import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/chip_selector.dart';
import '../../../core/widgets/field_app_bar.dart';
import '../../../core/widgets/switch_tile.dart';
import '../../../shared/camera/camera_controller.dart';
import '../../../shared/camera/camera_session.dart';
import '../state/settings_controller.dart';

/// Prototype screen 20 — Settings & camera pairing.
///
/// "Camera pairing, capture resolution and frame rate, upload policy and
/// storage housekeeping. The paired camera reports firmware and free space so a
/// crew can pre-flight before a walk."
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CameraSession camera = ref.watch(cameraSessionProvider);
    final AppSettings settings = ref.watch(settingsProvider);
    final SettingsController controller = ref.read(settingsProvider.notifier);
    final bool cameraConnected = camera is CameraConnected;

    return Scaffold(
      appBar: const FieldAppBar(title: 'Settings'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSizes.screenPadding,
          AppSizes.lg,
          AppSizes.screenPadding,
          AppSizes.xxl,
        ),
        children: <Widget>[
          const _SectionLabel('Camera'),
          _CameraCard(camera: camera),
          const SizedBox(height: AppSizes.xl),

          Text(
            'Capture quality',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 2),
          Text(
            cameraConnected
                ? "From the connected camera's capabilities"
                : 'Pair a 360° camera to change these',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: AppSizes.lg),

          _Field(
            label: 'Resolution',
            child: ChipSelector<CaptureResolution>(
              values: CaptureResolution.values,
              selected: settings.resolution,
              labelOf: (CaptureResolution r) => r.label,
              enabled: cameraConnected,
              onChanged: controller.setResolution,
            ),
          ),
          const SizedBox(height: AppSizes.lg),
          _Field(
            label: 'Frame rate — 360° video',
            child: ChipSelector<CaptureFrameRate>(
              values: CaptureFrameRate.values,
              selected: settings.frameRate,
              labelOf: (CaptureFrameRate f) => f.label,
              enabled: cameraConnected,
              onChanged: controller.setFrameRate,
            ),
          ),
          const SizedBox(height: AppSizes.xl),

          Text(
            'Pair new camera',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSizes.md),
          AppButton(
            label: 'Scan for 360° cameras',
            variant: AppButtonVariant.secondary,
            onPressed: () => _scan(context),
          ),
          const SizedBox(height: AppSizes.xxl),

          const _SectionLabel('Uploads & storage'),
          SwitchTile(
            title: 'Upload on Wi-Fi only',
            description: 'Uploads start automatically on a stable connection.',
            value: settings.uploadOnWifiOnly,
            onChanged: controller.setUploadOnWifiOnly,
          ),
          const SizedBox(height: AppSizes.cardGap),
          SwitchTile(
            title: 'Auto-delete local files',
            description: 'Remove captures from this device once they have '
                'landed on Asite. Off by default.',
            value: settings.autoDeleteAfterUpload,
            destructive: true,
            onChanged: (bool value) =>
                _setAutoDelete(context, controller, value),
          ),
        ],
      ),
    );
  }

  /// "Scan for 360° cameras" is a button to nowhere in the prototype — no
  /// discovery screen is drawn and no pairing protocol is named.
  /// ASSUMPTIONS.md §H5.
  void _scan(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text(
            'Camera discovery needs the Ricoh SDK — not wired up yet.',
          ),
        ),
      );
  }

  /// "Destructive settings opt in" — so turning this ON asks, turning it off
  /// does not.
  Future<void> _setAutoDelete(
    BuildContext context,
    SettingsController controller,
    bool value,
  ) async {
    if (!value) {
      controller.setAutoDeleteAfterUpload(false);
      return;
    }

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete captures after upload?'),
        content: const Text(
          'Once a capture has landed on Asite it will be removed from this '
          'device. This frees space but cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep files'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: AppColors.onDangerContainer,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Auto-delete'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) controller.setAutoDeleteAfterUpload(true);
  }
}

class _CameraCard extends ConsumerWidget {
  const _CameraCard({required this.camera});

  final CameraSession camera;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final CameraSessionController controller =
        ref.read(cameraSessionProvider.notifier);

    if (camera is! CameraConnected) {
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  height: 9,
                  width: 9,
                  decoration: const BoxDecoration(
                    color: AppColors.recording,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: AppSizes.sm),
                Text(
                  camera is CameraReconnecting
                      ? 'Reconnecting…'
                      : 'No camera connected',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: AppSizes.sm),
            Text(
              'Mobile Capture still works without one.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.onSurfaceVariant),
            ),
            const SizedBox(height: AppSizes.lg),
            AppButton(
              label: 'Reconnect',
              variant: AppButtonVariant.secondary,
              busy: camera is CameraReconnecting,
              onPressed: controller.reconnect,
            ),
          ],
        ),
      );
    }

    final CameraConnected connected = camera as CameraConnected;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                height: 9,
                width: 9,
                decoration: const BoxDecoration(
                  color: AppColors.success,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSizes.sm),
              Expanded(
                child: Text(
                  '${connected.model} · ${connected.serial}',
                  style: AppTypography.mono.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 17),
            child: Text(
              'Connected',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: AppSizes.lg),
          Row(
            children: <Widget>[
              Expanded(
                child: _Spec(label: 'Model', value: 'Ricoh Theta X'),
              ),
              Expanded(
                child: _Spec(
                  label: 'Battery',
                  value: '${connected.batteryPercent}%',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSizes.lg),
          Row(
            children: <Widget>[
              Expanded(
                child: _Spec(
                  label: 'Camera storage',
                  value: '${Formatters.bytes(connected.storageFreeBytes)} free '
                      'of ${Formatters.bytes(connected.storageTotalBytes)}',
                ),
              ),
              Expanded(
                child: _Spec(
                  label: 'Firmware',
                  value: connected.firmware,
                  monospace: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSizes.lg),
          Row(
            children: <Widget>[
              Expanded(
                child: AppButton(
                  label: 'Reconnect',
                  variant: AppButtonVariant.secondary,
                  onPressed: controller.reconnect,
                ),
              ),
              const SizedBox(width: AppSizes.md),
              Expanded(
                child: AppButton(
                  label: 'Forget Camera',
                  variant: AppButtonVariant.destructive,
                  onPressed: () => _confirmForget(context, controller),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Forget Camera is destructive and drawn with no confirmation. Given the
  /// deck's own rule that "destructive settings opt in", it gets one.
  /// ASSUMPTIONS.md §H5.
  Future<void> _confirmForget(
    BuildContext context,
    CameraSessionController controller,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Forget this camera?'),
        content: const Text(
          'The pairing is removed from this device. Video and image capture '
          'stay unavailable until a camera is paired again.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep paired'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: AppColors.onDangerContainer,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) controller.simulateDisconnect();
  }
}

class _Spec extends StatelessWidget {
  const _Spec({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: monospace
              ? AppTypography.mono
                  .copyWith(fontSize: 13, color: AppColors.onSurface)
              : theme.textTheme.titleSmall,
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: AppSizes.sm),
        child,
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSizes.md),
      child: Text(
        text.toUpperCase(),
        style: AppTypography.sectionLabel
            .copyWith(color: AppColors.onSurfaceVariant),
      ),
    );
  }
}
