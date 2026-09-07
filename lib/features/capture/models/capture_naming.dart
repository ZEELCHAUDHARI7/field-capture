import '../../plan/models/plan_marker.dart';

/// Builds the pre-filled capture name.
///
/// The prototype says the name is "pre-filled from level, mode, date and
/// sequence so the default is already correct and the crew can just confirm",
/// and shows five examples:
///
///   L03_Img_2026-07-03_13     L03_Walk_2026-07-03_09
///   L03_Walk_2026-06-28_04    B1_Walk_2026-07-01_02
///   L03_Mobile_2026-07-01_05
///
/// The trailing pair is read as the **hour of capture**, not a running counter:
/// the walk recorded "today" is `_09` and the phone's status bar in every
/// mockup reads 9:41. Every other example (02, 04, 05, 11, 13) is a plausible
/// hour on a working day. Recorded as an inference in ASSUMPTIONS.md §G1.
///
/// Two captures of the same mode in the same hour would collide, which the
/// prototype does not address, so a `_2`, `_3`… suffix is appended.
abstract final class CaptureNaming {
  static String build({
    required String levelCode,
    required CaptureMode mode,
    required DateTime now,
    Iterable<String> existingNames = const <String>[],
  }) {
    final String base = '${levelCode}_${mode.nameToken}_'
        '${now.year}-${_pad(now.month)}-${_pad(now.day)}_${_pad(now.hour)}';

    final Set<String> taken = existingNames.toSet();
    if (!taken.contains(base)) return base;

    int suffix = 2;
    while (taken.contains('${base}_$suffix')) {
      suffix++;
    }
    return '${base}_$suffix';
  }

  /// What the naming sheet says under its title.
  ///
  /// Only the Image line is drawn in the prototype; the other two follow its
  /// shape. See ASSUMPTIONS.md §G2.
  static String hintFor(CaptureMode mode) => switch (mode) {
        CaptureMode.image => '360° image — you will set one capture point',
        CaptureMode.video =>
          '360° video — you will set a start pin, then walk the level',
        CaptureMode.mobile =>
          'Mobile 360° — you will set one capture point, then sweep',
      };

  /// The prototype's own validation rules are unstated. These are the minimum
  /// that keep the upload queue readable, which is the stated reason for
  /// naming up front. ASSUMPTIONS.md §G3.
  static const int maxLength = 64;

  static String? validate(String value) {
    final String name = value.trim();
    if (name.isEmpty) return 'A capture needs a name.';
    if (name.length > maxLength) {
      return 'Keep the name under $maxLength characters.';
    }
    if (!RegExp(r'^[A-Za-z0-9_\-.]+$').hasMatch(name)) {
      return 'Use letters, numbers, dashes and underscores only.';
    }
    return null;
  }

  static String _pad(int value) => value.toString().padLeft(2, '0');
}
