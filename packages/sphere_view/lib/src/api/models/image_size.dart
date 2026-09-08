import 'json_codec.dart';

/// Pixel dimensions of an image, as a value type the model layer can own.
///
/// This is deliberately **not** `dart:ui.Size`. Every model in this directory
/// has to be loadable by `tools/replay`, which is a plain `dart run` CLI with
/// no Flutter engine and therefore no `dart:ui` (architecture §6.6 — offline
/// replay is the highest-leverage decision in the project, so the data model
/// must not be able to break it). Widths and heights are `double` rather than
/// `int` because the registration stage works at a fractional downscale
/// (~0.6 MP) and intrinsics have to be rescaled exactly to it.
class ImageSize {
  /// Creates a size of [width] × [height] pixels.
  const ImageSize(this.width, this.height);

  /// Convenience for the common case of integral pixel dimensions.
  ImageSize.fromInts(int width, int height)
    : width = width.toDouble(),
      height = height.toDouble();

  /// Width in pixels.
  final double width;

  /// Height in pixels.
  final double height;

  /// Width divided by height. `0` when [height] is zero.
  double get aspectRatio => height == 0 ? 0 : width / height;

  /// Total pixel count, used by the memory tier and the registration downscale.
  double get area => width * height;

  /// Returns this size scaled uniformly by [factor].
  ImageSize operator *(double factor) =>
      ImageSize(width * factor, height * factor);

  /// Serialises to `{"width": …, "height": …}`.
  Map<String, Object?> toJson() => {'width': width, 'height': height};

  /// Inverse of [toJson].
  factory ImageSize.fromJson(Map<String, Object?> json) => ImageSize(
    jsonDouble(json, 'width', context: 'ImageSize'),
    jsonDouble(json, 'height', context: 'ImageSize'),
  );

  @override
  bool operator ==(Object other) =>
      other is ImageSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'ImageSize(${width}x$height)';
}
