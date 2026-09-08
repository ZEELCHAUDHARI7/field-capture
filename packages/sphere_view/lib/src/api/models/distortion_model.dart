import 'json_codec.dart';

/// A lens distortion model, in whatever form the platform could supply it.
///
/// Exists because §2 defect 3 of the architecture — "no lens distortion model
/// at all" — is one of the five reasons the previous stitcher could not close a
/// panorama: without undistortion, straight edges bow near the frame border and
/// two perfectly-oriented neighbours still refuse to align at their overlap.
///
/// It is a *sum type* rather than one struct because the two platforms hand us
/// genuinely different mathematics and flattening them early would lose
/// information: Android gives Brown–Conrady coefficients directly (R2:
/// `LENS_DISTORTION` is a pure reorder away from OpenCV's), while iOS gives a
/// radial magnification lookup table with no tangential component at all
/// (Math §4.2). Carrying the raw form means the least-squares fit from LUT to
/// coefficients happens once, in the native stage that needs it, and stays
/// auditable.
sealed class DistortionModel {
  /// Const base constructor for the two variants.
  const DistortionModel();

  /// Serialises with a `type` discriminator so `fromJson` can dispatch.
  Map<String, Object?> toJson();

  /// Returns the same model expressed for an image scaled by [scaleX]/[scaleY].
  ///
  /// Whether anything changes depends on the variant: Brown–Conrady operates on
  /// normalised coordinates and is scale-invariant, while a lookup table's
  /// centre is in pixels and must move with the image.
  DistortionModel scaledBy(double scaleX, double scaleY);

  /// Dispatches on the `type` discriminator written by [toJson].
  factory DistortionModel.fromJson(Map<String, Object?> json) {
    final type = jsonString(json, 'type', context: 'DistortionModel');
    return switch (type) {
      BrownConradyDistortion.typeName => BrownConradyDistortion.fromJson(json),
      LookupTableDistortion.typeName => LookupTableDistortion.fromJson(json),
      _ => throw SphereJsonFormatException(
        'DistortionModel.type',
        'unknown distortion model "$type"',
      ),
    };
  }
}

/// Brown–Conrady radial + tangential distortion, in **OpenCV coefficient
/// order** `(k1, k2, p1, p2, k3)`.
///
/// The ordering is stated in the type rather than left to a comment because it
/// is the exact place the Android path can go wrong: `LENS_DISTORTION` reports
/// `[κ1, κ2, κ3, κ4, κ5]` = `[R, R, R, T, T]` while OpenCV wants `[R, R, T, T, R]`.
/// R2 established that this is a *pure reorder* with no value transform — so
/// anything constructing this class from Android must pass
/// `{κ1, κ2, κ4, κ5, κ3}` (Math §4.1). Storing it already-reordered means the
/// native side never has to know which platform the numbers came from.
class BrownConradyDistortion extends DistortionModel {
  /// Creates a Brown–Conrady model from OpenCV-ordered coefficients.
  const BrownConradyDistortion({
    required this.k1,
    required this.k2,
    required this.p1,
    required this.p2,
    required this.k3,
  });

  /// Builds the model from Android's `LENS_DISTORTION` array
  /// `[κ1, κ2, κ3, κ4, κ5]`, applying the R2 reorder.
  factory BrownConradyDistortion.fromAndroidLensDistortion(
    List<double> kappa,
  ) {
    if (kappa.length != 5) {
      throw ArgumentError.value(
        kappa,
        'kappa',
        'LENS_DISTORTION must have exactly 5 elements',
      );
    }
    return BrownConradyDistortion(
      k1: kappa[0],
      k2: kappa[1],
      p1: kappa[3],
      p2: kappa[4],
      k3: kappa[2],
    );
  }

  /// The `type` discriminator used on the wire.
  static const String typeName = 'brown_conrady';

  /// Second-order radial coefficient.
  final double k1;

  /// Fourth-order radial coefficient.
  final double k2;

  /// First tangential coefficient. Always `0` on iOS — Apple's model gives no
  /// basis for tangential terms, and fitting them would be fitting noise.
  final double p1;

  /// Second tangential coefficient. See [p1].
  final double p2;

