import 'dart:math' as math;

import 'json_codec.dart';

/// How many exposures to fire at each position, and how far apart.
///
/// A sum type rather than a bool because the modes carry different data — a
/// bracket has a spread, the others have nothing — and because the choice
/// changes the shape of everything downstream: shots per position, capture
/// duration, and whether the native pipeline runs its Mertens fusion stage at
/// all.
///
/// [ExposureStrategy.auto] is the default. Bracketing was, on the reasoning that
/// construction interiors span 12–16 EV and a single exposure loses one end;
/// that is true of the *scene* but it was the wrong trade for the product. It
/// tripled the shots and the stitch time, it put the non-deterministic
/// `cv::MergeMertens` on the default path, and on device the lock it depended on
/// was not holding anyway. Per-frame metering plus gain compensation gives a
/// result that reads correctly everywhere, three times faster.
sealed class ExposureStrategy {
  /// Const base constructor for the two variants.
  const ExposureStrategy();

  /// One exposure per position, metered freshly at each one. The default.
  ///
  /// The camera is left to do what it does for an ordinary photo, which is what
  /// Pixel's Photo Sphere and Street View both do. Each frame is individually
  /// well exposed — a bright window and a dark corner each look right in their
  /// own frame — and the *differences* between frames are removed afterwards by
  /// gain compensation and multi-band blending, which is what those stages are
  /// for.
  ///
  /// Preferred over [ExposureStrategy.locked] because a lock is only as good as
  /// the moment it was taken: metered on a wall and then panned to a window, a
  /// locked capture clips every bright frame with no way back. Measured on
  /// device, the lock was not even holding — brightness match came out at 1.315
  /// against a 1.03 target, so the lock was buying inconsistency *and* clipping.
  const factory ExposureStrategy.auto() = AutoExposure;

  /// One exposure per position, at the metered lock. Faster capture, no fusion
  /// stage, but no dynamic range beyond the sensor's.
  ///
  /// Prefer [ExposureStrategy.auto] unless a scene genuinely needs every frame
  /// at one identical exposure.
  const factory ExposureStrategy.locked() = LockedExposure;

  /// Three exposures per position at `−evSpread, 0, +evSpread`, fused with
  /// Mertens (architecture §6.2).
  const factory ExposureStrategy.bracket3({double evSpread}) = Bracket3Exposure;

  /// The EV biases to request from the camera, in shooting order. The `0 EV`
  /// entry is the one the pose is interpolated to and sharpness measured on.
  List<double> get evBiases;

  /// Number of frames captured per position.
  int get shotsPerPosition => evBiases.length;

  /// Serialises with a `type` discriminator.
  Map<String, Object?> toJson();

  /// Dispatches on the `type` discriminator written by [toJson].
  factory ExposureStrategy.fromJson(Map<String, Object?> json) {
    final type = jsonString(json, 'type', context: 'ExposureStrategy');
    return switch (type) {
      AutoExposure.typeName => const AutoExposure(),
      LockedExposure.typeName => const LockedExposure(),
      Bracket3Exposure.typeName => Bracket3Exposure(
        evSpread: jsonDouble(json, 'ev_spread', context: 'Bracket3Exposure'),
      ),
      _ => throw SphereJsonFormatException(
        'ExposureStrategy.type',
        'unknown exposure strategy "$type"',
      ),
    };
  }
}

/// A single exposure per position, metered freshly at each one.
class AutoExposure extends ExposureStrategy {
  /// Creates the automatic strategy.
  const AutoExposure();

  /// The `type` discriminator used on the wire.
  static const String typeName = 'auto';

  @override
  List<double> get evBiases => const [0.0];

  @override
  Map<String, Object?> toJson() => {'type': typeName};

  @override
  bool operator ==(Object other) => other is AutoExposure;

  @override
  int get hashCode => typeName.hashCode;

  @override
  String toString() => 'ExposureStrategy.auto()';
}

/// A single exposure per position, at the hard-locked metered value.
class LockedExposure extends ExposureStrategy {
  /// Creates the locked strategy.
  const LockedExposure();

  /// The `type` discriminator used on the wire.
  static const String typeName = 'locked';

  @override
  List<double> get evBiases => const [0.0];

  @override
  Map<String, Object?> toJson() => {'type': typeName};

  @override
  bool operator ==(Object other) => other is LockedExposure;

  @override
  int get hashCode => typeName.hashCode;

  @override
  String toString() => 'ExposureStrategy.locked()';
}

/// A three-shot hardware bracket at `−evSpread, 0, +evSpread`.
class Bracket3Exposure extends ExposureStrategy {
  /// Creates a bracket with the given [evSpread] in stops.
  const Bracket3Exposure({this.evSpread = 2.0});

