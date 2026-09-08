import 'dart:convert';
import 'dart:io';

import 'package:sphere_view/src/api/models/camera_intrinsics.dart';
import 'package:sphere_view/src/api/models/json_codec.dart';
import 'package:vector_math/vector_math_64.dart';

/// The answers, kept in a file the stitcher is never given.
///
/// This separation is the entire reason the harness can be trusted. `bundle.json`
/// holds what a real device could plausibly have recorded — a pose good to a
/// couple of degrees, a focal length a few percent off, no distortion model at
/// all on most of the fleet. `ground_truth.json` holds what was actually true.
/// If the two ever lived in one file, the first convenient
/// `bundle.trueRotation` would turn every metric into a tautology, and it would
/// happen by accident, in a hurry, on the day something else was on fire. So
/// they are different files, and `tools/replay` loads the truth *after* the
/// stitcher has finished and only to score it.
class GroundTruth {
  /// Creates a ground-truth record.
  const GroundTruth({
    required this.profile,
    required this.sceneStyle,
    required this.nearestSurfaceMetres,
    required this.sceneSeed,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.trueIntrinsics,
    required this.positions,
    required this.recordedFocalScale,
    required this.depthFileName,
    required this.evFileName,
  });

  /// Name of the manifest inside the bundle directory.
  static const String fileName = 'ground_truth.json';

  /// Name of the ground-truth equirect inside the bundle directory.
  static const String imageFileName = 'ground_truth.png';

  /// Version of this layout, gating compatibility the way `bundle.json` does.
  static const int schemaVersion = 1;

  /// Metres per unit in the 16-bit depth map. 64 m spans any room we render
  /// and leaves 1 mm of quantisation, which is far below the disparity the
  /// parallax profiles are measuring.
  static const double depthScaleMetres = 64.0;

  /// The EV map stores `[-evScaleStops, +evScaleStops]`, so a 14 EV interior
  /// fits with headroom and the encoding stays exactly invertible.
  static const double evScaleStops = 16.0;

  /// Which profile produced this bundle.
  final String profile;

  /// The [SceneStyle] name the room was built with.
  final String sceneStyle;

  /// Distance to the nearest surface, in metres — the number that sets how much
  /// parallax a given lens offset produces.
  final double nearestSurfaceMetres;

  /// Seed the room's textures were generated from.
  final int sceneSeed;

  /// Ground-truth equirect width.
  final int canvasWidth;

  /// Ground-truth equirect height.
  final int canvasHeight;

  /// The intrinsics frames were actually rendered through — **not** the ones in
  /// `bundle.json`, which are off by [recordedFocalScale].
  final CameraIntrinsics trueIntrinsics;

  /// Per captured position, in the same order as `CaptureBundle.positions`.
  final List<GroundTruthPosition> positions;

  /// What the recorded focal was multiplied by before being written into the
  /// bundle. `1.03` is the `nominal` profile's 3% error.
  final double recordedFocalScale;

  /// Depth equirect file name, or `null` when the profile needs no depth.
  final String? depthFileName;

  /// EV-offset equirect file name, or `null` when the scene is within 8 bits.
  final String? evFileName;

  /// Serialises.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'profile': profile,
    'scene_style': sceneStyle,
    'nearest_surface_metres': nearestSurfaceMetres,
    'scene_seed': sceneSeed,
    'canvas_width': canvasWidth,
    'canvas_height': canvasHeight,
    'depth_scale_metres': depthScaleMetres,
    'ev_scale_stops': evScaleStops,
    'image_file': imageFileName,
    'depth_file': depthFileName,
    'ev_file': evFileName,
    'true_intrinsics': trueIntrinsics.toJson(),
    'recorded_focal_scale': recordedFocalScale,
    'positions': [for (final p in positions) p.toJson()],
  };

  /// Inverse of [toJson].
  factory GroundTruth.fromJson(Map<String, Object?> json) {
    const ctx = 'GroundTruth';
    final version = jsonInt(json, 'schema_version', context: ctx);
    if (version != schemaVersion) {
      throw SphereJsonFormatException(
        '$ctx.schema_version',
        'ground truth was written by schema version $version, '
            'this build reads version $schemaVersion',
      );
    }
    return GroundTruth(
      profile: jsonString(json, 'profile', context: ctx),
      sceneStyle: jsonString(json, 'scene_style', context: ctx),
      nearestSurfaceMetres: jsonDouble(
        json,
        'nearest_surface_metres',
        context: ctx,
      ),
      sceneSeed: jsonInt(json, 'scene_seed', context: ctx),
      canvasWidth: jsonInt(json, 'canvas_width', context: ctx),
      canvasHeight: jsonInt(json, 'canvas_height', context: ctx),
      trueIntrinsics: CameraIntrinsics.fromJson(
        jsonObject(json, 'true_intrinsics', context: ctx),
      ),
      recordedFocalScale: jsonDouble(json, 'recorded_focal_scale', context: ctx),
      depthFileName: json['depth_file'] as String?,
      evFileName: json['ev_file'] as String?,
      positions: jsonList(json, 'positions', (e) {
        if (e is! Map) {
          throw const SphereJsonFormatException(
            'GroundTruth.positions',
            'expected a list of objects',
          );
        }
        return GroundTruthPosition.fromJson(e.cast<String, Object?>());
      }, context: ctx),
    );
  }

  /// Writes `ground_truth.json` into [directory].
  Future<void> save(Directory directory) async {
    await directory.create(recursive: true);
    await File(
      '${directory.path}${Platform.pathSeparator}$fileName',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
  }

  /// Reads the ground truth belonging to the bundle in [directory].
  static Future<GroundTruth> load(Directory directory) async {
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    if (!await file.exists()) {
      throw SphereJsonFormatException(
        'GroundTruth.load',
        'no $fileName in ${directory.path}; this bundle was not produced by '
            'tools/synth, so the ground-truth metrics cannot be computed',
      );
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const SphereJsonFormatException(
        'GroundTruth.load',
        '$fileName does not contain a JSON object',
      );
    }
    return GroundTruth.fromJson(decoded.cast<String, Object?>());
  }
}

