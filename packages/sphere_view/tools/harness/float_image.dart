import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A floating-point raster, and the only image buffer the harness passes
/// around.
///
/// Everything the rig does — accumulating radiance, applying a camera
/// response, differencing against ground truth, computing SSIM — is arithmetic
/// that saturates or quantises the moment it touches 8-bit. A synthetic rig
/// whose own rounding error is comparable to the stitcher error it is trying to
/// measure is not measuring anything, so 8-bit exists here only at the two
/// edges: decoding a ground-truth PNG, and encoding a rendered frame.
///
/// Values are nominally in `[0, 1]`, but radiance buffers deliberately exceed
/// 1 — that is what a blown window *is*, and clipping it early would delete the
/// dynamic range the HDR profiles exist to exercise.
class FloatImage {
  /// Creates a zero-filled image.
  FloatImage(this.width, this.height, this.channels)
    : data = Float32List(width * height * channels);

  /// Wraps an existing buffer; [data] must be `width · height · channels` long.
  FloatImage.wrap(this.width, this.height, this.channels, this.data)
    : assert(data.length == width * height * channels);

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Samples per pixel: 3 for colour, 1 for depth / EV / weight maps.
  final int channels;

  /// Interleaved samples, row-major.
  final Float32List data;

  /// Index of the first channel of pixel ([x], [y]).
  int offset(int x, int y) => (y * width + x) * channels;

  /// Channel [c] of pixel ([x], [y]).
  double at(int x, int y, int c) => data[(y * width + x) * channels + c];

  /// Sets channel [c] of pixel ([x], [y]).
  void setAt(int x, int y, int c, double value) {
    data[(y * width + x) * channels + c] = value;
  }

  /// An independent copy.
  FloatImage clone() =>
      FloatImage.wrap(width, height, channels, Float32List.fromList(data));

  /// Multiplies every sample by [factor], in place.
  void scale(double factor) {
    for (var i = 0; i < data.length; i++) {
      data[i] *= factor;
    }
  }

  /// Reads a texel with **horizontal wrap and vertical clamp** — the boundary
  /// rule an equirectangular image actually has.
  ///
  /// Wrapping x is not a convenience: columns `0` and `W` are the same
  /// meridian, and a sampler that clamps there instead is the origin of the
  /// vertical seam at yaw ±180° that architecture §7 calls the single most
  /// common bug in hand-rolled 360 stitchers. Clamping y is correct for a
  /// different reason — beyond the pole there is no row, only the same pole
  /// again, and clamping reproduces the pole's own colour.
  double tap(int x, int y, int c) {
    var xi = x % width;
    if (xi < 0) xi += width;
    final yi = y < 0
        ? 0
        : y >= height
        ? height - 1
        : y;
    return data[(yi * width + xi) * channels + c];
  }

  /// Bicubic (Catmull–Rom) sample at fractional ([x], [y]), into [out].
  ///
  /// Bicubic rather than bilinear because the rig is the *reference*: bilinear
  /// resampling loses roughly 0.5 dB of PSNR against a perfect stitch, which is
  /// a sixth of the entire margin criterion S6 is asking about. The kernel can
  /// overshoot into negative values on a hard edge; that is left unclamped here
  /// and dealt with by the caller, because radiance buffers legitimately exceed
  /// the display range in the other direction too.
  void sampleBicubic(double x, double y, List<double> out) {
    final x0 = x.floor();
    final y0 = y.floor();
    final tx = x - x0;
    final ty = y - y0;
    for (var c = 0; c < channels; c++) {
      var acc = 0.0;
      for (var j = -1; j <= 2; j++) {
        final p0 = tap(x0 - 1, y0 + j, c);
        final p1 = tap(x0, y0 + j, c);
        final p2 = tap(x0 + 1, y0 + j, c);
        final p3 = tap(x0 + 2, y0 + j, c);
        acc += _catmullRom(p0, p1, p2, p3, tx) * _catmullRomWeight(j, ty);
      }
      out[c] = acc;
    }
  }

  /// Bilinear sample at fractional ([x], [y]), into [out]. Used where the
  /// sampled quantity is already smooth — depth and EV maps — and the extra
  /// taps would buy nothing.
  void sampleBilinear(double x, double y, List<double> out) {
    final x0 = x.floor();
    final y0 = y.floor();
    final tx = x - x0;
    final ty = y - y0;
    for (var c = 0; c < channels; c++) {
      final a = tap(x0, y0, c) * (1 - tx) + tap(x0 + 1, y0, c) * tx;
      final b = tap(x0, y0 + 1, c) * (1 - tx) + tap(x0 + 1, y0 + 1, c) * tx;
      out[c] = a * (1 - ty) + b * ty;
    }
  }

