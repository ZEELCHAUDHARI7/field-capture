import 'package:flutter/widgets.dart';

import '../api/models/capture_bundle.dart';
import '../api/models/stitch_result.dart';
import '../api/sphere_capture_view.dart';
import 'capture_hud.dart';
import 'capture_warnings.dart';

/// The screen after a capture (Phase 09 §3.3): what was shot, how complete it
/// is, what is wrong with it in plain language, and the two things to do next.
///
/// The warnings are the point. A capture that fell short has to say so in words
/// that tell the user whether to re-shoot — "3 photos were too blurry to use",
/// not "stitching may be imperfect". See [CaptureWarnings].
class SphereReviewScreen extends StatefulWidget {
  /// Creates the review screen for [bundle].
  const SphereReviewScreen({
    required this.bundle,
    required this.onSave,
    super.key,
    this.report,
    this.previewBuilder,
    this.onRetake,
    this.onDiscard,
    this.saveLabel = 'Save',
  });

  /// The capture being reviewed.
  final CaptureBundle bundle;

  /// The stitch report, when a preview stitch has already run. `null` before
  /// one has.
  final StitchReport? report;

  /// Builds the equirect preview — the fast 2048 preview from Phase 04 §7 in
  /// the viewer. Left to the caller because the review screen must render on a
  /// device that has not stitched anything yet.
  final WidgetBuilder? previewBuilder;

  /// Called with a target index the user wants to shoot again.
  final void Function(int targetIndex)? onRetake;

  /// Called when the user commits: runs the stitch.
  final VoidCallback onSave;

  /// Called when the user throws the capture away.
  final VoidCallback? onDiscard;

  /// Label for the commit button.
  final String saveLabel;

  @override
  State<SphereReviewScreen> createState() => _SphereReviewScreenState();
}

class _SphereReviewScreenState extends State<SphereReviewScreen> {
  bool _showingPositions = false;

  @override
  Widget build(BuildContext context) {
    final bundle = widget.bundle;
    final report = widget.report;
    final warnings = [
      ...CaptureWarnings.sentencesForBundle(bundle),
      if (report != null) ...CaptureWarnings.sentencesForReport(report),
    ];
    final coverage = report?.coverageFraction ?? bundle.completionFraction;

    return DefaultTextStyle(
      style: const TextStyle(
        color: CaptureHudColors.foreground,
        fontSize: 16,
        fontWeight: FontWeight.w400,
        decoration: TextDecoration.none,
      ),
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView(
                    children: [
                      AspectRatio(
                        aspectRatio: 2,
                        child: widget.previewBuilder?.call(context) ??
                            const _PreviewPlaceholder(),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${bundle.positions.length} of ${bundle.plan.length} '
                        'photos · ${(coverage * 100).toStringAsFixed(0)}% of '
                        'the sphere',
                        style: const TextStyle(
                          color: CaptureHudColors.foreground,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      if (warnings.isEmpty) ...[
                        const SizedBox(height: 8),
                        const Text('Nothing was compromised in this capture.'),
                      ],
                      for (final warning in warnings) ...[
                        const SizedBox(height: 12),
                        _Warning(warning),
                      ],
                      if (_showingPositions) ...[
                        const SizedBox(height: 20),
                        for (final target in bundle.plan.targets)
                          _PositionRow(
                            label:
                                '${target.ringLabel} · position '
                                '${target.index + 1}',
                            captured: bundle.positions.any(
                              (p) => p.targetIndex == target.index,
                            ),
                            onRetake: widget.onRetake == null
                                ? null
                                : () => widget.onRetake!(target.index),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (widget.onRetake != null)
                  Center(
                    child: CaptureTextButton(
                      label: _showingPositions
                          ? 'Hide positions'
                          : 'Retake position…',
                      onPressed: () => setState(
                        () => _showingPositions = !_showingPositions,
                      ),
                      filled: false,
                    ),
                  ),
                const SizedBox(height: 12),
                Center(
                  child: CaptureTextButton(
                    label: widget.saveLabel,
                    onPressed: widget.onSave,
                  ),
                ),
                if (widget.onDiscard != null) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: CaptureTextButton(
                      label: 'Discard',
                      onPressed: widget.onDiscard,
                      filled: false,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      border: Border.all(color: CaptureHudColors.foreground, width: 2),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: const TextStyle(height: 1.35)),
  );
}

class _PositionRow extends StatelessWidget {
  const _PositionRow({
    required this.label,
    required this.captured,
    required this.onRetake,
  });

  final String label;
  final bool captured;
  final VoidCallback? onRetake;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(captured ? label : '$label — not taken'),
        ),
        if (onRetake != null)
          Semantics(
            button: true,
            label: 'Retake $label',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onRetake,
              // 56 dp square even though the label is short: §4's floor applies
              // to every target on every screen, not only to the two on the
              // capture screen.
              child: const SizedBox(
                width: 96,
                height: 56,
                child: Center(child: Text('Retake')),
              ),
            ),
          ),
      ],
    ),
  );
}

class _PreviewPlaceholder extends StatelessWidget {
  const _PreviewPlaceholder();

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border.all(color: CaptureHudColors.pending, width: 2),
      borderRadius: BorderRadius.circular(6),
    ),
    alignment: Alignment.center,
    child: const Text('Preview appears once the panorama is stitched.'),
  );
}
