import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Measures how sharp a frame is, as the variance of a 3×3 Laplacian over
/// luminance.
///
/// Exists because a blurred frame is the one defect the pipeline genuinely
/// cannot repair: bundle adjustment can fix a wrong rotation and the gain
/// compensator can fix a wrong exposure, but there is no operator that puts
/// back detail the shutter smeared. So it has to be caught at capture, while
/// the user is still standing there and re-prompting them costs three seconds
/// (architecture §8).
///
/// Sharp images concentrate energy in the Laplacian; blurred ones smear it out,
/// so the variance separates them. The absolute value is scene-dependent, which
/// is why the threshold is a config field tuned per device tier in Phase 12
/// rather than a constant here.
class Sharpness {
  /// Creates a detector that downscales to [downscaleTo] px on the long edge.
  const Sharpness({this.downscaleTo = 320});

  /// Long-edge size the image is reduced to before the Laplacian runs.
  ///
  /// Running the full 12 MP frame would be wasteful and, worse, slow enough to
  /// stall the capture loop between positions — the measurement has to finish
  /// before the user has moved on.
  final int downscaleTo;

  /// Decodes [file] on a background isolate and returns its Laplacian
  /// variance, or `null` when the file cannot be decoded.
  static Future<double?> ofFile(File file) async {
    final bytes = await file.readAsBytes();
    return compute(_varianceOfBytes, bytes);
  }

  static double? _varianceOfBytes(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    return const Sharpness().variance(img.bakeOrientation(decoded));
  }

  /// Laplacian variance of [image]. Returns infinity for images too small to
  /// convolve, so a degenerate input is never mistaken for a blurred one.
  double variance(img.Image image) {
    final scaled = _downscale(image);
    final w = scaled.width;
    final h = scaled.height;
    if (w < 3 || h < 3) return double.infinity;

    final gray = List<int>.filled(w * h, 0);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = scaled.getPixel(x, y);
        final r = p.r.toInt();
        final g = p.g.toInt();
        final b = p.b.toInt();
        gray[y * w + x] = (r * 299 + g * 587 + b * 114) ~/ 1000;
      }
    }

    var sum = 0.0;
    var sumSq = 0.0;
    var count = 0;
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final c = gray[y * w + x];
        final l =
            -4 * c +
            gray[y * w + x - 1] +
            gray[y * w + x + 1] +
            gray[(y - 1) * w + x] +
            gray[(y + 1) * w + x];
        sum += l;
        sumSq += l * l;
        count++;
      }
    }
    final mean = sum / count;
    return sumSq / count - mean * mean;
  }

  img.Image _downscale(img.Image src) {
    final maxSide = src.width > src.height ? src.width : src.height;
    if (maxSide <= downscaleTo) return src;
    final scale = downscaleTo / maxSide;
    return img.copyResize(
      src,
      width: (src.width * scale).round(),
      height: (src.height * scale).round(),
      interpolation: img.Interpolation.linear,
    );
  }
}
