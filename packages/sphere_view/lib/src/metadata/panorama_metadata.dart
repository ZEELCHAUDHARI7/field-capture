import 'dart:math' as math;

import '../api/models/json_codec.dart';
import '../api/models/stitch_warning.dart';

/// Where the compass heading written into the output came from.
///
/// Recorded rather than inferred because Phase 11 §2 forbids writing a
/// magnetometer heading as though it were reliable. Indoors — which is the
/// whole use case — rebar, lift motors and steel studs bend a magnetic heading
/// by tens of degrees (architecture §1.1), so a panorama that opens facing
/// entirely the wrong way is an expected outcome, not a bug. The only thing
/// that makes it diagnosable months later is knowing which source produced it.
enum HeadingSource {
  /// Derived from the site plan: the manager drew a path, the plan's north is
  /// known, so the facing direction at a station is arithmetic.
  ///
  /// By far the most accurate source, and it costs the user nothing — no
  /// sensor, no extra step, no permission. It is first in the priority order
  /// for that reason.
  plan,

  /// The device magnetometer, sampled at session start. Rough indoors, and
  /// carried only because opening roughly right beats opening arbitrarily.
  magnetometer,

  /// No heading. `PoseHeadingDegrees` is omitted entirely and viewers open at
  /// yaw 0, which is the session-start heading — still meaningful, just not
  /// north-referenced.
  none,
}

/// A compass heading for the image centre, together with where it came from.
///
/// The two fields travel together and are never separated: a bare `double?`
/// is exactly the shape that lets a magnetometer reading be mistaken for a
/// surveyed one three layers downstream.
class PanoramaHeading {
  const PanoramaHeading._(this.degrees, this.source);

  /// A heading derived from the site plan.
  factory PanoramaHeading.fromPlan(double degrees) =>
      PanoramaHeading._(_wrap360(degrees), HeadingSource.plan);

  /// A heading read off the magnetometer.
  factory PanoramaHeading.fromMagnetometer(double degrees) =>
      PanoramaHeading._(_wrap360(degrees), HeadingSource.magnetometer);

  /// No heading is available. [degrees] is `null` and nothing is written.
  static const PanoramaHeading unknown =
      PanoramaHeading._(null, HeadingSource.none);

  /// Compass heading of the image centre — of yaw 0 — in `[0, 360)`.
  /// `null` exactly when [source] is [HeadingSource.none].
  final double? degrees;

  /// Which of Phase 11 §2's three sources supplied [degrees].
  final HeadingSource source;

  /// Whether a heading will be written.
  bool get isKnown => degrees != null;

  /// Whether this heading is accurate enough to be relied on for anything
  /// beyond an opening direction.
  ///
  /// Only [HeadingSource.plan] is. Callers should not use this to *suppress*
  /// a magnetometer heading — a rough opening direction is still better than
  /// none — but to decide whether to say so.
  bool get isTrustworthy => source == HeadingSource.plan;

  /// Applies Phase 11 §2's priority order: the plan first, the magnetometer
  /// second, omission third.
  ///
  /// The order is not a preference between two similar things. The plan
  /// heading is derived from a drawing whose north is surveyed and is good to
  /// a degree or two; the magnetometer indoors is good to tens of degrees. So
  /// a plan heading is never displaced by a sensor reading, however fresh.
  factory PanoramaHeading.resolve({
    double? planDegrees,
    double? magnetometerDegrees,
  }) {
    if (planDegrees != null) return PanoramaHeading.fromPlan(planDegrees);
    if (magnetometerDegrees != null) {
      return PanoramaHeading.fromMagnetometer(magnetometerDegrees);
    }
    return unknown;
  }

  /// The warning that belongs in `StitchReport.warnings` when the heading came
  /// from somewhere the user should not trust, or `null` when there is nothing
  /// worth saying.
  ///
  /// Coded, so the sentence lives with the rest of Phase 12 §2's copy rather
  /// than here — see [StitchWarningMessages].
  StitchWarning? get warning => switch (source) {
    HeadingSource.plan => null,
    HeadingSource.none => null,
    HeadingSource.magnetometer => StitchWarning(
      StitchWarningCode.headingFromMagnetometer,
      data: {'degrees': degrees},
      detail:
          'PoseHeadingDegrees was written from a magnetometer reading of '
          '${degrees?.toStringAsFixed(1) ?? '?'}°',
    ),
  };

