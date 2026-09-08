import 'package:flutter/material.dart';
import 'package:sphere_view/sphere_view.dart';

/// Flow 4: the whole `StitchReport`, with every number said twice — once as the
/// figure, once as what it means.
///
/// This is the demo's most useful screen for anyone evaluating whether the
/// package is good enough for their site, so it deliberately does not
/// summarise. Architecture §8's rule is that no compromise is silent; a screen
/// that showed a green tick and hid the six warnings behind it would be the
/// most efficient possible way to break that rule.
class ReportPage extends StatelessWidget {
  /// Shows [result], and names it [title].
  const ReportPage({
    super.key,
    required this.title,
    required this.result,
    this.elapsedNote,
  });

  /// The station's name.
  final String title;

  /// The panorama and its measured quality.
  final StitchResult result;

  /// Anything the demo knows about the run that the report does not — how long
  /// the bundle sat in the queue, typically.
  final String? elapsedNote;

  @override
  Widget build(BuildContext context) {
    final report = result.report;
    final warnings = CaptureWarnings.forReport(report);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text('$title — report')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Verdict(report: report),
          const SizedBox(height: 16),

          _CriterionTile(
            id: 'S1',
            name: 'Registration accuracy',
            value: '${report.rmsReprojectionErrorPx.toStringAsFixed(2)} px',
            target: 'under ${StitchReport.maxRmsReprojectionErrorPx} px',
            passed: report.rmsReprojectionErrorPx <
                StitchReport.maxRmsReprojectionErrorPx,
            explanation:
                'How far a point seen in two photos lands from itself once '
                'both have been positioned. Under a pixel and no join is '
                'visible; a few pixels and straight lines break across a seam.',
          ),
          _CriterionTile(
            id: 'S2',
            name: 'Loop closure',
            value: '${report.loopClosureErrorDegrees.toStringAsFixed(3)}°',
            target: 'under ${StitchReport.maxLoopClosureErrorDegrees}°',
            // A negative value is the "no equatorial ring" sentinel, not a
            // measurement: fewer than three frames around the horizon could be
            // matched, so there was no loop to close.
            unavailableReason: report.loopClosureErrorDegrees < 0
                ? 'Fewer than three photos around the horizon could be matched '
                      'to each other, so there was no complete turn to check.'
                : null,
            passed: report.loopClosureErrorDegrees <
                StitchReport.maxLoopClosureErrorDegrees,
            explanation:
                'Turn all the way round and you should arrive back where you '
                'started. Whatever is left over is the honest test of whether '
                "the lens's field of view was measured correctly.",
          ),
          _CriterionTile(
            id: 'S4',
            name: 'Brightness match',
            value: report.maxGainRatio.toStringAsFixed(3),
            target: 'under ${StitchReport.maxAcceptableGainRatio}',
            passed:
                report.maxGainRatio < StitchReport.maxAcceptableGainRatio,
            explanation:
                'The biggest brightness step left between two neighbouring '
                'photos after they were evened out. Above about 1.03 you can '
                'see the banding on a plain wall.',
          ),
          _CriterionTile(
            id: 'S5',
            name: 'Coverage',
            value: '${(report.coverageFraction * 100).toStringAsFixed(1)}%',
            target: '100%',
            passed: report.coverageFraction >= 1.0 - 1e-9,
            explanation:
                'How much of the sphere has real imagery behind it. Below '
                '100% the panorama was emitted deliberately incomplete rather '
                'than faked — the missing directions are filled, not '
                'photographed.',
          ),
          _CriterionTile(
            id: '—',
            name: 'Levelling drift',
            value: '${report.residualTiltDegrees.toStringAsFixed(3)}°',
            target: 'under ${StitchReport.maxResidualTiltDegrees}°',
            passed: report.residualTiltDegrees <
                StitchReport.maxResidualTiltDegrees,
            explanation:
                'How far the alignment had drifted from gravity before the '
                'sphere was levelled against it. Small means the photos and the '
                'tablet agreed about which way is up. This used to be measured '
                'after levelling, where it was always exactly zero — levelling '
                'is defined as the correction that makes it zero.',
          ),

          const Divider(height: 32),
          _Facts('The panorama', {
            'Size': '${result.width}×${result.height}',
            'File': result.equirectPath,
            'Quality tier used': report.tierUsed.name,
            'Stitch time': _seconds(report.elapsedMs),
            'In the demo': ?elapsedNote,
          }),

          const Divider(height: 32),
          _Facts('What the lens turned out to be', {
            // R2's gradient, made visible: which rung the device reached is the
            // single best predictor of how S1 and S3 come out, and the refined
            // focal against the input focal is how a weak rung gets caught.
            'Intrinsics source': report.refinedIntrinsics.source.name,
            // Seed beside refined, because either alone is unfalsifiable. A
            // capture once reported a 23.5° field of view — telephoto, from a
            // camera with about 67 — and every downstream number was built on
            // it, with nothing in the report to compare against.
            'Focal the device reported': ?switch (report.capturedIntrinsics) {
              final CameraIntrinsics i => '${i.fx.toStringAsFixed(1)} px '
                  '(${i.hfovDegrees.toStringAsFixed(1)}° wide)',
              null => null,
            },
            'Focal after refinement':
                '${report.refinedFocalPx.toStringAsFixed(1)} px',
            'Refinement': ?switch (report.capturedIntrinsics) {
              final CameraIntrinsics i when i.fx > 0 =>
                '${((report.refinedFocalPx / i.fx - 1) * 100).toStringAsFixed(1)}% '
                    'from what the device claimed',
              _ => null,
            },
            'Horizontal field of view':
                '${report.refinedIntrinsics.hfovDegrees.toStringAsFixed(2)}°',
            'Vertical field of view':
                '${report.refinedIntrinsics.vfovDegrees.toStringAsFixed(2)}°',
            'Distortion model':
                report.refinedIntrinsics.distortion?.toString() ?? 'none',
          }),

          if (report.droppedPositionIndices.isNotEmpty) ...[
            const Divider(height: 32),
            _Facts('Positions the pipeline could not use', {
              'Count': '${report.droppedPositionIndices.length}',
              'Which': report.droppedPositionIndices.join(', '),
            }),
          ],

          const Divider(height: 32),
          Text('Warnings', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (warnings.isEmpty)
            const Text(
              'None. Every compromise this pipeline can make would appear '
              'here, so an empty list is a statement rather than an absence.',
            )
          else
            for (final warning in warnings) _WarningTile(warning: warning),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  static String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)} s';
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.report});

  final StitchReport report;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final passed = report.meetsQualityTargets;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: passed ? scheme.primaryContainer : scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            passed ? Icons.check_circle_outline : Icons.warning_amber_outlined,
            color: passed
                ? scheme.onPrimaryContainer
                : scheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              passed
                  ? 'Meets every quality target this device can check.'
                  : 'Below target on at least one criterion. The panorama is '
                        'still here — nothing is withheld — but the numbers '
                        'below say where it is weak.',
              style: TextStyle(
                color: passed
                    ? scheme.onPrimaryContainer
                    : scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CriterionTile extends StatelessWidget {
  const _CriterionTile({
    required this.id,
    required this.name,
    required this.value,
    required this.target,
    required this.passed,
    required this.explanation,
    this.unavailableReason,
  });

  final String id;
  final String name;
  final String value;
  final String target;
  final bool passed;
  final String explanation;

  /// Set when the criterion could not be measured at all, in which case it
  /// replaces both the value and the pass/fail colour.
  ///
  /// Some of these numbers carry a sentinel for "no measurement" — S2 reports
  /// −1° when fewer than three frames formed an equatorial ring — and rendering
  /// that verbatim produced a report claiming a loop closure of −1.000° against
  /// a target of 0.25°, which then *passed*, because −1 is less than 0.25. A
  /// sentinel shown as a measurement is worse than no row at all: it reads as
  /// evidence.
  final String? unavailableReason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text(id, style: theme.textTheme.labelLarge),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(name, style: theme.textTheme.titleSmall),
                    ),
                    Text(
                      unavailableReason == null ? value : 'not measured',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: unavailableReason != null
                            ? theme.colorScheme.onSurfaceVariant
                            : passed
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                    ),
                  ],
                ),
                Text('Target: $target', style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                if (unavailableReason != null)
                  Text(
                    unavailableReason!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (unavailableReason != null) const SizedBox(height: 4),
                Text(explanation, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WarningTile extends StatelessWidget {
  const _WarningTile({required this.warning});

  final StitchWarning warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The sentence first, the code second. The code is what a bug report
          // should quote and what `docs/TROUBLESHOOTING.md` is indexed by; the
          // sentence is what the person holding the tablet can act on.
          Text(warning.message),
          Text(
            '${warning.code.wireName} · ${warning.detail}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts(this.title, this.rows);

  final String title;
  final Map<String, String> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final entry in rows.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 160,
                  child: Text(entry.key, style: theme.textTheme.bodySmall),
                ),
                Expanded(child: SelectableText(entry.value)),
              ],
            ),
          ),
      ],
    );
  }
}
