import 'json_codec.dart';

/// The stages of the native pipeline, in execution order.
///
/// **The ordinal of each value is part of the native ABI.** C++ writes the
/// current stage as an `int32` into the shared-memory progress triple and Dart
/// reads it back with `StitchStage.values[stage]` (architecture §6.3), so
/// reordering or inserting a value silently remaps every progress report.
/// Append only, and change `sphere_stitch.h` in the same commit.
///
/// The enum exists at all — rather than a percentage — because a 60-second
/// stitch that says only "47%" is indistinguishable from a hung one, and
/// because when a stitch fails the stage it failed in is most of the diagnosis.
enum StitchStage {
  /// Mertens exposure fusion of each position's bracket (pipeline stage 5).
  fusing,

  /// Applying the measured lens distortion model (stage 6).
  undistorting,

  /// SIFT at ~0.6 MP registration scale (stage 7).
  findingFeatures,

  /// Matching only the pairs whose IMU poses overlap (stage 8).
  matching,

  /// Bundle adjustment, seeded with the IMU rotations (stage 9).
  adjusting,

  /// Spherical warp onto the equirectangular canvas (stage 10).
  warping,

  /// Blocks gain compensation (stage 11).
  compensating,

  /// Graph-cut seam finding (stage 12).
  seaming,

  /// Multi-band blending, in padded horizontal strips (stage 13).
  blending,

  /// Push–pull fill of any uncovered nadir or zenith (stage 14).
  fillingPoles,

  /// JPEG encode plus XMP GPano and EXIF (stage 15).
  encoding,
}

/// A single progress tick from the stitch.
///
/// Deliberately a value type with no callback identity: it is produced on the
/// worker isolate by polling shared memory at 10 Hz and handed to the UI, and
/// making it plain data is what lets the progress path avoid `NativeCallable`
/// and its isolate-lifetime hazards altogether (architecture §6.3).
class StitchProgress {
  /// Creates a progress tick.
  const StitchProgress({
    required this.stage,
    required this.fraction,
    this.message,
  });

  /// Which pipeline stage is running.
  final StitchStage stage;

  /// Overall completion in `0.0..1.0` — not per-stage, so a progress bar never
  /// goes backwards.
  final double fraction;

  /// Optional plain-language detail for the UI, e.g. which position is fusing.
  final String? message;

  /// Serialises for logs and for the isolate boundary.
  Map<String, Object?> toJson() => {
    'stage': stage.name,
    'fraction': fraction,
    'message': message,
  };

  /// Inverse of [toJson].
  factory StitchProgress.fromJson(Map<String, Object?> json) {
    const ctx = 'StitchProgress';
    return StitchProgress(
      stage: jsonEnum(json, 'stage', StitchStage.values, context: ctx),
      fraction: jsonDouble(json, 'fraction', context: ctx),
      message: json['message'] == null
          ? null
          : jsonString(json, 'message', context: ctx),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StitchProgress &&
      other.stage == stage &&
      other.fraction == fraction &&
      other.message == message;

  @override
  int get hashCode => Object.hash(stage, fraction, message);

  @override
  String toString() =>
      'StitchProgress(${stage.name}, ${(fraction * 100).toStringAsFixed(0)}%'
      '${message == null ? '' : ', $message'})';
}
