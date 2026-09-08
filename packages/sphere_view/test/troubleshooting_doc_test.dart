import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

/// Phase 12 §6 — `docs/TROUBLESHOOTING.md` is keyed to the warning codes, and
/// stays keyed to them.
///
/// The doc is the thing a site lead reads at 7 a.m. with a bad panorama on the
/// screen, so a code missing from it is a user with a message they cannot look
/// up. Documentation drift is the normal state of affairs and nothing but a test
/// prevents it: the message table itself is protected by an exhaustive `switch`,
/// but prose has no compiler.
void main() {
  final doc = File('docs/TROUBLESHOOTING.md');
  final technique = File('docs/CAPTURE_TECHNIQUE.md');
  final metrics = File('docs/METRICS.md');

  test('the four docs Phase 12 §6 asks for exist', () {
    for (final file in [doc, technique, metrics, File('README.md')]) {
      expect(
        file.existsSync(),
        isTrue,
        reason: '${file.path} is one of the §6 deliverables',
      );
    }
  });

  test('every warning code has a row in the troubleshooting table', () {
    final text = doc.readAsStringSync();
    final missing = <String>[];
    for (final code in StitchWarningCode.values) {
      // Backticked, so a code name that happens to be a common English phrase
      // cannot pass by appearing in a sentence.
      if (!text.contains('`${code.wireName}`')) missing.add(code.wireName);
    }
    expect(
      missing,
      isEmpty,
      reason:
          'docs/TROUBLESHOOTING.md has no row for: ${missing.join(', ')}. A code '
          'with no row is a message a site lead cannot look up.',
    );
  });

  test('the table names no code that does not exist', () {
    // The other direction, and it matters as much: a row for a code that was
    // renamed or removed sends the reader looking for a warning they will never
    // see, which is how a doc stops being trusted.
    final text = doc.readAsStringSync();
    final known = {for (final code in StitchWarningCode.values) code.wireName};
    // Only the rows of the code table, which are the lines starting with a
    // backticked snake_case token.
    final rows = RegExp(r'^\| `([a-z0-9_]+)` \|', multiLine: true)
        .allMatches(text)
        .map((m) => m.group(1)!)
        .toList();
    expect(
      rows,
      isNotEmpty,
      reason: 'the code table was not found; has its format changed?',
    );
    for (final row in rows) {
      expect(
        known,
        contains(row),
        reason:
            '`$row` has a troubleshooting row but is not a warning code any '
            'more',
      );
    }
    // And the table is the *whole* set rather than a popular subset.
    expect(rows.toSet().length, StitchWarningCode.values.length);
  });

  test('the capture-technique page stays one page, and keeps the pivot rule', () {
    final text = technique.readAsStringSync();
    // The claim in the phase doc is that this page "has more effect on output
    // quality than most of the algorithm work" — which is only true if it is
    // short enough to be read on site. Two thousand words is not one page.
    final words = text.split(RegExp(r'\s+')).length;
    expect(
      words,
      lessThan(1400),
      reason:
          'CAPTURE_TECHNIQUE.md is $words words; a page a site team actually '
          'reads is shorter than that',
    );
    // The one rule that cannot be dropped in a tidy-up. Architecture §3: the
    // lens offset is the only lever on the parallax floor, and capture technique
    // is the only lever on the lens offset.
    expect(text.toLowerCase(), contains('pivot'));
    expect(text, contains('1.5 m'));
    // And the diagram §6 asks for by name.
    expect(
      text,
      contains('lens stays here'),
      reason: 'the pivot diagram is named as a deliverable in Phase 12 §6',
    );
  });

  test('METRICS.md documents all ten criteria and the parallax floor', () {
    final text = metrics.readAsStringSync();
    for (var criterion = 1; criterion <= 10; criterion++) {
      expect(
        text,
        contains('S$criterion'),
        reason: 'S$criterion is undocumented',
      );
    }
    // The exit criterion is that the floor is measured and documented **rather
    // than hidden**, so this checks for the measurement rather than for a
    // paragraph about parallax being hard.
    expect(text, contains('parallax floor'));
    expect(
      text,
      contains('0.68'),
      reason:
          'the measured-to-predicted ratio is the result; a page that describes '
          'the sweep without quoting it has hidden the floor again',
    );
  });
}
