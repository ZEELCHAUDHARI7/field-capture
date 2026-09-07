import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_button.dart';

/// The bar that replaces the capture dock during a pin mode.
///
/// Sits on the dark chrome so the plan above it keeps every pixel it can, and
/// carries either one full-width action or a cancel/confirm pair.
class PinModeActionBar extends StatelessWidget {
  const PinModeActionBar({
    super.key,
    required this.confirmLabel,
    required this.onConfirm,
    this.cancelLabel,
    this.onCancel,
    this.confirmIsDestructive = false,
    this.showRecordingDot = false,
  });

  /// A single full-width action — "Back to recording — no waypoint".
  const PinModeActionBar.single({
    super.key,
    required this.confirmLabel,
    required this.onConfirm,
    this.showRecordingDot = false,
  })  : cancelLabel = null,
        onCancel = null,
        confirmIsDestructive = false;

  final String confirmLabel;

  /// Null disables the confirm button — the prototype leaves "Start Walking"
  /// and "Save capture" disabled until a pin exists.
  final VoidCallback? onConfirm;

  final String? cancelLabel;
  final VoidCallback? onCancel;
  final bool confirmIsDestructive;
  final bool showRecordingDot;

  @override
  Widget build(BuildContext context) {
    final bool hasCancel = cancelLabel != null && onCancel != null;

    return ColoredBox(
      color: AppColors.chrome,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.md),
          child: Row(
            children: <Widget>[
              if (hasCancel) ...<Widget>[
                Expanded(
                  child: _DarkButton(label: cancelLabel!, onPressed: onCancel!),
                ),
                const SizedBox(width: AppSizes.md),
              ],
              Expanded(
                flex: hasCancel ? 2 : 1,
                child: showRecordingDot
                    ? _DarkButton(
                        label: confirmLabel,
                        onPressed: onConfirm,
                        leadingDot: AppColors.recording,
                      )
                    : AppButton(
                        label: confirmLabel,
                        onPressed: onConfirm,
                        variant: confirmIsDestructive
                            ? AppButtonVariant.destructive
                            : AppButtonVariant.primary,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cancel and Discard on the dark bar: navy fill, white label, hairline border.
class _DarkButton extends StatelessWidget {
  const _DarkButton({
    required this.label,
    required this.onPressed,
    this.leadingDot,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color? leadingDot;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null;

    return Material(
      color: AppColors.chrome,
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
            height: AppSizes.buttonHeight,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: AppSizes.md),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (leadingDot != null) ...<Widget>[
                  Container(
                    height: 8,
                    width: 8,
                    decoration: BoxDecoration(
                      color: leadingDot,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: AppSizes.sm),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: enabled
                              ? AppColors.onChrome
                              : AppColors.onChromeMuted,
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
