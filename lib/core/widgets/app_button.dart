import 'package:flutter/material.dart';

import '../constants/app_sizes.dart';
import '../theme/app_colors.dart';

/// The five button treatments the prototype draws.
enum AppButtonVariant {
  /// Solid blue. Sign in, Report an issue, Next — pin location.
  primary,

  /// Blue outline on transparent. Download, Reconnect, Retry now.
  secondary,

  /// White with a grey border. Cancel, Close, Discard.
  neutral,

  /// Soft red fill with deep red label. Forget Camera.
  destructive,

  /// Solid recording red, fully rounded. Stop Walking.
  recording,
}

/// A single button widget so the five treatments stay consistent and every
/// one of them clears the 48px touch-target floor.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.icon,
    this.expanded = true,
    this.busy = false,
  });

  final String label;

  /// Null disables the button. The prototype disables "Start Walking" and
  /// "Save capture" until a pin exists, so this is a real state, not an edge case.
  final VoidCallback? onPressed;

  final AppButtonVariant variant;
  final IconData? icon;
  final bool expanded;

  /// Replaces the label with a spinner and blocks input.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onPressed != null && !busy;
    final _ButtonColors colors = _colorsFor(variant, enabled);
    final TextStyle? textStyle = Theme.of(context).textTheme.labelLarge;

    final Widget content = busy
        ? SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(colors.foreground),
            ),
          )
        : Row(
            mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 18, color: colors.foreground),
                const SizedBox(width: AppSizes.sm),
              ],
              Flexible(
                child: Text(
                  label,
                  style: textStyle?.copyWith(color: colors.foreground),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          );

    final double radius = variant == AppButtonVariant.recording
        ? AppSizes.radiusPill
        : AppSizes.radiusButton;

    final Widget button = Material(
      color: colors.background,
      borderRadius: BorderRadius.circular(radius),
      // Ink wraps InkWell so the splash paints under the border, not over it.
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: colors.border == null
              ? null
              : Border.all(color: colors.border!, width: AppSizes.borderWidth),
        ),
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: BorderRadius.circular(radius),
          child: Container(
            height:
                variant == AppButtonVariant.recording ? 60 : AppSizes.buttonHeight,
            padding: const EdgeInsets.symmetric(horizontal: AppSizes.lg),
            alignment: Alignment.center,
            child: content,
          ),
        ),
      ),
    );

    if (!expanded) return button;
    return SizedBox(width: double.infinity, child: button);
  }

  _ButtonColors _colorsFor(AppButtonVariant variant, bool enabled) {
    switch (variant) {
      case AppButtonVariant.primary:
        return _ButtonColors(
          background: enabled ? AppColors.primary : AppColors.primaryDisabled,
          foreground:
              enabled ? AppColors.onPrimary : AppColors.onPrimaryDisabled,
        );
      case AppButtonVariant.secondary:
        return _ButtonColors(
          background: Colors.transparent,
          foreground: enabled ? AppColors.primary : AppColors.onSurfaceVariant,
          border: enabled ? AppColors.primary : AppColors.outline,
        );
      case AppButtonVariant.neutral:
        return _ButtonColors(
          background: AppColors.surface,
          foreground: enabled ? AppColors.onSurface : AppColors.onSurfaceVariant,
          border: AppColors.outline,
        );
      case AppButtonVariant.destructive:
        return _ButtonColors(
          background: AppColors.dangerContainer,
          foreground: enabled
              ? AppColors.onDangerContainer
              : AppColors.onSurfaceVariant,
        );
      case AppButtonVariant.recording:
        return const _ButtonColors(
          background: AppColors.recording,
          foreground: AppColors.onPrimary,
        );
    }
  }
}

class _ButtonColors {
  const _ButtonColors({
    required this.background,
    required this.foreground,
    this.border,
  });

  final Color background;
  final Color foreground;
  final Color? border;
}