  static double _catmullRom(
    double p0,
    double p1,
    double p2,
    double p3,
    double t,
  ) {
    final t2 = t * t;
    final t3 = t2 * t;
    return 0.5 *
        (2 * p1 +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
  }

  static double _catmullRomWeight(int j, double t) {
    final t2 = t * t;
    final t3 = t2 * t;
    return switch (j) {
      -1 => 0.5 * (-t + 2 * t2 - t3),
      0 => 0.5 * (2 - 5 * t2 + 3 * t3),
      1 => 0.5 * (t + 4 * t2 - 3 * t3),
      _ => 0.5 * (-t2 + t3),
    };
  }

  /// Decodes an 8-bit image file into `[0, 1]` display-referred samples.
  static Future<FloatImage> loadRgb(File file) async {
    final decoded = img.decodeImage(await file.readAsBytes());
    if (decoded == null) {
      throw FormatException('could not decode an image from ${file.path}');
    }
    final out = FloatImage(decoded.width, decoded.height, 3);
    var i = 0;
    for (final pixel in decoded) {
      out.data[i++] = pixel.rNormalized.toDouble();
      out.data[i++] = pixel.gNormalized.toDouble();
      out.data[i++] = pixel.bNormalized.toDouble();
    }
    return out;
  }

  /// Decodes a single-channel image, preserving 16-bit precision when present.
  ///
  /// [scale] converts the stored integer back to physical units — metres for a
  /// depth map, stops for an EV map — and [bias] shifts it, so a map that has
  /// to represent negative values (EV) round-trips exactly.
  static Future<FloatImage> loadScalar(
    File file, {
    double scale = 1.0,
    double bias = 0.0,
  }) async {
    final decoded = img.decodeImage(await file.readAsBytes());
    if (decoded == null) {
      throw FormatException('could not decode an image from ${file.path}');
    }
    final out = FloatImage(decoded.width, decoded.height, 1);
    var i = 0;
    for (final pixel in decoded) {
      out.data[i++] = pixel.rNormalized.toDouble() * scale + bias;
    }
    return out;
  }

  /// Encodes to 8-bit RGB PNG, rounding rather than truncating.
  img.Image toRgb8() {
    final out = img.Image(width: width, height: height, numChannels: 3);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final o = offset(x, y);
        out.setPixelRgb(
          x,
          y,
          _quantise(data[o]),
          _quantise(data[o + (channels > 1 ? 1 : 0)]),
          _quantise(data[o + (channels > 2 ? 2 : 0)]),
        );
      }
    }
    return out;
  }

  /// Encodes a scalar map to a 16-bit greyscale PNG. [scale] and [bias] are the
  /// inverse of [loadScalar]'s.
  img.Image toScalar16({double scale = 1.0, double bias = 0.0}) {
    final out = img.Image(
      width: width,
      height: height,
      numChannels: 1,
      format: img.Format.uint16,
    );
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final v = ((at(x, y, 0) - bias) / scale * 65535).round().clamp(0, 65535);
        out.setPixelR(x, y, v);
      }
    }
    return out;
  }

  static int _quantise(double v) =>
      (v * 255).round().clamp(0, 255);
}

/// Display-referred → linear radiance, and back.
///
/// A plain 2.2 power law rather than the sRGB piecewise curve. The rig only
/// needs the two to be exact inverses of each other — the `pristine` profile's
/// "near-pixel-perfect" claim rests on that round trip and on nothing else —
/// and a power law is exactly invertible where the piecewise curve's toe
/// invites an off-by-one near black.
class ToneCurve {
  const ToneCurve._();

  /// The exponent both directions share.
  static const double gamma = 2.2;

  /// Display value in `[0, 1]` → linear radiance.
  static double toLinear(double v) => v <= 0 ? 0 : math.pow(v, gamma).toDouble();

  /// Linear radiance → display value, **unclipped** so the caller decides where
  /// the sensor saturates.
  static double toDisplay(double v) =>
      v <= 0 ? 0 : math.pow(v, 1 / gamma).toDouble();
}
