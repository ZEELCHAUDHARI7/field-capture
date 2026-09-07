import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Type tokens.
///
/// The prototype is set in Inter, with a monospace face (Consolas in the PDF)
/// for identifiers: capture names, project codes, firmware versions and grid
/// references.
///
/// [sansFamily] is null today, so Flutter falls back to Roboto. Bundle the
/// Inter TTFs (see the commented fonts block in pubspec.yaml) and set
/// [sansFamily] to 'Inter' to match the prototype exactly. That one change
/// propagates through the whole app — no screen references a font directly.
abstract final class AppTypography {
  /// Set to 'Inter' once assets/fonts/Inter-*.ttf are bundled.
  static const String? sansFamily = null;

  /// Android resolves the generic 'monospace' family without bundling.
  static const String monoFamily = 'monospace';

  /// Identifiers: L03_Img_2026-07-03_13, PRJ-4821, R0110482, v2.30.1.
  static const TextStyle mono = TextStyle(
    fontFamily: monoFamily,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
    height: 1.35,
  );

  /// Small uppercase section label — "SYNC STATUS — READ-ONLY", "CAMERA".
  static const TextStyle sectionLabel = TextStyle(
    fontFamily: monoFamily,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.4,
    height: 1.4,
  );

  static TextTheme get textTheme => const TextTheme(
        // Sign-in hero.
        displaySmall: TextStyle(
          fontFamily: sansFamily,
          fontSize: 30,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
          height: 1.15,
        ),
        // App bar title, sheet title.
        titleLarge: TextStyle(
          fontFamily: sansFamily,
          fontSize: 19,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          height: 1.25,
        ),
        // Card title — project name, calibration name, issue title.
        titleMedium: TextStyle(
          fontFamily: sansFamily,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
          height: 1.3,
        ),
        // Field label, switch-tile title.
        titleSmall: TextStyle(
          fontFamily: sansFamily,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
        // Default body.
        bodyLarge: TextStyle(
          fontFamily: sansFamily,
          fontSize: 15,
          fontWeight: FontWeight.w400,
          height: 1.45,
        ),
        // Card metadata — "24 MB · updated 28 Jun".
        bodyMedium: TextStyle(
          fontFamily: sansFamily,
          fontSize: 13,
          fontWeight: FontWeight.w400,
          height: 1.4,
        ),
        // Helper text under a form.
        bodySmall: TextStyle(
          fontFamily: sansFamily,
          fontSize: 12,
          fontWeight: FontWeight.w400,
          height: 1.4,
        ),
        // Button label.
        labelLarge: TextStyle(
          fontFamily: sansFamily,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
          height: 1.2,
        ),
        // Chip and badge label.
        labelMedium: TextStyle(
          fontFamily: sansFamily,
          fontSize: 13,
          fontWeight: FontWeight.w500,
          height: 1.2,
        ),
        // Dense badge label.
        labelSmall: TextStyle(
          fontFamily: sansFamily,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          height: 1.2,
        ),
      );

  /// Text styles for content sitting on dark chrome.
  static TextStyle onChrome(TextStyle base) =>
      base.copyWith(color: AppColors.onChrome);

  static TextStyle onChromeMuted(TextStyle base) =>
      base.copyWith(color: AppColors.onChromeMuted);
}
