import 'package:flutter/material.dart';

/// Colour tokens for Field Capture.
///
/// Every value marked MEASURED was pixel-sampled from the prototype PDF
/// mockups or read from the PDF's own vector fills. Values marked ASSUMED
/// could not be determined from a raster and are recorded in ASSUMPTIONS.md.
///
/// Screens must never hard-code a colour. If a screen needs a colour that is
/// not here, add it here first.
abstract final class AppColors {
  // ---------------------------------------------------------------------------
  // Primary — MEASURED
  // ---------------------------------------------------------------------------

  /// Buttons, links, selected chips, capture pins, active tab indicator.
  static const Color primary = Color(0xFF085B90);
  static const Color onPrimary = Color(0xFFFFFFFF);

  /// Primary at 45% — the disabled treatment on "Start Walking" / "Save capture".
  static const Color primaryDisabled = Color(0x73085B90);
  static const Color onPrimaryDisabled = Color(0xB3FFFFFF);

  // ---------------------------------------------------------------------------
  // Dark chrome — MEASURED
  // App bars, capture dock, 3D screens, dark pill toggles.
  // ---------------------------------------------------------------------------

  static const Color chrome = Color(0xFF071529);
  static const Color chromeElevated = Color(0xFF202C3E);
  static const Color onChrome = Color(0xFFFFFFFF);
  static const Color onChromeMuted = Color(0xFF777F8A);

  // ---------------------------------------------------------------------------
  // Semantic accents — MEASURED
  // ---------------------------------------------------------------------------

  /// Stop Walking, upload-queue count badge, camera-lost chip.
  static const Color recording = Color(0xFFFE5C4E);

  /// Issue pins on the plan, the Offline connectivity pill.
  static const Color warning = Color(0xFFFFA41E);

  /// End pin, "Uploaded", "Available offline", "Synced".
  static const Color success = Color(0xFF1C6F5A);

  /// The live status dot rendered on dark chrome.
  static const Color liveDot = Color(0xFF3ECF6E);

  /// The capture in progress — the trail being recorded right now, the mobile
  /// sweep progress bar and its ring. Deliberately brighter than [primary] so
  /// a live walk reads apart from walks already saved.
  static const Color captureActive = Color(0xFF289DE8);

  // ---------------------------------------------------------------------------
  // Full-screen camera chrome — MEASURED
  // The recording and mobile-capture screens drop the app chrome entirely.
  // ---------------------------------------------------------------------------

  static const Color captureBackdrop = Color(0xFF0B1420);
  static const Color capturePill = Color(0xFF101A24);
  static const Color capturePillBorder = Color(0xFF213448);

  // ---------------------------------------------------------------------------
  // Neutrals — MEASURED
  // ---------------------------------------------------------------------------

  static const Color onSurface = Color(0xFF0C1315);
  static const Color onSurfaceVariant = Color(0xFF5E5C5C);
  static const Color background = Color(0xFFFAFAFA);
  static const Color surface = Color(0xFFFFFFFF);

  /// Card borders, dividers, plan grid lines.
  static const Color outline = Color(0xFFDDE2E7);
  static const Color outlineSoft = Color(0xFFE9E9E9);

  /// Placeholder fill behind absent thumbnails.
  static const Color thumbnailPlaceholder = Color(0xFFE5E6EB);

  /// The grey ground the white plan sheet sits on in the plan view.
  static const Color planBackdrop = Color(0xFFE5E6EB);

  // ---------------------------------------------------------------------------
  // Semantic containers — MEASURED
  // Chip and badge fills. Pair each container with its `on` colour.
  // ---------------------------------------------------------------------------

  static const Color infoContainer = Color(0xFFD1EBFB);
  static const Color onInfoContainer = Color(0xFF085B90);

  static const Color dangerContainer = Color(0xFFFFF0ED);
  static const Color onDangerContainer = Color(0xFF961414);

  static const Color successContainer = Color(0xFFF0FAF7);
  static const Color onSuccessContainer = Color(0xFF1C6F5A);

  static const Color neutralContainer = Color(0xFFE9E9E9);
  static const Color onNeutralContainer = Color(0xFF5E5C5C);

  /// ASSUMED — no amber chip is drawn in the prototype, but "Medium" severity
  /// and the Offline pill need a container. Derived from [warning].
  static const Color warningContainer = Color(0xFFFDF0DA);
  static const Color onWarningContainer = Color(0xFF8A5300);

  // ---------------------------------------------------------------------------
  // Brand — MEASURED
  // ---------------------------------------------------------------------------

  /// The Asite logo mark only. Never use this as a UI colour.
  static const Color brandMark = Color(0xFFCE202A);

  // ---------------------------------------------------------------------------
  // Elevation — ASSUMED
  // The prototype is flat: cards use a 1px border, not a shadow. Only bottom
  // sheets and map pins lift off the surface.
  // ---------------------------------------------------------------------------

  static const Color shadow = Color(0x1A071529);
  static const Color scrim = Color(0x66071529);

  /// The single place the app applies opacity to a token.
  ///
  /// `withValues` is the wide-gamut API introduced in Flutter 3.27. If this
  /// project is ever pinned to an older SDK, change this one line to
  /// `color.withOpacity(opacity)` and nothing else needs touching.
  static Color alpha(Color color, double opacity) =>
      color.withValues(alpha: opacity);
}
