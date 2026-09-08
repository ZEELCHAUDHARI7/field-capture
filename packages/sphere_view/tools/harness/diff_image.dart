import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'camera_model.dart';
import 'float_image.dart';
import 'stitcher_backend.dart';

/// The one picture that says where the error is.
///
/// `|stitched − ground truth|`, amplified, with the seam paths drawn over it.
/// The point is diagnostic triage in a single glance, as §2 of the phase doc
/// puts it: error concentrated **on the seam lines** is a registration or
/// blending problem, error **spread across each frame's interior** is
/// intrinsics or distortion, and error in **broad flat patches** is a gain
/// problem. Three very different bugs that all read as "the number went up" in
/// the table.
class DiffImage {
  const DiffImage._();

  /// Default amplification, from the phase doc.
  static const int defaultAmplification = 4;

  /// Renders the diff.
  ///
  /// Seams are drawn in a saturated colour that the amplified greyscale
  /// difference cannot produce on its own, so a seam is never confused with the
  /// error underneath it. Uncovered pixels are drawn in a second such colour
  /// rather than left black, because black is also what "no error here" looks
  /// like and the difference between "perfect" and "absent" is the whole point
  /// of the `partial` profile.
  static img.Image render({
    required FloatImage stitched,
    required FloatImage groundTruth,
    required StitchOutcome outcome,
    required EquirectCanvas canvas,
    int amplification = defaultAmplification,
  }) {
    final out = img.Image(
      width: canvas.width,
      height: canvas.height,
      numChannels: 3,
    );
    final labels = outcome.labels;

    for (var y = 0; y < canvas.height; y++) {
      for (var x = 0; x < canvas.width; x++) {
        final i = y * canvas.width + x;
        final label = labels[i];

        if (label == StitchOutcome.uncovered) {
          // Magenta: nothing reached here.
          out.setPixelRgb(x, y, 200, 0, 160);
          continue;
        }
        if (label == StitchOutcome.poleFilled) {
          // Blue: invented by the pole fill, and excluded from S6.
          out.setPixelRgb(x, y, 0, 90, 220);
          continue;
        }

        var value = 0;
        for (var c = 0; c < 3; c++) {
          final d = (stitched.data[i * 3 + c] - groundTruth.data[i * 3 + c])
              .abs();
          value = math.max(value, (d * 255 * amplification).round());
        }
        final v = value.clamp(0, 255);
        out.setPixelRgb(x, y, v, v, v);
      }
    }

    _drawSeams(out, outcome, canvas);
    return out;
  }

  /// Overlays the seam paths, found the same way S3 finds them — as label
  /// boundaries — so what the eye sees is exactly what the number counted.
  static void _drawSeams(
    img.Image out,
    StitchOutcome outcome,
    EquirectCanvas canvas,
  ) {
    final labels = outcome.labels;
    for (var y = 0; y < canvas.height - 1; y++) {
      for (var x = 0; x < canvas.width; x++) {
        final here = labels[y * canvas.width + x];
        if (here < 0) continue;
        final right = labels[y * canvas.width + (x + 1) % canvas.width];
        final below = labels[(y + 1) * canvas.width + x];
        if ((right >= 0 && right != here) || (below >= 0 && below != here)) {
          // Amber, at half weight, so a bright error underneath still reads
          // through the line rather than being painted over.
          final pixel = out.getPixel(x, y);
          out.setPixelRgb(
            x,
            y,
            (pixel.r.toInt() + 255) ~/ 2,
            (pixel.g.toInt() + 170) ~/ 2,
            pixel.b.toInt() ~/ 2,
          );
        }
      }
    }
  }

  /// A label map coloured by source frame, for when the diff shows a problem
  /// and the next question is *which frame*.
  static img.Image renderLabels({
    required StitchOutcome outcome,
    required EquirectCanvas canvas,
  }) {
    final out = img.Image(
      width: canvas.width,
      height: canvas.height,
      numChannels: 3,
    );
    for (var y = 0; y < canvas.height; y++) {
      for (var x = 0; x < canvas.width; x++) {
        final label = outcome.labels[y * canvas.width + x];
        if (label < 0) {
          out.setPixelRgb(x, y, 24, 24, 24);
          continue;
        }
        // A golden-ratio hue walk, so adjacent frame indices are never adjacent
        // colours and a seam between neighbours is always visible.
        final hue = (label * 0.61803398875) % 1.0;
        final (r, g, b) = _hsv(hue, 0.62, 0.95);
        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  static (int, int, int) _hsv(double h, double s, double v) {
    final i = (h * 6).floor();
    final f = h * 6 - i;
    final p = v * (1 - s);
    final q = v * (1 - f * s);
    final t = v * (1 - (1 - f) * s);
    final (r, g, b) = switch (i % 6) {
      0 => (v, t, p),
      1 => (q, v, p),
      2 => (p, v, t),
      3 => (p, q, v),
      4 => (t, p, v),
      _ => (v, p, q),
    };
    return ((r * 255).round(), (g * 255).round(), (b * 255).round());
  }
}
