import 'package:flutter/material.dart';
import 'package:sphere_view/sphere_view.dart';

/// A debug control that cycles the capture preview's rotation on the device.
///
/// **Why this exists in the example rather than in the package.** The preview's
/// orientation is the one decision in `sphere_view` that cannot be settled on a
/// desk: every input to it — the sensor's mounting angle, the preview stream's
/// reported size, whether the platform already turned the buffer on the way out —
/// is something the *device* says about itself, and devices are inconsistent about
/// all three. A rotation that is right on one tablet is a quarter turn out on
/// another, and the symptom is unmistakable but the cause is not: pan sideways and
/// the scene slides vertically.
///
/// So rather than another round of "try this, rebuild, send me a photo", this
/// shows the numbers the device reported and lets you cycle the turn until the
/// preview stands up. The value that works is the one to pass as
/// [SphereCaptureView.previewQuarterTurns] — and it is also the answer to give a
/// bug report, because it says what this device model does.
///
/// It is a *diagnostic*, not a setting. A shipping app should not need it: once a
/// device's answer is known it belongs in the package's derivation, not in a
/// button. If you find yourself needing it, that is the bug report.
class PreviewRotationProbe extends StatelessWidget {
  /// Creates the probe.
  const PreviewRotationProbe({
    required this.session,
    required this.quarterTurns,
    required this.onChanged,
    super.key,
  });

  /// The session whose camera facts are shown.
  final SphereCaptureSession session;

  /// The turn currently applied, `0..3`.
  final int quarterTurns;

  /// Called with the next turn when the user taps.
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final preview = session.previewSize;
    final capture = session.deviceIntrinsics.imageSize;
    return Material(
      color: const Color(0xCC000000),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onChanged((quarterTurns + 1) % 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.screen_rotation, size: 16, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    'preview turn $quarterTurns — tap to rotate',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              // The three numbers the derivation is made from. If the preview only
              // stands up at a turn the package did not choose, these say why.
              Text(
                'default ${session.previewQuarterTurns} · '
                'preview ${preview.width.toInt()}×${preview.height.toInt()} · '
                'device frame ${capture.width.toInt()}×${capture.height.toInt()}',
                style: const TextStyle(
                  color: Color(0xFFBBBBBB),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
