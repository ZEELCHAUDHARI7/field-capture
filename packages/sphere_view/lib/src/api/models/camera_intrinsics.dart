import 'dart:math' as math;

import 'distortion_model.dart';
import 'image_size.dart';
import 'json_codec.dart';

/// Where a set of intrinsics came from, best first.
///
/// R2 established that intrinsics quality is a **gradient, not a constant**:
/// full `AVCameraCalibrationData` needs a multi-camera device, which excludes
/// the base iPad, Air and mini outright, and Android's
/// `LENS_INTRINSIC_CALIBRATION` is reported null even on Pixel hardware. So a
/// panorama can be soft for reasons that have nothing to do with the stitcher,
/// and the only way to tell is to carry the provenance all the way into
/// `StitchReport` (Math §6).
enum IntrinsicsSource {
  /// The platform returned a measured calibration —
  /// `AVCameraCalibrationData.intrinsicMatrix` or
  /// `LENS_INTRINSIC_CALIBRATION`. The best case, and the rarest.
  platformCalibration,

  /// Computed from focal length and sensor geometry (Math §4.1) or from
  /// `videoFieldOfView` (Math §4.2). The realistic primary path on our fleet.
  derivedFromPhysics,

  /// Last resort: `fx = W · FocalLengthIn35mmFilm / 36` from EXIF. Good to
  /// maybe 10%, which bundle adjustment can still recover from (Math §4.3).
  exifFallback,

  /// Refined by `BundleAdjusterRay` from the imagery itself. Only ever
  /// produced by the stitcher, never by the camera probe.
  refinedByStitcher,
}

/// The pinhole model for one camera, in the pixel coordinates of one specific
/// output size.
///
/// This type exists to kill the single worst assumption in the previous
/// implementation: a hard-coded 52° horizontal FOV (architecture §2 defect 2).
/// Real main-camera HFOV in portrait ranges roughly 46°–56° across the tablet
/// fleet, and a 4% focal error means the panorama does not close — the last
/// frame of a full turn lands ~14° from the first. Everything downstream (the
/// shot plan, the warper scale, the coverage proof) is only valid for *these*
/// numbers at *this* [imageSize], which is why the size travels with them.
class CameraIntrinsics {
  /// Creates intrinsics valid for [imageSize] pixel coordinates.
  const CameraIntrinsics({
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.imageSize,
    required this.source,
    this.distortion,
  });

  /// Builds intrinsics from a **horizontal** field of view.
  ///
  /// The "horizontal" is load-bearing: R2 confirmed `videoFieldOfView` is
  /// horizontal, not diagonal, and getting that wrong is a silent ~20% focal
  /// error. Assumes square pixels and a centred principal point, which is what
  /// every FOV-derived path can honestly claim.
  factory CameraIntrinsics.fromHorizontalFov({
    required double hfovRadians,
    required ImageSize imageSize,
    IntrinsicsSource source = IntrinsicsSource.derivedFromPhysics,
    DistortionModel? distortion,
  }) {
    final fx = (imageSize.width / 2) / math.tan(hfovRadians / 2);
    return CameraIntrinsics(
      fx: fx,
      fy: fx,
      cx: imageSize.width / 2,
      cy: imageSize.height / 2,
      imageSize: imageSize,
      source: source,
      distortion: distortion,
    );
  }

  /// Focal length in pixels along x, in [imageSize] coordinates.
  final double fx;

  /// Focal length in pixels along y, in [imageSize] coordinates.
  final double fy;

  /// Principal point x, in [imageSize] coordinates, origin top-left.
  final double cx;

  /// Principal point y, in [imageSize] coordinates, origin top-left.
  final double cy;

  /// The image size these values are expressed in. Intrinsics are meaningless
  /// without it — see [scaledTo].
  final ImageSize imageSize;

  /// Lens distortion, when the platform could supply one. `null` means "not
  /// available", which is a real and common state on our fleet — never
  /// silently substituted with zero coefficients, so `StitchReport` can say so.
  final DistortionModel? distortion;

  /// Provenance, carried into `StitchReport` so a soft panorama can be traced
  /// back to a weak focal estimate rather than blamed on the stitcher.
  final IntrinsicsSource source;

  /// Horizontal field of view: `2·atan(W / (2·fx))` (Math §4).
  double get hfovRadians => 2 * math.atan(imageSize.width / (2 * fx));

  /// Vertical field of view: `2·atan(H / (2·fy))` (Math §4).
  double get vfovRadians => 2 * math.atan(imageSize.height / (2 * fy));

  /// [hfovRadians] in degrees, for logs and UI copy only.
  double get hfovDegrees => hfovRadians * 180 / math.pi;

  /// [vfovRadians] in degrees, for logs and UI copy only.
  double get vfovDegrees => vfovRadians * 180 / math.pi;

  /// The 3×3 `K` matrix, row-major, ready for the JSON ABI.
  List<double> get matrix => [fx, 0, cx, 0, fy, cy, 0, 0, 1];

