import 'dart:convert';
import 'dart:io';

import '../../metadata/panorama_metadata.dart';
import '../../plan/capture_plan.dart';
import 'camera_intrinsics.dart';
import 'device_pose.dart';
import 'json_codec.dart';

/// One frame off the sensor, at one exposure bias.
///
/// Records the camera's own [exposureTimeNs] and [iso] rather than only the
/// requested bias because the bias is what we *asked* for and these are what we
/// *got*: when a bracket comes back with two identical frames — the failure R3
/// warns about on devices with no real bracketing support — this is the only
/// evidence of it.
class ExposureShot {
  /// Creates a shot record.
  const ExposureShot({
    required this.filePath,
    required this.evBias,
    required this.timestampUs,
    this.exposureTimeNs,
    this.iso,
  });

  /// Path to the JPEG, **relative to the owning bundle's directory**.
  ///
  /// Relative, because a bundle is meant to be copied off the device and
  /// replayed on a desktop (architecture §6.6). An absolute device path would
  /// make every bundle unreplayable the moment it moved, which would quietly
  /// destroy the regression corpus. Use [resolveIn] to get a real [File].
  final String filePath;

  /// The exposure bias in stops this frame was requested at; `0.0` is the
  /// metered reference and the frame the pose is interpolated to.
  final double evBias;

  /// Shutter instant on the same monotonic clock as `DevicePose.timestampUs`.
  final int timestampUs;

  /// Actual exposure time reported by the camera, when available.
  final int? exposureTimeNs;

  /// Actual sensitivity reported by the camera, when available.
  final int? iso;

  /// Resolves [filePath] against the bundle directory it belongs to.
  File resolveIn(Directory bundleDirectory) =>
      File('${bundleDirectory.path}${Platform.pathSeparator}$filePath');

  /// Serialises to `bundle.json`.
  Map<String, Object?> toJson() => {
    'file_path': filePath,
    'ev_bias': evBias,
    'timestamp_us': timestampUs,
    'exposure_time_ns': exposureTimeNs,
    'iso': iso,
  };