/// What was true at one captured position.
class GroundTruthPosition {
  /// Creates a record.
  GroundTruthPosition({
    required this.targetIndex,
    required Matrix3 trueDeviceToWorld,
    required this.trueGain,
    required Vector3 lensOffsetMetres,
    required Vector3 angularVelocityRadPerSec,
  }) : trueDeviceToWorld = trueDeviceToWorld.clone(),
       lensOffsetMetres = lensOffsetMetres.clone(),
       angularVelocityRadPerSec = angularVelocityRadPerSec.clone();

  /// Index into `CapturePlan.targets`.
  final int targetIndex;

  /// The rotation the frame was actually rendered at, before the IMU error the
  /// bundle records was added.
  final Matrix3 trueDeviceToWorld;

  /// Exposure gain actually applied, simulating imperfect AE lock. S4 asks
  /// whether the compensator recovered it.
  final double trueGain;

  /// Where the entrance pupil actually sat, in world metres. Non-zero only for
  /// the parallax profiles, and the reason those cannot reach S6.
  final Vector3 lensOffsetMetres;

  /// Angular velocity at the shutter — what drove the motion blur and the
  /// rolling-shutter skew.
  final Vector3 angularVelocityRadPerSec;

  /// Serialises. The rotation goes out row-major, matching Math §2's notation.
  Map<String, Object?> toJson() => {
    'target_index': targetIndex,
    'true_device_to_world': [
      for (var row = 0; row < 3; row++)
        for (var column = 0; column < 3; column++)
          trueDeviceToWorld.entry(row, column),
    ],
    'true_gain': trueGain,
    'lens_offset_metres': [
      lensOffsetMetres.x,
      lensOffsetMetres.y,
      lensOffsetMetres.z,
    ],
    'angular_velocity_rad_per_sec': [
      angularVelocityRadPerSec.x,
      angularVelocityRadPerSec.y,
      angularVelocityRadPerSec.z,
    ],
  };

  /// Inverse of [toJson].
  factory GroundTruthPosition.fromJson(Map<String, Object?> json) {
    const ctx = 'GroundTruthPosition';
    final r = jsonDoubleList(json, 'true_device_to_world', context: ctx);
    if (r.length != 9) {
      throw const SphereJsonFormatException(
        '$ctx.true_device_to_world',
        'expected 9 elements',
      );
    }
    final offset = jsonDoubleList(json, 'lens_offset_metres', context: ctx);
    final omega = jsonDoubleList(
      json,
      'angular_velocity_rad_per_sec',
      context: ctx,
    );
    final matrix = Matrix3.zero();
    for (var row = 0; row < 3; row++) {
      for (var column = 0; column < 3; column++) {
        matrix.setEntry(row, column, r[row * 3 + column]);
      }
    }
    return GroundTruthPosition(
      targetIndex: jsonInt(json, 'target_index', context: ctx),
      trueDeviceToWorld: matrix,
      trueGain: jsonDouble(json, 'true_gain', context: ctx),
      lensOffsetMetres: Vector3(offset[0], offset[1], offset[2]),
      angularVelocityRadPerSec: Vector3(omega[0], omega[1], omega[2]),
    );
  }
}