  /// The `type` discriminator used on the wire.
  static const String typeName = 'bracket3';

  /// Stops between the middle exposure and each end. 2.0 covers most interiors
  /// without pushing the dark frame into read noise.
  final double evSpread;

  @override
  List<double> get evBiases => [-evSpread, 0.0, evSpread];

  @override
  Map<String, Object?> toJson() => {'type': typeName, 'ev_spread': evSpread};

  @override
  bool operator ==(Object other) =>
      other is Bracket3Exposure && other.evSpread == evSpread;

  @override
  int get hashCode => Object.hash(typeName, evSpread);

  @override
  String toString() => 'ExposureStrategy.bracket3(evSpread: $evSpread)';
}

/// Output resolution class, chosen from the device's RAM rather than offered to
/// the user.
///
/// It is a *tier*, not a setting, because the binding constraint is memory, not
/// optics (architecture §6.5, §7). Multi-band blending at 8192×4096 wants
/// 550–650 MB before the OS, Flutter and the camera get their share, which on a
/// 3 GB tablet is an OOM kill. A phone camera at ~50° HFOV over 3024 px would
/// support a 21600-wide equirect, so the tiers really are sharper as they go
/// up — the ceiling is just the device, and the device is not something a user
/// should have to reason about.
enum QualityTier {
  /// Under 3 GB RAM: 4096×2048, blended in 4 strips.
  low(outputWidth: 4096, stripCount: 4),

  /// 3–6 GB RAM: 6144×3072, blended in 6 strips.
  mid(outputWidth: 6144, stripCount: 6),

  /// Over 6 GB RAM: 8192×4096, blended in 8 strips.
  high(outputWidth: 8192, stripCount: 8);

  const QualityTier({required this.outputWidth, required this.stripCount});

  /// Equirectangular canvas width in pixels.
  final int outputWidth;

  /// Number of padded horizontal strips the blender splits the canvas into.
  /// Peak memory drops by roughly this factor, with bit-identical output
  /// (architecture §7).
  final int stripCount;

  /// Canvas height. Equirectangular output is always 2:1.
  int get outputHeight => outputWidth ~/ 2;
}

/// Everything the caller can tune about a capture session.
///
/// The defaults are the product decision, not a starting point — in particular
/// the gates are deliberately much tighter than the previous implementation's
/// (aim 4° where it was 10°, steadiness 0.12 rad/s where it was 0.25). The old
/// values were loose because the old pipeline had no way to fix residual error
/// and a rejected frame was pure cost; the new one wants good bundle-adjustment
/// seeds and sharp frames, and can afford to ask for them.
class SphereCaptureConfig {
  /// Creates a configuration. Every field has a shipping-quality default, so
  /// `const SphereCaptureConfig()` is the intended normal call.
  const SphereCaptureConfig({
    this.exposure = const ExposureStrategy.auto(),
    this.overlapFraction = 0.33,
    this.captureNadir = true,
    this.autoShutter = true,
    this.aimToleranceDegrees = 4.0,
    this.steadinessThresholdRadPerSec = 0.12,
    this.dwell = const Duration(milliseconds: 350),
    this.minSharpness = 40.0,
    this.qualityTier,
  });

  /// Exposure strategy per position. Bracketing by default (architecture §6.2).
  final ExposureStrategy exposure;

  /// Target overlap `ω` between neighbouring frames, feeding the plan geometry
  /// of Math §8. Below ~0.30 feature matching stops being reliable.
  final double overlapFraction;

  /// Whether to shoot straight down. **On by default.**
  ///
  /// It was off, on the reasoning that the nadir is the user's own feet and the
  /// pole could be push–pull filled instead. Two things were wrong with that.
  /// The fill is a pyramid whose coarsest level is the average colour of the
  /// whole sphere, so what it actually produces over a cap this size is a flat
  /// grey smear, not plausible floor. And it took the bottom target out of the
  /// plan entirely, so the capture UI had no dot to draw there — leaving a user
  /// unable to tell a deliberate omission from a bug.
  ///
  /// Photographing it costs two shutter presses and gives real pixels. Feet in
  /// the frame are what every phone panorama app produces at the nadir, and they
  /// read as the floor of the room rather than as a defect.
  final bool captureNadir;

  /// Fire automatically once aim, steadiness and dwell are all satisfied. When
  /// `false` the user taps the shutter and the gates only advise.
  final bool autoShutter;

  /// How close the aim must be to the target direction before the shutter gate
  /// opens.
  final double aimToleranceDegrees;

