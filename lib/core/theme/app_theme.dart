import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants/app_sizes.dart';
import 'app_colors.dart';
import 'app_typography.dart';

/// The single ThemeData for the app.
///
/// Decision (approved): Material 3 components restyled with the prototype's
/// measured tokens. The app looks like the iOS deck but behaves like Android —
/// hardware back, ripples, and system insets all work natively.
///
/// The prototype is light-only. No dark theme is defined until Asite specifies
/// one; a construction site in daylight is the design constraint.
abstract final class AppTheme {
  static ThemeData get light {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      surface: AppColors.surface,
      onSurface: AppColors.onSurface,
      onSurfaceVariant: AppColors.onSurfaceVariant,
      outline: AppColors.outline,
      outlineVariant: AppColors.outlineSoft,
      error: AppColors.onDangerContainer,
      errorContainer: AppColors.dangerContainer,
      onErrorContainer: AppColors.onDangerContainer,
      shadow: AppColors.shadow,
      scrim: AppColors.scrim,
    );

    final TextTheme text = AppTypography.textTheme.apply(
      bodyColor: AppColors.onSurface,
      displayColor: AppColors.onSurface,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: text,
      scaffoldBackgroundColor: AppColors.background,
      splashFactory: InkSparkle.splashFactory,

      // The prototype's app bars are the dark chrome colour, not the surface.
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.chrome,
        foregroundColor: AppColors.onChrome,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(color: AppColors.onChrome),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),

      // NOTE: cardTheme and tabBarTheme are deliberately NOT set here. Their
      // types were renamed (CardTheme -> CardThemeData, TabBarTheme ->
      // TabBarThemeData) across recent Flutter releases, so setting them ties
      // this file to one SDK version. Cards are styled by core/widgets/app_card.dart
      // instead, which is what every screen uses.

      dividerTheme: const DividerThemeData(
        color: AppColors.outline,
        thickness: AppSizes.borderWidth,
        space: AppSizes.borderWidth,
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          disabledBackgroundColor: AppColors.primaryDisabled,
          disabledForegroundColor: AppColors.onPrimaryDisabled,
          minimumSize: const Size.fromHeight(AppSizes.buttonHeight),
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSizes.radiusButton),
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          minimumSize: const Size(0, AppSizes.buttonHeight),
          textStyle: text.labelLarge,
          side: const BorderSide(
            color: AppColors.primary,
            width: AppSizes.borderWidth,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSizes.radiusButton),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          textStyle: text.labelLarge,
          minimumSize: const Size(AppSizes.minTouchTarget, AppSizes.minTouchTarget),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSizes.md,
          vertical: AppSizes.md,
        ),
        hintStyle: text.bodyLarge?.copyWith(color: AppColors.onSurfaceVariant),
        border: _fieldBorder(AppColors.outline),
        enabledBorder: _fieldBorder(AppColors.outline),
        focusedBorder: _fieldBorder(AppColors.primary, width: 2),
        errorBorder: _fieldBorder(AppColors.onDangerContainer),
        focusedErrorBorder: _fieldBorder(AppColors.onDangerContainer, width: 2),
        errorStyle: text.bodySmall?.copyWith(color: AppColors.onDangerContainer),
      ),

      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.selected)) return AppColors.primary;
          return AppColors.surface;
        }),
        checkColor: const WidgetStatePropertyAll<Color>(AppColors.onPrimary),
        side: const BorderSide(color: AppColors.outline, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        materialTapTargetSize: MaterialTapTargetSize.padded,
      ),

      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll<Color>(AppColors.surface),
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.selected)) return AppColors.primary;
          return AppColors.outline;
        }),
        trackOutlineColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      ),

      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.primary,
        linearTrackColor: AppColors.outlineSoft,
        circularTrackColor: AppColors.outlineSoft,
      ),

      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        showDragHandle: true,
        dragHandleColor: AppColors.outline,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppSizes.radiusSheet),
          ),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.chrome,
        contentTextStyle: text.bodyMedium?.copyWith(color: AppColors.onChrome),
        actionTextColor: AppColors.liveDot,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSizes.radiusButton),
        ),
      ),
    );
  }

  static OutlineInputBorder _fieldBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppSizes.radiusField),
      borderSide: BorderSide(color: color, width: width),
    );
  }
}