  /// Serialises for `bundle.json`.
  Map<String, Object?> toJson() => {
    'degrees': degrees,
    'source': source.name,
  };

  /// Inverse of [toJson].
  factory PanoramaHeading.fromJson(Map<String, Object?> json) {
    const ctx = 'PanoramaHeading';
    final source = jsonEnum(json, 'source', HeadingSource.values, context: ctx);
    final degrees = jsonDoubleOrNull(json, 'degrees', context: ctx);
    if ((source == HeadingSource.none) != (degrees == null)) {
      throw const SphereJsonFormatException(
        ctx,
        'source and degrees disagree: a heading with a source must have a '
            'value, and one without a source must not',
      );
    }
    return PanoramaHeading._(degrees, source);
  }

  static double _wrap360(double degrees) {
    if (!degrees.isFinite) {
      throw ArgumentError.value(degrees, 'degrees', 'must be finite');
    }
    final wrapped = degrees % 360.0;
    return wrapped < 0 ? wrapped + 360.0 : wrapped;
  }

  @override
  bool operator ==(Object other) =>
      other is PanoramaHeading &&
      other.degrees == degrees &&
      other.source == source;

  @override
  int get hashCode => Object.hash(degrees, source);

  @override
  String toString() => degrees == null
      ? 'PanoramaHeading(none)'
      : 'PanoramaHeading(${degrees!.toStringAsFixed(1)}°, ${source.name})';
}

/// A GPS fix, for the output's EXIF GPS block.
///
/// Supplied by the host app rather than read here. `sphere_view` is a
/// standalone package with no location permission of its own, and asking for
/// one would be worse than useless: the app embedding it already has the fix,
/// already explained to the user why it wants it, and on a construction site
/// usually knows the station's surveyed position more precisely than the
/// receiver does.
class GeoLocation {
  /// Creates a fix. [latitudeDegrees] and [longitudeDegrees] are signed, in the
  /// usual WGS 84 sense — north and east positive.
  GeoLocation({
    required this.latitudeDegrees,
    required this.longitudeDegrees,
    this.altitudeMeters,
    this.timestampUtc,
  }) {
    if (latitudeDegrees.isNaN || latitudeDegrees.abs() > 90) {
      throw ArgumentError.value(
        latitudeDegrees,
        'latitudeDegrees',
        'must be within ±90',
      );
    }
    if (longitudeDegrees.isNaN || longitudeDegrees.abs() > 180) {
      throw ArgumentError.value(
        longitudeDegrees,
        'longitudeDegrees',
        'must be within ±180',
      );
    }
  }

  /// Signed latitude, north positive.
  final double latitudeDegrees;

  /// Signed longitude, east positive.
  final double longitudeDegrees;

  /// Height above the WGS 84 ellipsoid, in metres. Negative is below.
  final double? altitudeMeters;

  /// When the fix was taken, for `GPSDateStamp`/`GPSTimeStamp`.
  final DateTime? timestampUtc;

  /// Serialises for `bundle.json`.
  Map<String, Object?> toJson() => {
    'latitude_degrees': latitudeDegrees,
    'longitude_degrees': longitudeDegrees,
    'altitude_meters': altitudeMeters,
    'timestamp_utc': timestampUtc?.toUtc().toIso8601String(),
  };

