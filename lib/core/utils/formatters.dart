/// Display formatters.
///
/// Hand-written rather than pulling in `intl`, because Phase 1 needs exactly
/// three formats and the prototype shows all of them literally:
///   "24 MB"  ·  "updated 28 Jun"  ·  "Yesterday 14:12"
///
/// When localisation lands (see ASSUMPTIONS.md), replace the bodies here and
/// nothing else in the app changes.
abstract final class Formatters {
  static const List<String> _months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// "24 MB", "1.2 GB", "980 kB". Uses MB/GB as the prototype does.
  static String bytes(int value) {
    const int kb = 1000;
    const int mb = kb * 1000;
    const int gb = mb * 1000;

    if (value >= gb) {
      final double n = value / gb;
      return '${_trim(n)} GB';
    }
    if (value >= mb) {
      return '${(value / mb).round()} MB';
    }
    if (value >= kb) {
      return '${(value / kb).round()} kB';
    }
    return '$value B';
  }

  /// "28 Jun" — the prototype's calibration date format.
  static String dayMonth(DateTime date) {
    return '${date.day} ${_months[date.month - 1]}';
  }

  /// "14:12" — 24-hour, matching the prototype.
  static String time(DateTime date) {
    return '${_pad(date.hour)}:${_pad(date.minute)}';
  }

  /// "Just now", "12 min ago", "Yesterday 14:12", "28 Jun 14:12".
  static String relative(DateTime date, {DateTime? now}) {
    final DateTime reference = now ?? DateTime.now();
    final Duration delta = reference.difference(date);

    if (delta.inMinutes < 1) return 'Just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (_isSameDay(date, reference)) return 'Today ${time(date)}';

    final DateTime yesterday = reference.subtract(const Duration(days: 1));
    if (_isSameDay(date, yesterday)) return 'Yesterday ${time(date)}';

    return '${dayMonth(date)} ${time(date)}';
  }

  /// "02:12" — elapsed recording time. Rolls over to "1:02:12" past an hour.
  static String elapsed(Duration duration) {
    final int hours = duration.inHours;
    final int minutes = duration.inMinutes.remainder(60);
    final int seconds = duration.inSeconds.remainder(60);
    if (hours > 0) return '$hours:${_pad(minutes)}:${_pad(seconds)}';
    return '${_pad(minutes)}:${_pad(seconds)}';
  }

  /// "46%" from a 0.0–1.0 progress value.
  static String percent(double progress) {
    return '${(progress.clamp(0.0, 1.0) * 100).round()}%';
  }

  /// "3 calibrations offline", "1 calibration offline", "Nothing downloaded yet".
  static String offlineCount(int count) {
    if (count == 0) return 'Nothing downloaded yet';
    if (count == 1) return '1 calibration offline';
    return '$count calibrations offline';
  }

  static String _pad(int value) => value.toString().padLeft(2, '0');

  static String _trim(double value) {
    final String fixed = value.toStringAsFixed(1);
    return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
  }

  static bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}
