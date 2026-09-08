import 'dart:convert';

import 'metrics.dart';

/// Formats a [MetricsResult] three ways: for a terminal, for a markdown table,
/// and for the JSON the quality gate diffs against a baseline.
class ReportFormatter {
  const ReportFormatter._();

  /// The console table from §2 of the phase doc.
  static String text(
    MetricsResult result, {
    required String profile,
    required String backend,
    required String focal,
    required int totalMilliseconds,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('profile $profile   backend $backend');

    final stages = result.stageMilliseconds.entries
        .map((e) => '${e.key} ${(e.value / 1000).toStringAsFixed(1)}s')
        .join('  ');
    buffer.writeln(
      'stage timings          ${stages.isEmpty ? '(none reported)' : stages}',
    );
    buffer.writeln(
      'total                  ${(totalMilliseconds / 1000).toStringAsFixed(1)}s',
    );
    buffer.writeln('focal used             $focal');

    for (final metric in result.metrics) {
      final verdict = switch (metric.pass) {
        true => 'PASS',
        false => 'FAIL',
        null => 'n/a ',
      };
      buffer.writeln(
        '${metric.id.padRight(8)}${metric.label.padRight(15)}'
        '${metric.formatted.padRight(17)}'
        '${metric.target.isEmpty ? '' : 'target ${metric.target.padRight(12)}'}'
        '$verdict',
      );
    }

    buffer.writeln(
      'excluded from s6       '
      '${(result.excludedFraction * 100).toStringAsFixed(1)}% of the sphere '
      '(uncovered or pole-filled)',
    );

    // The stitcher's own account of how it got here. Printed as one line
    // because it is a diagnosis aid, not a verdict: none of these numbers passes
    // or fails, and reading them only matters once a metric above has.
    if (result.diagnostics.isNotEmpty) {
      final keys = result.diagnostics.keys.toList()..sort();
      final described = keys
          .where((k) => result.diagnostics[k] != null)
          .map((k) => '$k ${_shortly(result.diagnostics[k])}')
          .join('  ');
      if (described.isNotEmpty) {
        buffer.writeln('compositing            $described');
      }
    }

    if (result.worstSeams.isNotEmpty) {
      final worst = result.worstSeams
          .take(10)
          .map((s) => '(${s.x},${s.y}) ${s.ratio.toStringAsFixed(1)}x')
          .join('  ');
      buffer.writeln('worst seams            $worst');
    }
    for (final warning in result.warnings) {
      buffer.writeln('warning                $warning');
    }
    buffer.writeln(
      result.allPass
          ? 'RESULT                 PASS'
          : 'RESULT                 FAIL',
    );
    return buffer.toString();
  }

  /// A diagnostic value, short enough to sit on a shared line. Paths keep only
  /// their file name, which is all that distinguishes them from each other.
  static String _shortly(Object? value) => switch (value) {
    final double d => d.abs() < 100 ? d.toStringAsFixed(3) : d.round().toString(),
    final String s when s.contains('/') => s.split('/').last,
    _ => '$value',
  };

  /// One markdown table row per profile, for `quality_gate.sh`.
  static String markdownHeader(List<Metric> metrics) {
    final names = metrics.map((m) => m.label).join(' | ');
    final rule = metrics.map((_) => '---').join(' | ');
    return '| profile | $names | result |\n| --- | $rule | --- |';
  }

  /// The row for one profile.
  static String markdownRow(String profile, MetricsResult result) {
    final cells = result.metrics
        .map((m) {
          final mark = switch (m.pass) {
            true => '',
            false => ' **FAIL**',
            null => '',
          };
          return '${m.formatted}$mark';
        })
        .join(' | ');
    return '| `$profile` | $cells | ${result.allPass ? 'PASS' : '**FAIL**'} |';
  }

  /// The full JSON report, including the baseline-comparable raw values.
  static String json(
    MetricsResult result, {
    required String profile,
    required String backend,
  }) => const JsonEncoder.withIndent('  ').convert({
    'profile': profile,
    'backend': backend,
    'pass': result.allPass,
    'excluded_fraction': result.excludedFraction,
    'stage_milliseconds': result.stageMilliseconds,
    'metrics': [
      for (final m in result.metrics)
        {
          'id': m.id,
          'label': m.label,
          'value': m.value.isNaN ? null : m.value,
          'formatted': m.formatted,
          'target': m.target,
          'pass': m.pass,
          'lower_is_better': m.lowerIsBetter,
        },
    ],
    'worst_seams': [
      for (final s in result.worstSeams)
        {'x': s.x, 'y': s.y, 'ratio': s.ratio},
    ],
    'compositing': result.diagnostics,
    'warnings': result.warnings,
  });

  /// The baseline file `quality_gate.sh` compares against.
  ///
  /// Deliberately more than the numbers: a baseline that records a `FAIL` and
  /// does not say *why it is allowed to* is a baseline someone will "fix" by
  /// deleting. The exit criteria for this phase call for exactly that state —
  /// baselines recorded as FAIL against a stitcher known to be bad — so the
  /// file has to carry its own explanation.
  static String baselineJson(
    MetricsResult result, {
    required String profile,
    required String backend,
    required String note,
  }) => const JsonEncoder.withIndent('  ').convert({
    'profile': profile,
    'backend': backend,
    'note': note,
    'pass': result.allPass,
    'metrics': {
      for (final m in result.metrics)
        if (!m.value.isNaN)
          m.id: {
            'value': m.value,
            'pass': m.pass,
            'lower_is_better': m.lowerIsBetter,
          },
    },
  });
}
