import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../camera/camera_platform.dart';
import '../camera/pigeon_camera_platform.dart';

/// How large a texture this GPU will accept, and what to do about it.
///
/// Phase 11 §3.1 names this as *the* real problem with a 6144×3072 panorama,
/// and the reason is the failure mode rather than the size. Many mid-range
/// tablet GPUs cap `GL_MAX_TEXTURE_SIZE` at 4096. An 8192-wide upload against
/// such a cap does not throw, does not log and does not degrade — it produces a
/// **black sphere**. To the user that is indistinguishable from a stitcher that
/// wrote an empty file, and to a developer it is indistinguishable from a
/// shader bug, so it is the kind of defect that costs days and then ships
/// anyway on the one device nobody had.
class TextureLimit {
  /// Creates a limit.
  const TextureLimit(this.maxEdgePx, {this.probed = true});

  /// What to assume when the platform will not say.
  ///
  /// 4096 is the floor the OpenGL ES 3.0 specification guarantees and the cap
  /// real mid-range tablets actually sit at. Assuming *more* than the device
  /// can do is the failure this class exists to prevent, so an unknown answer
  /// resolves downwards: a panorama downscaled unnecessarily loses some
  /// sharpness, while one that was not downscaled when it needed to be loses
  /// everything.
  static const int conservativeFloor = 4096;

  /// The largest edge, in pixels, that may be uploaded.
  final int maxEdgePx;

  /// Whether [maxEdgePx] came from the GPU or from [conservativeFloor].
  final bool probed;

  /// The fallback limit, for a platform that did not answer.
  static const TextureLimit unknown =
      TextureLimit(conservativeFloor, probed: false);

  /// Asks the platform, falling back to [unknown] on any failure.
  ///
  /// Cached by the caller, not here: the answer cannot change while the process
  /// lives, but a global cache in a library makes it impossible for a test to
  /// pose as a 4096-limited device.
  static Future<TextureLimit> probe({SphereCameraPlatform? platform}) async {
    try {
      final size = await (platform ?? PigeonCameraPlatform()).maxTextureSize();
      return size > 0 ? TextureLimit(size) : unknown;
    } on Object {
      return unknown;
    }
  }

  /// The width to decode a [sourceWidth]×[sourceHeight] panorama at so that
  /// both edges fit, preserving the 2:1 ratio.
  ///
  /// Returns [sourceWidth] unchanged when it already fits, so the common case
  /// costs nothing. Equirectangular is 2:1, so the width is always the binding
  /// edge and halving it keeps the aspect exactly — no rounding drift that
  /// would put the horizon a fraction of a pixel out.
  int decodeWidthFor(int sourceWidth, int sourceHeight) {
    var width = sourceWidth;
    var height = sourceHeight;
    // Successive halving rather than an exact fit, because halving an equirect
    // keeps it exactly 2:1 and keeps it cheap to filter. Both edges are tested
    // even though the width binds for every 2:1 image, so that a caller who
    // hands this a non-panorama gets a legal texture rather than a black one.
    while ((width > maxEdgePx || height > maxEdgePx) && width > 2) {
      width ~/= 2;
      height ~/= 2;
    }
    return width;
  }

  /// Whether a [width]-wide panorama would have to be downscaled.
  bool requiresDownscale(int width) => width > maxEdgePx;

  @override
  String toString() =>
      'TextureLimit($maxEdgePx px${probed ? '' : ', assumed'})';
}

/// A decoded panorama and what had to be done to it to make it uploadable.
class PanoramaTexture {
  /// Creates a texture record.
  const PanoramaTexture({
    required this.image,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.isPreview,
    this.downscaleNote,
  });

  /// The decoded image, ready for `setImageSampler`.
  final ui.Image image;

  /// The panorama's real width before any downscale.
  final int sourceWidth;

  /// The panorama's real height before any downscale.
  final int sourceHeight;

  /// Whether this is the fast low-resolution pass rather than the final one.
  final bool isPreview;

  /// Set when the image was downscaled to fit the GPU, in plain language.
  ///
  /// Reaches the caller rather than staying in a log, because architecture §8's
  /// rule is that every compromise is visible: a manager zooming in on a defect
  /// deserves to know they are looking at a 4096-wide rendering of a 8192-wide
  /// capture, and that the file itself is still the full size.
  final String? downscaleNote;

  /// Disposes the underlying image.
  void dispose() => image.dispose();
}

/// Decodes panoramas for the viewer, off the UI thread and within the GPU's
/// limits.
///
/// Two responsibilities that look separate and are not. The decode has to
/// happen off the UI thread (§3.1) *and* has to produce an image no larger than
/// the GPU will take (§3.1 again), and `instantiateImageCodec`'s `targetWidth`
/// does both in one step — it resizes during decode rather than after, so a
/// 8192-wide JPEG on a 4096-limited device never has the full-size bitmap in
/// memory at all. Decoding at full size and then scaling would allocate 134 MB
/// to produce a 33 MB image, on the devices least able to afford it.
class PanoramaLoader {
  /// Creates a loader against [limit].
  const PanoramaLoader(this.limit);

  /// The GPU's texture ceiling.
  final TextureLimit limit;

  /// Decodes [bytes], downscaling if the GPU requires it.
  ///
  /// [isPreview] only labels the result; the preview and the full image go
  /// through the same path because the preview also has to be a legal texture,
  /// and a second code path that skipped the check would be a second place for
  /// the black sphere to come from.
  Future<PanoramaTexture> decode(
    Uint8List bytes, {
    bool isPreview = false,
  }) async {
    // Reads the header only; the pixels are not decoded here.
    final descriptor = await ui.ImageDescriptor.encoded(
      await ui.ImmutableBuffer.fromUint8List(bytes),
    );
    final sourceWidth = descriptor.width;
    final sourceHeight = descriptor.height;
    final targetWidth = limit.decodeWidthFor(sourceWidth, sourceHeight);

    // Scaled from the source ratio rather than assumed to be half the width.
    // It *is* half for every panorama this package produces, but the viewer is
    // documented as accepting any 2:1 image and in practice gets handed
    // whatever a caller has — and a hard-coded 2:1 would silently squash a
    // non-panorama rather than merely displaying it oddly.
    final targetHeight = math.max(
      1,
      (sourceHeight * targetWidth / sourceWidth).round(),
    );

    final ui.Codec codec;
    if (targetWidth == sourceWidth) {
      codec = await descriptor.instantiateCodec();
    } else {
      // Both dimensions are given. Passing only `targetWidth` lets the engine
      // pick the height, and for a 2:1 equirect a height that is off by one
      // row puts the horizon fractionally out of place — which is invisible
      // until somebody compares the viewer against the file.
      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
    }
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();

    return PanoramaTexture(
      image: frame.image,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      isPreview: isPreview,
      downscaleNote: targetWidth == sourceWidth
          ? null
          : 'This panorama is $sourceWidth×$sourceHeight, and this device\'s '
                'graphics hardware accepts textures up to ${limit.maxEdgePx} '
                'pixels, so it is being displayed at $targetWidth×'
                '$targetHeight. The saved file is unaffected and is still '
                'full resolution.',
    );
  }
}