  /// Angular-speed ceiling at the shutter, in rad/s (~7°/s). Above this the
  /// rolling shutter skews the frame faster than registration can fix.
  final double steadinessThresholdRadPerSec;

  /// How long aim and steadiness must both hold before firing. Long enough to
  /// exclude a wobble, short enough that 29 positions still fit in the 90 s
  /// capture budget (S7).
  final Duration dwell;

  /// Laplacian-variance floor below which a frame is rejected as blurred.
  /// Provisional; Phase 12 tunes it per device tier against real frames.
  final double minSharpness;

  /// Forces an output tier. `null` — the default — probes total RAM instead,
  /// which is the behaviour architecture §6.5 argues for.
  final QualityTier? qualityTier;

  /// Aim tolerance in radians, the form the guidance engine actually uses.
  double get aimToleranceRadians => aimToleranceDegrees * math.pi / 180;

  /// Returns a copy with selected fields replaced.
  SphereCaptureConfig copyWith({
    ExposureStrategy? exposure,
    double? overlapFraction,
    bool? captureNadir,
    bool? autoShutter,
    double? aimToleranceDegrees,
    double? steadinessThresholdRadPerSec,
    Duration? dwell,
    double? minSharpness,
    QualityTier? qualityTier,
  }) => SphereCaptureConfig(
    exposure: exposure ?? this.exposure,
    overlapFraction: overlapFraction ?? this.overlapFraction,
    captureNadir: captureNadir ?? this.captureNadir,
    autoShutter: autoShutter ?? this.autoShutter,
    aimToleranceDegrees: aimToleranceDegrees ?? this.aimToleranceDegrees,
    steadinessThresholdRadPerSec:
        steadinessThresholdRadPerSec ?? this.steadinessThresholdRadPerSec,
    dwell: dwell ?? this.dwell,
    minSharpness: minSharpness ?? this.minSharpness,
    qualityTier: qualityTier ?? this.qualityTier,
  );

  /// Serialises into `bundle.json`, so a replay knows the gates the frames were
  /// captured under.
  Map<String, Object?> toJson() => {
    'exposure': exposure.toJson(),
    'overlap_fraction': overlapFraction,
    'capture_nadir': captureNadir,
    'auto_shutter': autoShutter,
    'aim_tolerance_degrees': aimToleranceDegrees,
    'steadiness_threshold_rad_per_sec': steadinessThresholdRadPerSec,
    'dwell_ms': dwell.inMilliseconds,
    'min_sharpness': minSharpness,
    'quality_tier': qualityTier?.name,
  };

  /// Inverse of [toJson].
  factory SphereCaptureConfig.fromJson(Map<String, Object?> json) {
    const ctx = 'SphereCaptureConfig';
    return SphereCaptureConfig(
      exposure: ExposureStrategy.fromJson(
        jsonObject(json, 'exposure', context: ctx),
      ),
      overlapFraction: jsonDouble(json, 'overlap_fraction', context: ctx),
      captureNadir: jsonBool(json, 'capture_nadir', context: ctx),
      autoShutter: jsonBool(json, 'auto_shutter', context: ctx),
      aimToleranceDegrees: jsonDouble(
        json,
        'aim_tolerance_degrees',
        context: ctx,
      ),
      steadinessThresholdRadPerSec: jsonDouble(
        json,
        'steadiness_threshold_rad_per_sec',
        context: ctx,
      ),
      dwell: Duration(milliseconds: jsonInt(json, 'dwell_ms', context: ctx)),
      minSharpness: jsonDouble(json, 'min_sharpness', context: ctx),
      qualityTier: json['quality_tier'] == null
          ? null
          : jsonEnum(json, 'quality_tier', QualityTier.values, context: ctx),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SphereCaptureConfig &&
      other.exposure == exposure &&
      other.overlapFraction == overlapFraction &&
      other.captureNadir == captureNadir &&
      other.autoShutter == autoShutter &&
      other.aimToleranceDegrees == aimToleranceDegrees &&
      other.steadinessThresholdRadPerSec == steadinessThresholdRadPerSec &&
      other.dwell == dwell &&
      other.minSharpness == minSharpness &&
      other.qualityTier == qualityTier;

  @override
  int get hashCode => Object.hash(
    exposure,
    overlapFraction,
    captureNadir,
    autoShutter,
    aimToleranceDegrees,
    steadinessThresholdRadPerSec,
    dwell,
    minSharpness,
    qualityTier,
  );

  @override
  String toString() =>
      'SphereCaptureConfig($exposure, overlap: $overlapFraction, '
      'aim: $aimToleranceDegrees°, tier: ${qualityTier?.name ?? 'auto'})';
}
