import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../api/sphere_capture_view.dart';
import '../api/sphere_capability.dart';
import '../plan/capture_plan.dart';
import 'capture_hud.dart';

/// The screen shown before the camera opens (Phase 09 §3.1).
///
/// It exists so the capture screen can stay minimal — three sentences here buy
/// the silence there. And one of those sentences is the most valuable in the
/// whole feature.
///
/// **"Pivot, don't walk"** is the parallax mitigation from architecture §3, and
/// parallax is the one limit in this project that no amount of code removes. A
/// panorama is only geometrically consistent if every frame is taken from the
/// same optical centre; handheld, the lens traces a circle of radius `r` about
/// the wrist or the torso, and an object at distance `d` picks up `atan(r/d)` of
/// disparity that no bundle adjustment can undo — 97 px at 6144 wide for a wall
/// at 1 m and a 10 cm swing. Graph-cut seam finding *hides* it. Nothing removes
/// it. So the only real mitigation is the user's hands, and the only place to
/// reach them is here, before they start turning.
class SpherePreCaptureScreen extends StatelessWidget {
  /// Creates the pre-capture screen for [plan].
  const SpherePreCaptureScreen({
    required this.plan,
    required this.onStart,
    super.key,
    this.onCancel,
    this.capability,
    this.estimatedDuration,
    this.monopodNote,
    this.locationNote = 'Stand where the pin is.',
  });

  /// The plan about to be shot; its length is the photo count shown.
  final CapturePlan plan;

  /// Called when the user presses Start.
  final VoidCallback onStart;

  /// Called when the user backs out.
  final VoidCallback? onCancel;

  /// What this device can do, from [SphereCapabilityProbe].
  ///
  /// This screen is the **UI** feature entry point, and Phase 12 §1 puts the
  /// capability gate exactly here: a tablet with no gyroscope shows the reason
  /// and no Start button, and a tablet that can capture but cannot bracket says
  /// so *before* the operator spends ninety seconds finding out that every
  /// window in the panorama is white.
  ///
  /// Optional, because a host app that has already gated elsewhere should not be
  /// forced to probe twice — but when it is absent this screen cannot warn, and
  /// that is the caller's choice to make rather than this widget's to fake.
  final SphereCapabilityReport? capability;

  /// Overrides the estimate. Defaults to [estimateFor].
  final Duration? estimatedDuration;

  /// Site-specific line about a tablet clamp, shown when supplied (§3.1).
  ///
  /// A clamp on a monopod makes `r ≈ 0`, which is the only way to remove
  /// parallax rather than hide it — worth saying wherever one exists.
  final String? monopodNote;

  /// Where to stand. The host app knows the station; this is the sentence it
  /// gets to replace.
  final String locationNote;

  /// Rough capture time for a plan of [positions] positions.
  ///
  /// From S7: 29 positions in ≤ 90 s, i.e. ~3 s of aim, dwell and bracket per
  /// position. Rounded to ten seconds because a number like "87 seconds" claims
  /// a precision this cannot have and invites the user to time it.
  static Duration estimateFor(int positions) =>
      Duration(seconds: math.max(10, (positions * 3.1 / 10).round() * 10));

