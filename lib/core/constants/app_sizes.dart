/// Spacing, radius and sizing tokens.
///
/// The 48px minimum touch target is STATED in the prototype documentation
/// ("touch targets never below 48px") and is therefore a hard rule, not an
/// assumption. Everything else on this page is ASSUMED — the mockups are
/// rasters, so exact values could not be measured. See ASSUMPTIONS.md.
abstract final class AppSizes {
  // Spacing scale — 4pt base.
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;

  /// Horizontal padding on every scrollable screen body.
  static const double screenPadding = lg;

  /// Inner padding of a list card.
  static const double cardPadding = lg;

  /// Vertical gap between sibling cards in a list.
  static const double cardGap = md;

  // Radii.
  static const double radiusCard = 12;
  static const double radiusButton = 8;
  static const double radiusField = 8;
  static const double radiusSheet = 20;
  static const double radiusThumbnail = 8;

  /// Chips and status pills are fully rounded.
  static const double radiusPill = 999;

  // Sizing.

  /// Hard floor for any interactive element. STATED in the prototype.
  static const double minTouchTarget = 48;

  static const double buttonHeight = 48;
  static const double chipHeight = 40;
  static const double fieldHeight = 48;

  /// Square plan thumbnail on calibration and trajectory rows.
  static const double thumbnail = 48;

  /// Border width used everywhere the prototype draws a hairline.
  static const double borderWidth = 1;

  /// Height of the dark app bar content, excluding the system status bar.
  static const double appBarHeight = 60;

  /// Height of the status strip (camera chip + connectivity pill) that sits
  /// under the app bar on capture screens.
  ///
  /// Pinned to [minTouchTarget]: the strip hosts the connectivity pill, which
  /// is tappable, and a strip shorter than the floor caps the pill's hit area
  /// no matter what the pill itself asks for.
  static const double statusStripHeight = minTouchTarget;
}