  /// Sixth-order radial coefficient.
  final double k3;

  /// The five coefficients in OpenCV order, ready to hand to `cv::undistort`.
  List<double> get openCvCoefficients => [k1, k2, p1, p2, k3];

  /// `true` when every coefficient is zero, i.e. an ideal pinhole.
  bool get isIdentity =>
      k1 == 0 && k2 == 0 && p1 == 0 && p2 == 0 && k3 == 0;

  @override
  DistortionModel scaledBy(double scaleX, double scaleY) => this;

  @override
  Map<String, Object?> toJson() => {
    'type': typeName,
    'k1': k1,
    'k2': k2,
    'p1': p1,
    'p2': p2,
    'k3': k3,
  };

  /// Inverse of [toJson].
  factory BrownConradyDistortion.fromJson(Map<String, Object?> json) {
    const ctx = 'BrownConradyDistortion';
    return BrownConradyDistortion(
      k1: jsonDouble(json, 'k1', context: ctx),
      k2: jsonDouble(json, 'k2', context: ctx),
      p1: jsonDouble(json, 'p1', context: ctx),
      p2: jsonDouble(json, 'p2', context: ctx),
      k3: jsonDouble(json, 'k3', context: ctx),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BrownConradyDistortion &&
      other.k1 == k1 &&
      other.k2 == k2 &&
      other.p1 == p1 &&
      other.p2 == p2 &&
      other.k3 == k3;

  @override
  int get hashCode => Object.hash(k1, k2, p1, p2, k3);

  @override
  String toString() =>
      'BrownConradyDistortion(k1: $k1, k2: $k2, p1: $p1, p2: $p2, k3: $k3)';
}

/// iOS `lensDistortionLookupTable`: radial magnification sampled along the
/// radius from [centerX]/[centerY] out to the farthest image corner.
///
/// Kept in its native form rather than converted at capture time because the
/// conversion is a least-squares fit (Math §4.2) and a fit is a place where
/// error is introduced. Storing the table means a bundle captured today can be
/// re-fit by a better estimator tomorrow and replayed — which is the whole
/// point of the bundle being self-describing.
class LookupTableDistortion extends DistortionModel {
  /// Creates a lookup-table model.
  const LookupTableDistortion({
    required this.magnifications,
    required this.centerX,
    required this.centerY,
  });

  /// The `type` discriminator used on the wire.
  static const String typeName = 'lookup_table';

  /// Magnification factors `r'/r`, uniformly sampled from radius `0` at index
  /// `0` to the maximum radius (centre to farthest corner) at the last index.
  final List<double> magnifications;

  /// Distortion centre, x, in pixels of the owning intrinsics' image size.
  ///
  /// This is Apple's `lensDistortionCenter`, which is *not* necessarily the
  /// principal point and *not* necessarily the image centre.
  final double centerX;

  /// Distortion centre, y, in pixels of the owning intrinsics' image size.
  final double centerY;

  @override
  DistortionModel scaledBy(double scaleX, double scaleY) =>
      LookupTableDistortion(
        magnifications: magnifications,
        centerX: centerX * scaleX,
        centerY: centerY * scaleY,
      );

  @override
  Map<String, Object?> toJson() => {
    'type': typeName,
    'magnifications': magnifications,
    'center_x': centerX,
    'center_y': centerY,
  };

  /// Inverse of [toJson].
  factory LookupTableDistortion.fromJson(Map<String, Object?> json) {
    const ctx = 'LookupTableDistortion';
    return LookupTableDistortion(
      magnifications: jsonDoubleList(json, 'magnifications', context: ctx),
      centerX: jsonDouble(json, 'center_x', context: ctx),
      centerY: jsonDouble(json, 'center_y', context: ctx),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LookupTableDistortion &&
      other.centerX == centerX &&
      other.centerY == centerY &&
      listEquals(other.magnifications, magnifications);

  @override
  int get hashCode =>
      Object.hash(centerX, centerY, listHash(magnifications));

  @override
  String toString() =>
      'LookupTableDistortion(${magnifications.length} samples, '
      'centre: ($centerX, $centerY))';
}