  @override
  Widget build(BuildContext context) {
    final estimate = estimatedDuration ?? estimateFor(plan.length);
    return DefaultTextStyle(
      style: const TextStyle(
        color: CaptureHudColors.foreground,
        fontSize: 18,
        fontWeight: FontWeight.w400,
        decoration: TextDecoration.none,
      ),
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _line(locationNote),
                        _line('Hold the tablet upright, arms in.'),
                        _line(
                          'Turn your body slowly — pivot, don’t walk.',
                          emphasis: true,
                        ),
                        const SizedBox(height: 24),
                        const AspectRatio(
                          aspectRatio: 2.1,
                          child: PivotDiagram(),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          '${plan.length} photos · about '
                          '${estimate.inSeconds} seconds',
                          style: const TextStyle(
                            color: CaptureHudColors.foreground,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        if (monopodNote != null) ...[
                          const SizedBox(height: 12),
                          Text(monopodNote!),
                        ],
                        // The device's own limits, before the shutter rather than
                        // after 29 of them. One sentence each, from the same
                        // message table the review screen uses, so a manager who
                        // reads "single-exposure only on this tablet" here
                        // recognises the sentence when the panorama's report
                        // repeats it.
                        for (final warning in capability?.warnings ?? const [])
                          ...[
                            const SizedBox(height: 12),
                            Text(
                              warning.message,
                              style: const TextStyle(
                                color: CaptureHudColors.foreground,
                                fontSize: 16,
                                // Weight rather than colour, because Phase 09's
                                // palette is two tones on purpose: any third
                                // shade is the one that vanishes against a
                                // sunlit wall or an unlit ceiling.
                                fontWeight: FontWeight.w700,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // No Start on a device that cannot do this at all. Hidden rather
                // than disabled: a greyed-out button invites tapping it to find
                // out why, and the reason is already on screen above.
                if (capability?.isSupported ?? true)
                  Center(
                    child: CaptureTextButton(label: 'Start', onPressed: onStart),
                  ),
                if (onCancel != null) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: CaptureTextButton(
                      label: 'Not now',
                      onPressed: onCancel,
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

  Widget _line(String text, {bool emphasis = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: TextStyle(
        color: CaptureHudColors.foreground,
        fontSize: emphasis ? 24 : 20,
        fontWeight: emphasis ? FontWeight.w700 : FontWeight.w400,
        decoration: TextDecoration.none,
      ),
    ),
  );
}

/// The diagram beside "pivot, don't walk": the tablet turning about a vertical
/// axis through its own lens, and — crossed out — the tablet swung around the
/// body.
///
/// Drawn rather than shipped as an asset so it scales, needs no resolution
/// variants, and carries the same white-on-black treatment as the rest of the
/// capture flow. Both halves are viewed from above.
class PivotDiagram extends StatelessWidget {
  /// Creates the diagram.
  const PivotDiagram({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label:
        'Diagram: turn the tablet about a vertical line through its own lens, '
        'not by swinging it around your body.',
    child: const CustomPaint(painter: _PivotDiagramPainter()),
  );
}

class _PivotDiagramPainter extends CustomPainter {
  const _PivotDiagramPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final half = size.width / 2;
    _panel(
      canvas,
      Rect.fromLTWH(0, 0, half, size.height),
      radius: 0,
      crossedOut: false,
    );
    _panel(
      canvas,
      Rect.fromLTWH(half, 0, half, size.height),
      radius: 0.34,
      crossedOut: true,
    );
  }

  /// One half of the diagram.
  ///
  /// [radius] is the swing radius as a fraction of the panel's half-width: `0`
  /// is the tablet turning on its own lens, and anything more is the lens
  /// tracing a circle — which is precisely the quantity `r` in architecture §3's
  /// disparity table.
  void _panel(
    Canvas canvas,
    Rect panel, {
    required double radius,
    required bool crossedOut,
  }) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = CaptureHudColors.foreground;
    final fill = Paint()..color = CaptureHudColors.foreground;
    final ghost = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = CaptureHudColors.reticle;

    final centre = Offset(panel.center.dx, panel.center.dy + panel.height * 0.06);
    final unit = panel.width * 0.5;
    final swing = unit * radius;
    final tablet = Size(unit * 0.30, unit * 0.46);

    // The arc the lens travels. A point at the centre in the left panel; a
    // circle in the right one.
    if (swing > 0) {
      canvas.drawCircle(
        centre,
        swing,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = CaptureHudColors.reticle,
      );
      // The body the tablet is being swung around.
      canvas.drawCircle(centre, unit * 0.07, stroke);
    }

    // Three tablet positions around the turn, so the motion reads as a rotation
    // rather than a still.
    for (final angle in [-0.9, 0.0, 0.9]) {
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate(angle);
      canvas.translate(0, -swing);
      final body = Rect.fromCenter(
        center: Offset.zero,
        width: tablet.width,
        height: tablet.height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(body, const Radius.circular(3)),
        angle == 0.0 ? stroke : ghost,
      );
      // The lens, and the axis the tablet should be turning about.
      canvas.drawCircle(Offset.zero, 3, fill);
      canvas.restore();
    }

    // The vertical axis itself, through the lens on the left and through the
    // body on the right — the whole difference between the two panels.
    canvas.drawLine(
      Offset(centre.dx, panel.top + panel.height * 0.08),
      Offset(centre.dx, panel.bottom - panel.height * 0.12),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = CaptureHudColors.reticle,
    );

    if (crossedOut) {
      final cross = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = CaptureHudColors.foreground;
      final inset = panel.deflate(panel.width * 0.14);
      canvas.drawLine(inset.topLeft, inset.bottomRight, cross);
      canvas.drawLine(inset.topRight, inset.bottomLeft, cross);
    }
  }

  @override
  bool shouldRepaint(covariant _PivotDiagramPainter oldDelegate) => false;
}
