import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_button.dart';
import '../../../shared/camera/camera_controller.dart';

/// Discovery for "Scan for 360° cameras".
///
/// The deck draws the button and names no pairing protocol behind it
/// (ASSUMPTIONS.md §C14), so the button used to answer a tap with a snackbar.
/// Pairing is the first thing a crew does with this app, which makes it worth
/// showing rather than apologising for.
///
/// PHASE 6 MOCK. Nothing touches Wi-Fi and no Ricoh SDK is linked: the scan is
/// a timer and the camera it finds is the one `CameraSessionController` already
/// describes. The shape — scan, list, pair — is what the real discovery will
/// replace, and only this file changes when it does.
class CameraScanSheet extends ConsumerStatefulWidget {
  const CameraScanSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      barrierColor: AppColors.scrim,
      builder: (BuildContext context) => const CameraScanSheet(),
    );
  }

  @override
  ConsumerState<CameraScanSheet> createState() => _CameraScanSheetState();
}

class _CameraScanSheetState extends ConsumerState<CameraScanSheet> {
  Timer? _scan;
  bool _found = false;

  @override
  void initState() {
    super.initState();
    _scan = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _found = true);
    });
  }

  @override
  void dispose() {
    _scan?.cancel();
    super.dispose();
  }

  void _pair() {
    // Captured before the pop — afterwards this context is on its way out.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    ref.read(cameraSessionProvider.notifier).pair();
    Navigator.of(context).pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Paired with THETA X · R0110482.')),
      );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Pair a 360° camera', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSizes.xs),
            Text(
              _found
                  ? 'One camera on this network.'
                  : 'Looking for cameras on this Wi-Fi network.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.onSurfaceVariant),
            ),
            const SizedBox(height: AppSizes.xl),
            if (_found) const _FoundCamera() else const _Scanning(),
            const SizedBox(height: AppSizes.xl),
            Row(
              children: <Widget>[
                Expanded(
                  child: AppButton(
                    label: 'Cancel',
                    variant: AppButtonVariant.neutral,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: AppSizes.md),
                Expanded(
                  child: AppButton(
                    label: 'Pair',
                    onPressed: _found ? _pair : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Scanning extends StatelessWidget {
  const _Scanning();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: AppSizes.md),
        Text(
          'Scanning…',
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: AppColors.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The one camera the mock session describes.
class _FoundCamera extends StatelessWidget {
  const _FoundCamera();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppSizes.radiusCard),
        border: Border.all(color: AppColors.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.cardPadding),
        child: Row(
          children: <Widget>[
            const Icon(
              Icons.camera_outlined,
              color: AppColors.primary,
              size: 22,
            ),
            const SizedBox(width: AppSizes.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'THETA X',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    'R0110482',
                    style: AppTypography.mono
                        .copyWith(color: AppColors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