  /// Inverse of [toJson].
  factory ExposureShot.fromJson(Map<String, Object?> json) {
    const ctx = 'ExposureShot';
    return ExposureShot(
      filePath: jsonString(json, 'file_path', context: ctx),
      evBias: jsonDouble(json, 'ev_bias', context: ctx),
      timestampUs: jsonInt(json, 'timestamp_us', context: ctx),
      exposureTimeNs: jsonIntOrNull(json, 'exposure_time_ns', context: ctx),
      iso: jsonIntOrNull(json, 'iso', context: ctx),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExposureShot &&
      other.filePath == filePath &&
      other.evBias == evBias &&
      other.timestampUs == timestampUs &&
      other.exposureTimeNs == exposureTimeNs &&
      other.iso == iso;

  @override
  int get hashCode =>
      Object.hash(filePath, evBias, timestampUs, exposureTimeNs, iso);

  @override
  String toString() =>
      'ExposureShot($filePath, ${evBias >= 0 ? '+' : ''}$evBias EV)';
}

/// Everything captured at one plan target: the bracket, the pose it was shot
/// at, and the two quality numbers that decide whether it is usable.
///
/// [pose] is interpolated to the **0 EV shutter timestamp** specifically, not
/// sampled when the burst started. At a realistic 60°/s pan a 20 ms offset is
/// 1.2° of error, which is larger than the entire budget bundle adjustment is
/// working within — so the interpolation is not a refinement, it is the
/// difference between usable and useless seeds.
class CapturedPosition {
  /// Creates a captured position.
  const CapturedPosition({
    required this.targetIndex,
    required this.pose,
    required this.shots,
    required this.sharpness,
    required this.steadinessRadPerSec,
  });

  /// Index into `CapturePlan.targets` this position was shot for.
  final int targetIndex;

  /// Device orientation SLERPed to the 0 EV shutter timestamp.
  final DevicePose pose;

  /// The exposures fired here — three when bracketing, one when locked.
  final List<ExposureShot> shots;

  /// Laplacian variance of the 0 EV shot. Compared against
  /// `SphereCaptureConfig.minSharpness` to accept or re-prompt.
  final double sharpness;

  /// Angular speed at the shutter, kept so a soft frame can be attributed to
  /// motion rather than to focus.
  final double steadinessRadPerSec;

  /// The 0 EV shot — the reference frame for pose, sharpness and fusion.
  /// Falls back to the first shot if no exposure is exactly 0 EV.
  ExposureShot get baseShot => shots.firstWhere(
    (s) => s.evBias == 0.0,
    orElse: () => shots.first,
  );

  /// Serialises to `bundle.json`.
  Map<String, Object?> toJson() => {
    'target_index': targetIndex,
    'pose': pose.toJson(),
    'shots': [for (final s in shots) s.toJson()],
    'sharpness': sharpness,
    'steadiness_rad_per_sec': steadinessRadPerSec,
  };

  /// Inverse of [toJson].
  factory CapturedPosition.fromJson(Map<String, Object?> json) {
    const ctx = 'CapturedPosition';
    return CapturedPosition(
      targetIndex: jsonInt(json, 'target_index', context: ctx),
      pose: DevicePose.fromJson(jsonObject(json, 'pose', context: ctx)),
      shots: jsonList(json, 'shots', (e) {
        if (e is! Map) {
          throw const SphereJsonFormatException(
            'CapturedPosition.shots',
            'expected a list of objects',
          );
        }
        return ExposureShot.fromJson(e.cast<String, Object?>());
      }, context: ctx),
      sharpness: jsonDouble(json, 'sharpness', context: ctx),
      steadinessRadPerSec: jsonDouble(
        json,
        'steadiness_rad_per_sec',
        context: ctx,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CapturedPosition &&
      other.targetIndex == targetIndex &&
      other.pose == pose &&
      other.sharpness == sharpness &&
      other.steadinessRadPerSec == steadinessRadPerSec &&
      listEquals(other.shots, shots);

  @override
  int get hashCode => Object.hash(
    targetIndex,
    pose,
    listHash(shots),
    sharpness,
    steadinessRadPerSec,
  );

  @override
  String toString() =>
      'CapturedPosition(target: $targetIndex, ${shots.length} shots, '
      'sharpness: ${sharpness.toStringAsFixed(1)})';
}

/// A self-describing on-disk capture: the JPEGs plus a `bundle.json` holding
/// everything needed to stitch them again from scratch.
///
/// This is the single highest-leverage decision in the project (architecture
/// §6.6). Because a bundle is a directory and nothing else, three things fall
/// out for free: stitcher iteration takes seconds on a desktop instead of a
/// trip to a site; every real-world failure becomes a permanent regression
/// test; and a crash mid-session leaves something resumable rather than a
/// folder of orphaned JPEGs. All three depend on [save] and [load] being an
/// exact round-trip, which is why that is this phase's most important test.
class CaptureBundle {
  /// Creates a bundle description. Writing it to disk is [save].
  CaptureBundle({
    required this.sessionId,
    required this.directory,
    required this.plan,
    required this.intrinsics,
    required this.positions,
    required this.deviceInfo,
    this.heading = PanoramaHeading.unknown,
    this.location,
    DateTime? capturedAt,
    this.captureQuarterTurns = 0,
  }) : capturedAt = capturedAt?.toUtc();

  /// Name of the manifest inside [directory].
  static const String manifestFileName = 'bundle.json';

  /// Version of the `bundle.json` layout.
  ///
  /// Gates compatibility the same way the native ABI's `schema_version` does
  /// (architecture §6.4): a bundle recorded by an older build must either load
  /// or fail loudly, never load into a subtly different meaning.
  static const int schemaVersion = 1;

  /// Stable identifier for this capture, used as the station id in the output's
  /// EXIF and as the stitch queue's key.
  final String sessionId;

  /// Where the JPEGs and the manifest live. Not serialised — it *is* the
  /// location, so [load] takes it as an argument and a moved bundle stays
  /// valid.
  final Directory directory;

  /// The plan these positions were shot against, including its coverage proof.
  final CapturePlan plan;

  /// The intrinsics in force during capture. Usually the same object as
  /// `plan.intrinsics`, but kept separately because a mid-session zoom or
  /// format change would make them diverge, and the stitcher must use these.
  final CameraIntrinsics intrinsics;

  /// What was actually captured, in shooting order. May be shorter than
  /// `plan.targets` — a session the user quit early still produces a valid
  /// bundle and an honest coverage number (architecture §8).
  final List<CapturedPosition> positions;

  /// Compass heading of yaw 0, for GPano `PoseHeadingDegrees`, together with
  /// where it came from.
  ///
  /// Purely cosmetic as far as the pipeline is concerned: it sets the viewer's
  /// opening direction and never enters the geometry (Math §5). The *source*
  /// travels with it because Phase 11 §2 forbids writing a magnetometer
  /// heading as though it were reliable — indoors it is wrong by tens of
  /// degrees, so a panorama that opens facing the wrong way is an expected
  /// outcome and the only thing that makes it diagnosable is knowing which
  /// source produced the number.
  final PanoramaHeading heading;

  /// Where this station is, when the host app supplies a fix.
  ///
  /// Supplied rather than measured: this package holds no location permission
  /// and asking for one would be worse than useless — the app embedding it
  /// already has the fix, has already explained to the user why it wants it,
  /// and on a site usually knows the station's surveyed position better than
  /// the receiver does.
  final GeoLocation? location;

  /// Wall-clock time the session started, for EXIF `DateTimeOriginal`.
  ///
  /// Distinct from the shutter timestamps in [positions], which are monotonic
  /// microseconds on a clock that only means anything within one boot. This is
  /// the one wall-clock fact in the bundle, and without it a panorama opened
  /// six months later has no date on it at all.
  final DateTime? capturedAt;

  /// Quarter turns from the **device** frame to the **capture** frame — how far
  /// the JPEG's own axes are rolled from the screen's.
  ///
  /// The poses in [positions] are device→world; the JPEGs and [intrinsics] are
  /// in the capture stream's frame. Math §2's `C = N·D` assumes those agree,
  /// which holds only for a sensor mounted square to the display — and most
  /// tablets mount it a quarter turn off, while iOS delivers landscape photos
  /// and still reports a 0° sensor orientation. The difference is a roll about
  /// the optical axis, and because it is a *right* multiplication it is not
  /// bundle adjustment's gauge freedom: it does not cancel, it hands every seed
  /// a quarter turn of error and tilts the §7 gravity levelling.
  ///
  /// It has to be recorded here, at capture time, because it is a fact about the
  /// device that took these frames and nothing downstream can recover it from
  /// the pixels. 0 for the synthetic harness, which renders and records in one
  /// frame, and for any square-mounted camera.
  final int captureQuarterTurns;

  /// Free-form device and build facts — model, OS, RAM, thermal state, plugin
  /// versions. Untyped on purpose: this is diagnostic context whose useful
  /// contents will keep changing, and forcing it through a schema would mean
  /// old bundles stop loading every time a field is added.
  final Map<String, Object?> deviceInfo;

  /// Number of positions actually captured out of the plan's targets.
  double get completionFraction =>
      plan.length == 0 ? 0 : positions.length / plan.length;

  /// The manifest file inside [directory].
  File get manifestFile =>
      File('${directory.path}${Platform.pathSeparator}$manifestFileName');

  /// Returns a copy with selected fields replaced.
  CaptureBundle copyWith({
    String? sessionId,
    Directory? directory,
    CapturePlan? plan,
    CameraIntrinsics? intrinsics,
    List<CapturedPosition>? positions,
    PanoramaHeading? heading,
    GeoLocation? location,
    DateTime? capturedAt,
    Map<String, Object?>? deviceInfo,
    int? captureQuarterTurns,
  }) => CaptureBundle(
    sessionId: sessionId ?? this.sessionId,
    directory: directory ?? this.directory,
    plan: plan ?? this.plan,
    intrinsics: intrinsics ?? this.intrinsics,
    positions: positions ?? this.positions,
    heading: heading ?? this.heading,
    location: location ?? this.location,
    capturedAt: capturedAt ?? this.capturedAt,
    deviceInfo: deviceInfo ?? this.deviceInfo,
    captureQuarterTurns: captureQuarterTurns ?? this.captureQuarterTurns,
  );

  /// The manifest contents. Excludes [directory] by design — see that field.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'session_id': sessionId,
    'plan': plan.toJson(),
    'intrinsics': intrinsics.toJson(),
    'positions': [for (final p in positions) p.toJson()],
    'heading': heading.toJson(),
    'location': location?.toJson(),
    'captured_at': capturedAt?.toIso8601String(),
    'capture_quarter_turns': captureQuarterTurns,
    'device_info': deviceInfo,
  };

  /// Rebuilds a bundle from a manifest read out of [directory].
  factory CaptureBundle.fromJson(
    Map<String, Object?> json,
    Directory directory,
  ) {
    const ctx = 'CaptureBundle';
    final version = jsonInt(json, 'schema_version', context: ctx);
    if (version != schemaVersion) {
      throw SphereJsonFormatException(
        '$ctx.schema_version',
        'bundle was written by schema version $version, '
            'this build reads version $schemaVersion',
      );
    }
    return CaptureBundle(
      sessionId: jsonString(json, 'session_id', context: ctx),
      directory: directory,
      plan: CapturePlan.fromJson(jsonObject(json, 'plan', context: ctx)),
      intrinsics: CameraIntrinsics.fromJson(
        jsonObject(json, 'intrinsics', context: ctx),
      ),
      positions: jsonList(json, 'positions', (e) {
        if (e is! Map) {
          throw const SphereJsonFormatException(
            'CaptureBundle.positions',
            'expected a list of objects',
          );
        }
        return CapturedPosition.fromJson(e.cast<String, Object?>());
      }, context: ctx),
      heading: _headingFrom(json, ctx),
      location: json['location'] == null
          ? null
          : GeoLocation.fromJson(jsonObject(json, 'location', context: ctx)),
      capturedAt: json['captured_at'] == null
          ? null
          : DateTime.parse('${json['captured_at']}'),
      // Defaulted, not required: manifests written before the field existed load
      // as 0, which is the correct answer for every bundle in the replay corpus.
      captureQuarterTurns: json.containsKey('capture_quarter_turns')
          ? jsonInt(json, 'capture_quarter_turns', context: ctx)
          : 0,
      deviceInfo: jsonObject(json, 'device_info', context: ctx),
    );
  }

  /// Reads the heading, accepting the pre-Phase-11 form.
  ///
  /// Manifests written before the source was recorded carry a bare
  /// `heading_degrees`. Those load as a **magnetometer** heading, which is the
  /// conservative reading and the only defensible one: the field existed when
  /// the magnetometer was the only source there was, and promoting an old
  /// number to a plan heading would manufacture exactly the false confidence
  /// Phase 11 §2 exists to prevent.
  static PanoramaHeading _headingFrom(Map<String, Object?> json, String ctx) {
    if (json['heading'] != null) {
      return PanoramaHeading.fromJson(jsonObject(json, 'heading', context: ctx));
    }
    final legacy = jsonDoubleOrNull(json, 'heading_degrees', context: ctx);
    return legacy == null
        ? PanoramaHeading.unknown
        : PanoramaHeading.fromMagnetometer(legacy);
  }

  /// Writes `bundle.json` into [directory], creating the directory if needed.
  ///
  /// Written via a temporary file and a rename so that a crash — or a
  /// battery pull — during the write leaves the previous manifest intact
  /// rather than a truncated one. Resume-after-crash is one of the three things
  /// this type exists for; a half-written manifest would defeat it.
  Future<void> save() async {
    await directory.create(recursive: true);
    final temp = File('${manifestFile.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
      flush: true,
    );
    await temp.rename(manifestFile.path);
  }

  /// Reads the bundle whose manifest lives in [directory].
  ///
  /// This is the entry point `tools/replay` uses, and it is why the manifest
  /// carries the plan and intrinsics rather than assuming the caller still has
  /// them.
  static Future<CaptureBundle> load(Directory directory) async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}$manifestFileName',
    );
    if (!await file.exists()) {
      throw SphereJsonFormatException(
        'CaptureBundle.load',
        'no $manifestFileName in ${directory.path}',
      );
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const SphereJsonFormatException(
        'CaptureBundle.load',
        '$manifestFileName does not contain a JSON object',
      );
    }
    return CaptureBundle.fromJson(decoded.cast<String, Object?>(), directory);
  }

  @override
  bool operator ==(Object other) =>
      other is CaptureBundle &&
      other.sessionId == sessionId &&
      // Directory does not define value equality, so compare the path.
      other.directory.path == directory.path &&
      other.plan == plan &&
      other.intrinsics == intrinsics &&
      other.heading == heading &&
      other.location == location &&
      other.capturedAt == capturedAt &&
      other.captureQuarterTurns == captureQuarterTurns &&
      listEquals(other.positions, positions) &&
      deepEquals(other.deviceInfo, deviceInfo);

  @override
  int get hashCode => Object.hash(
    sessionId,
    directory.path,
    plan,
    intrinsics,
    listHash(positions),
    heading,
    location,
    capturedAt,
    captureQuarterTurns,
    deepHash(deviceInfo),
  );

  @override
  String toString() =>
      'CaptureBundle($sessionId, ${positions.length}/${plan.length} positions, '
      '${directory.path})';
}