  /// Inverse of [toJson].
  factory GeoLocation.fromJson(Map<String, Object?> json) {
    const ctx = 'GeoLocation';
    final stamp = json['timestamp_utc'];
    return GeoLocation(
      latitudeDegrees: jsonDouble(json, 'latitude_degrees', context: ctx),
      longitudeDegrees: jsonDouble(json, 'longitude_degrees', context: ctx),
      altitudeMeters: jsonDoubleOrNull(json, 'altitude_meters', context: ctx),
      timestampUtc: stamp == null ? null : DateTime.parse('$stamp').toUtc(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GeoLocation &&
      other.latitudeDegrees == latitudeDegrees &&
      other.longitudeDegrees == longitudeDegrees &&
      other.altitudeMeters == altitudeMeters &&
      other.timestampUtc == timestampUtc;

  @override
  int get hashCode => Object.hash(
    latitudeDegrees,
    longitudeDegrees,
    altitudeMeters,
    timestampUtc,
  );

  @override
  String toString() =>
      'GeoLocation(${latitudeDegrees.toStringAsFixed(6)}, '
      '${longitudeDegrees.toStringAsFixed(6)})';
}

/// Everything written into the finished panorama's XMP and EXIF.
///
/// One value type rather than a dozen parameters, because the set is written
/// in two places (the stitcher, and `tools/replay`) and read in three (the
/// viewer, the round-trip test, and `exiftool` in CI), and a field that gets
/// added to one call site and not the others is the failure this shape rules
/// out.
class PanoramaMetadata {
  /// Creates a metadata set. [fullWidth] must be exactly twice [fullHeight] —
  /// equirectangular is 2:1 by definition, and a viewer handed anything else
  /// renders a sphere that is stretched in a way that looks like a stitcher
  /// bug.
  PanoramaMetadata({
    required this.fullWidth,
    required this.fullHeight,
    this.heading = PanoramaHeading.unknown,
    DateTime? capturedAt,
    this.make,
    this.model,
    this.stationId,
    this.location,
    this.software = defaultSoftware,
  }) : capturedAt = capturedAt?.toUtc() {
    if (fullWidth <= 0 || fullHeight <= 0) {
      throw ArgumentError('the panorama must have a positive size');
    }
    if (fullWidth != fullHeight * 2) {
      throw ArgumentError.value(
        '${fullWidth}x$fullHeight',
        'size',
        'an equirectangular panorama is 2:1 (Math §3); this one is not',
      );
    }
  }

  /// What goes in EXIF `Software` when the caller does not override it.
  static const String defaultSoftware = 'sphere_view 0.1.0';

  /// `GPano:FullPanoWidthPixels`, and the output's real width.
  final int fullWidth;

  /// `GPano:FullPanoHeightPixels`, and the output's real height.
  final int fullHeight;

  /// Compass heading of the image centre, with its provenance.
  final PanoramaHeading heading;

  /// Capture start, for `DateTimeOriginal`.
  ///
  /// Always UTC, whatever the caller passed. Normalised in the constructor
  /// because `DateTime` equality compares the zone flag as well as the instant,
  /// so a metadata set built from a local time would not equal its own JSON
  /// round trip — a difference that is invisible in every `toString` and shows
  /// up only as a test that cannot be made to pass. EXIF still gets the local
  /// rendering, which is what its format means.
  final DateTime? capturedAt;

  /// EXIF `Make`.
  final String? make;

  /// EXIF `Model`.
  final String? model;

  /// EXIF `ImageDescription` — the station id or plan reference, which is what
  /// makes a loose JPEG re-attachable to the walk it came from.
  final String? stationId;

  /// GPS fix, when the host app has one.
  final GeoLocation? location;

  /// EXIF `Software`.
  final String software;

  /// `PosePitchDegrees`, always exactly zero.
  ///
  /// Not a parameter, and deliberately not one. Phase 03 §5 levels the whole
  /// panorama against measured gravity before it is ever encoded (Math §7), so
  /// a non-zero pose pitch here would not be information — it would be a
  /// levelling bug being written into the file where the viewer will silently
  /// compensate for it and nobody will ever find it.
  static const double posePitchDegrees = 0.0;

  /// `PoseRollDegrees`, always exactly zero, for the same reason as
  /// [posePitchDegrees].
  static const double poseRollDegrees = 0.0;

  /// Returns a copy with selected fields replaced.
  PanoramaMetadata copyWith({
    int? fullWidth,
    int? fullHeight,
    PanoramaHeading? heading,
    DateTime? capturedAt,
    String? make,
    String? model,
    String? stationId,
    GeoLocation? location,
    String? software,
  }) => PanoramaMetadata(
    fullWidth: fullWidth ?? this.fullWidth,
    fullHeight: fullHeight ?? this.fullHeight,
    heading: heading ?? this.heading,
    capturedAt: capturedAt ?? this.capturedAt,
    make: make ?? this.make,
    model: model ?? this.model,
    stationId: stationId ?? this.stationId,
    location: location ?? this.location,
    software: software ?? this.software,
  );

  /// Serialises, for logs and for the isolate boundary.
  Map<String, Object?> toJson() => {
    'full_width': fullWidth,
    'full_height': fullHeight,
    'heading': heading.toJson(),
    'captured_at': capturedAt?.toUtc().toIso8601String(),
    'make': make,
    'model': model,
    'station_id': stationId,
    'location': location?.toJson(),
    'software': software,
  };

  /// Inverse of [toJson].
  factory PanoramaMetadata.fromJson(Map<String, Object?> json) {
    const ctx = 'PanoramaMetadata';
    final capturedAt = json['captured_at'];
    final location = json['location'];
    return PanoramaMetadata(
      fullWidth: jsonInt(json, 'full_width', context: ctx),
      fullHeight: jsonInt(json, 'full_height', context: ctx),
      heading: json['heading'] == null
          ? PanoramaHeading.unknown
          : PanoramaHeading.fromJson(jsonObject(json, 'heading', context: ctx)),
      capturedAt:
          capturedAt == null ? null : DateTime.parse('$capturedAt').toUtc(),
      make: jsonStringOrNull(json, 'make', context: ctx),
      model: jsonStringOrNull(json, 'model', context: ctx),
      stationId: jsonStringOrNull(json, 'station_id', context: ctx),
      location: location == null
          ? null
          : GeoLocation.fromJson(jsonObject(json, 'location', context: ctx)),
      software: jsonStringOrNull(json, 'software', context: ctx) ??
          defaultSoftware,
    );
  }

  /// Builds the metadata for a finished panorama from the capture it came out
  /// of.
  ///
  /// The one place the bundle's facts become the output's metadata, so that the
  /// device path and `tools/replay` cannot disagree about what a panorama
  /// should say about itself. [deviceInfo] is read defensively — it is
  /// deliberately untyped diagnostic context (`CaptureBundle.deviceInfo`), so a
  /// bundle recorded by an older build simply has fewer fields rather than
  /// failing to produce metadata at all.
  factory PanoramaMetadata.forCapture({
    required int fullWidth,
    required int fullHeight,
    required String sessionId,
    PanoramaHeading heading = PanoramaHeading.unknown,
    DateTime? capturedAt,
    GeoLocation? location,
    Map<String, Object?> deviceInfo = const {},
    String software = defaultSoftware,
  }) {
    final identity = deviceInfo['device_identity'];
    final map = identity is Map ? identity.cast<String, Object?>() : const {};
    String? nonEmpty(Object? v) {
      final s = v is String ? v.trim() : null;
      return s == null || s.isEmpty ? null : s;
    }

    return PanoramaMetadata(
      fullWidth: fullWidth,
      fullHeight: fullHeight,
      heading: heading,
      capturedAt: capturedAt,
      make: nonEmpty(map['make']),
      model: nonEmpty(map['model']),
      // The session id *is* the station id (`CaptureBundle.sessionId` says so),
      // and it is what re-attaches a loose JPEG to the walk it came from.
      stationId: sessionId,
      location: location,
      software: software,
    );
  }

  /// The viewer's opening yaw, in radians, for a panorama whose centre faces
  /// [heading] and which should open looking at [compassHeadingDegrees].
  ///
  /// Turning right decreases yaw (Math §3) while a compass bearing increases,
  /// so the two run opposite ways and the conversion is a subtraction with a
  /// sign flip. Kept here rather than in the viewer because it is the one place
  /// the metadata's angular convention meets the geometry's, and Math §0's rule
  /// is that such a place exists exactly once.
  static double yawForCompassHeading(
    double compassHeadingDegrees,
    double centreHeadingDegrees,
  ) {
    final delta = centreHeadingDegrees - compassHeadingDegrees;
    final wrapped = ((delta + 180.0) % 360.0 + 360.0) % 360.0 - 180.0;
    return wrapped * math.pi / 180.0;
  }

  @override
  bool operator ==(Object other) =>
      other is PanoramaMetadata &&
      other.fullWidth == fullWidth &&
      other.fullHeight == fullHeight &&
      other.heading == heading &&
      other.capturedAt == capturedAt &&
      other.make == make &&
      other.model == model &&
      other.stationId == stationId &&
      other.location == location &&
      other.software == software;

  @override
  int get hashCode => Object.hash(
    fullWidth,
    fullHeight,
    heading,
    capturedAt,
    make,
    model,
    stationId,
    location,
    software,
  );

  @override
  String toString() =>
      'PanoramaMetadata(${fullWidth}x$fullHeight, $heading, '
      '${stationId ?? 'no station'})';
}
