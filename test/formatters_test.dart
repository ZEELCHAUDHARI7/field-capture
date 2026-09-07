import 'package:field_capture/core/utils/formatters.dart';
import 'package:flutter_test/flutter_test.dart';

/// Formatters are the one piece of Phase 1 that can be verified without a
/// device, and every string they produce appears literally in the prototype —
/// so these tests are a direct check against the source of truth.
void main() {
  group('Formatters.bytes', () {
    test('renders the prototype\'s calibration sizes', () {
      expect(Formatters.bytes(24 * 1000 * 1000), '24 MB');
      expect(Formatters.bytes(18 * 1000 * 1000), '18 MB');
      expect(Formatters.bytes(31 * 1000 * 1000), '31 MB');
      expect(Formatters.bytes(412 * 1000 * 1000), '412 MB');
    });

    test('steps up to GB and trims a trailing zero', () {
      expect(Formatters.bytes(46 * 1000 * 1000 * 1000), '46 GB');
      expect(Formatters.bytes(1500 * 1000 * 1000), '1.5 GB');
    });

    test('handles small values', () {
      expect(Formatters.bytes(0), '0 B');
      expect(Formatters.bytes(999), '999 B');
      expect(Formatters.bytes(2500), '3 kB');
    });
  });

  group('Formatters.dayMonth', () {
    test("matches the prototype's 'updated 28 Jun'", () {
      expect(Formatters.dayMonth(DateTime(2026, 6, 28)), '28 Jun');
      expect(Formatters.dayMonth(DateTime(2026, 6, 30)), '30 Jun');
      expect(Formatters.dayMonth(DateTime(2026, 1, 1)), '1 Jan');
      expect(Formatters.dayMonth(DateTime(2026, 12, 31)), '31 Dec');
    });
  });

  group('Formatters.relative', () {
    final DateTime now = DateTime(2026, 7, 3, 15, 30);

    test('collapses the last minute', () {
      expect(
        Formatters.relative(now.subtract(const Duration(seconds: 20)), now: now),
        'Just now',
      );
    });

    test('counts minutes within the hour', () {
      expect(
        Formatters.relative(now.subtract(const Duration(minutes: 12)), now: now),
        '12 min ago',
      );
    });

    test("names today and yesterday, matching 'Yesterday 14:12'", () {
      expect(Formatters.relative(DateTime(2026, 7, 3, 9, 5), now: now),
          'Today 09:05');
      expect(Formatters.relative(DateTime(2026, 7, 2, 14, 12), now: now),
          'Yesterday 14:12');
    });

    test('falls back to a date beyond yesterday', () {
      expect(Formatters.relative(DateTime(2026, 6, 28, 8, 0), now: now),
          '28 Jun 08:00');
    });
  });

  group('Formatters.elapsed', () {
    test("matches the recording timer's '02:12'", () {
      expect(Formatters.elapsed(const Duration(minutes: 2, seconds: 12)),
          '02:12');
      expect(Formatters.elapsed(const Duration(minutes: 11, seconds: 24)),
          '11:24');
      expect(Formatters.elapsed(Duration.zero), '00:00');
    });

    test('rolls over past an hour', () {
      expect(
        Formatters.elapsed(const Duration(hours: 1, minutes: 2, seconds: 12)),
        '1:02:12',
      );
    });
  });

  group('Formatters.percent', () {
    test('rounds and clamps', () {
      expect(Formatters.percent(0.46), '46%');
      expect(Formatters.percent(0.38), '38%');
      expect(Formatters.percent(1.4), '100%');
      expect(Formatters.percent(-0.2), '0%');
    });
  });

  group('Formatters.offlineCount', () {
    test('matches every string on the project list', () {
      expect(Formatters.offlineCount(3), '3 calibrations offline');
      expect(Formatters.offlineCount(1), '1 calibration offline');
      expect(Formatters.offlineCount(0), 'Nothing downloaded yet');
    });
  });
}