  /// Rescales to [newSize] — same crop and aspect only.
  ///
  /// Every term is linear in the scale factor, so field of view is preserved
  /// exactly: `2·atan(W·s / (2·fx·s))` is `2·atan(W / (2·fx))`. That identity is
  /// what lets registration run at ~0.6 MP and composite at 8192 wide from one
  /// calibration. It does **not** hold across a change of crop — a 16:9 stream
  /// off a 4:3 sensor is a crop, not a scale, and must be derived from the
  /// actual stream rectangle instead (Math §4.1).
  CameraIntrinsics scaledTo(ImageSize newSize) {
    final sx = newSize.width / imageSize.width;
    final sy = newSize.height / imageSize.height;
    return CameraIntrinsics(
      fx: fx * sx,
      fy: fy * sy,
      cx: cx * sx,
      cy: cy * sy,
      imageSize: newSize,
      source: source,
      distortion: distortion?.scaledBy(sx, sy),
    );
  }

  /// The same camera, described in a frame turned a quarter turn from this one.
  ///
  /// Needed because the capture stream and the device are not always in the
  /// same frame. Android delivers the JPEG off the sensor unrotated
  /// (`JPEG_ORIENTATION = 0`, so the pixels and these numbers agree), and iOS
  /// delivers photos in the sensor's landscape orientation — while the pose,
  /// the plan and the preview all live in the **device** frame, portrait-locked
  /// (Phase 09 §4). On a camera mounted 90° from the display, the two differ by
  /// exactly this transform.
  ///
  /// Getting it wrong is not subtle in effect but is very subtle in appearance:
  /// the horizontal and vertical fields of view swap, so the planner computes a
  /// ring structure for a camera held the other way round and still returns a
  /// plausible-looking shot count.
  ///
  /// With [clockwise] true, a pixel at `(x, y)` moves to `(H − y, x)`: the
  /// old top-left corner becomes the new top-right. The focal lengths swap, and
  /// so do the tangential distortion coefficients — substituting `(x, y) →
  /// (−y, x)` into Brown–Conrady gives `(p1, p2) → (p2, −p1)` clockwise and
  /// `(−p2, p1)` anticlockwise, with the radial terms untouched because they
  /// depend only on `r`.
  CameraIntrinsics rotatedQuarterTurn({bool clockwise = true}) {
    final distortion = this.distortion;
    return CameraIntrinsics(
      fx: fy,
      fy: fx,
      cx: clockwise ? imageSize.height - cy : cy,
      cy: clockwise ? cx : imageSize.width - cx,
      imageSize: ImageSize(imageSize.height, imageSize.width),
      source: source,
      distortion: switch (distortion) {
        null => null,
        BrownConradyDistortion(:final k1, :final k2, :final p1, :final p2, :final k3) =>
          BrownConradyDistortion(
            k1: k1,
            k2: k2,
            p1: clockwise ? p2 : -p2,
            p2: clockwise ? -p1 : p1,
            k3: k3,
          ),
        LookupTableDistortion(
          :final magnifications,
          :final centerX,
          :final centerY,
        ) =>
          LookupTableDistortion(
            magnifications: magnifications,
            centerX: clockwise ? imageSize.height - centerY : centerY,
            centerY: clockwise ? centerX : imageSize.width - centerX,
          ),
      },
    );
  }

  /// Returns a copy with selected fields replaced.
  CameraIntrinsics copyWith({
    double? fx,
    double? fy,
    double? cx,
    double? cy,
    ImageSize? imageSize,
    IntrinsicsSource? source,
    DistortionModel? distortion,
  }) => CameraIntrinsics(
    fx: fx ?? this.fx,
    fy: fy ?? this.fy,
    cx: cx ?? this.cx,
    cy: cy ?? this.cy,
    imageSize: imageSize ?? this.imageSize,
    source: source ?? this.source,
    distortion: distortion ?? this.distortion,
  );

  /// Serialises to the JSON used by both `bundle.json` and the native ABI.
  Map<String, Object?> toJson() => {
    'fx': fx,
    'fy': fy,
    'cx': cx,
    'cy': cy,
    'image_size': imageSize.toJson(),
    'source': source.name,
    'distortion': distortion?.toJson(),
  };

  /// Inverse of [toJson].
  factory CameraIntrinsics.fromJson(Map<String, Object?> json) {
    const ctx = 'CameraIntrinsics';
    final distortion = jsonObjectOrNull(json, 'distortion', context: ctx);
    return CameraIntrinsics(
      fx: jsonDouble(json, 'fx', context: ctx),
      fy: jsonDouble(json, 'fy', context: ctx),
      cx: jsonDouble(json, 'cx', context: ctx),
      cy: jsonDouble(json, 'cy', context: ctx),
      imageSize: ImageSize.fromJson(
        jsonObject(json, 'image_size', context: ctx),
      ),
      source: jsonEnum(json, 'source', IntrinsicsSource.values, context: ctx),
      distortion: distortion == null
          ? null
          : DistortionModel.fromJson(distortion),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CameraIntrinsics &&
      other.fx == fx &&
      other.fy == fy &&
      other.cx == cx &&
      other.cy == cy &&
      other.imageSize == imageSize &&
      other.source == source &&
      other.distortion == distortion;

  @override
  int get hashCode =>
      Object.hash(fx, fy, cx, cy, imageSize, source, distortion);

  @override
  String toString() =>
      'CameraIntrinsics(fx: $fx, fy: $fy, cx: $cx, cy: $cy, '
      'size: $imageSize, hfov: ${hfovDegrees.toStringAsFixed(1)}°, '
      'source: ${source.name})';
}
