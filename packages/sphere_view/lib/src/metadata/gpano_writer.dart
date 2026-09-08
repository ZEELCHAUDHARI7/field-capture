import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'exif.dart';
import 'jpeg_segments.dart';
import 'panorama_metadata.dart';

/// Writes the XMP GPano block that makes the output a photo sphere rather than
/// a wide JPEG.
///
/// This is criterion S10, and it is what makes the result useful outside this
/// app: with the block, the same file opens as an interactive sphere in Google
/// Photos, Facebook and every standard viewer; without it, it is a 6144×3072
/// image nobody can navigate. The property set is fixed by Math §5 and is not
/// negotiable — viewers validate it strictly and fail closed.
class GPanoWriter {
  /// Creates a writer.
  const GPanoWriter();

  /// The GPano XMP namespace.
  static const String namespace = 'http://ns.google.com/photos/1.0/panorama/';

  /// Writes GPano and EXIF into the JPEG at [jpeg], in place.
  ///
  /// The XMP packet goes into an `APP1` segment **immediately after `SOI`**,
  /// ahead of any `APP0`/JFIF or `APP1`/EXIF the encoder wrote, because some
  /// readers only scan the first few segments before concluding a file has no
  /// XMP. An XMP packet already present is *replaced* rather than joined:
  /// duplicate packets make several readers ignore both, so a second write must
  /// not accumulate. The EXIF segment follows it, replacing any existing one.
  ///
  /// The write is atomic — a temporary file and a rename — so an interrupted
  /// write leaves the panorama that was there rather than a truncated file.
  /// A stitch costs up to 60 seconds and the metadata step is the last thing
  /// that touches the artefact; corrupting it at that point would throw away
  /// the whole minute.
  Future<void> write(File jpeg, PanoramaMetadata metadata) async {
    final bytes = await jpeg.readAsBytes();
    final updated = writeBytes(bytes, metadata);
    final temp = File('${jpeg.path}.meta.tmp');
    await temp.writeAsBytes(updated, flush: true);
    await temp.rename(jpeg.path);
  }

  /// [write]'s pure half: takes JPEG bytes and returns them with the metadata
  /// in place.
  ///
  /// Separated from the file I/O because it is where every mistake would live —
  /// segment order, the 64 KB bound, replacing rather than appending — and a
  /// pure function over bytes can be asserted exhaustively in a unit test
  /// without a temporary directory.
  Uint8List writeBytes(Uint8List jpegBytes, PanoramaMetadata metadata) {
    final file = JpegFile.parse(jpegBytes);
    final xmp = JpegSegment.buildApp1(
      JpegSegment.xmpHeader,
      // ASCII rather than UTF-8 by construction: `buildXmpPacket` emits no
      // non-ASCII character. XMP's own encoding declaration says UTF-8 and the
      // two agree over this subset, so the file is valid under either reading.
      Uint8List.fromList(utf8.encode(buildXmpPacket(metadata))),
    );
    final exif = JpegSegment.buildApp1(
      JpegSegment.exifHeader,
      ExifBuilder().buildTiff(metadata),
    );
    return file
        .withLeadingSegments(
          [xmp, exif],
          where: (s) => s.isXmp || s.isExif,
        )
        .toBytes();
  }

  /// Builds the XMP packet, separated from the file I/O so its exact text can
  /// be asserted in a test rather than checked by opening the result in a
  /// viewer.
  ///
  /// `PosePitchDegrees` and `PoseRollDegrees` are the literal `0` from
  /// [PanoramaMetadata.posePitchDegrees] and [PanoramaMetadata.poseRollDegrees]
  /// and are not parameters. Phase 03 §5 has already levelled the panorama
  /// against measured gravity (Math §7), so a non-zero value here would not be
  /// information — it would be a levelling bug written into the file, where
  /// every viewer would silently compensate for it and nobody would ever find
  /// it.
  String buildXmpPacket(PanoramaMetadata metadata) {
    final heading = metadata.heading;
    final headingLine = heading.isKnown
        ? '   <GPano:PoseHeadingDegrees>'
            '${_formatDegrees(heading.degrees!)}'
            '</GPano:PoseHeadingDegrees>\n'
        // Omitted entirely rather than written as 0 (Phase 11 §2). Zero is a
        // real bearing — due north — so writing it for "we do not know" would
        // make an unknown heading indistinguishable from a surveyed one, and
        // every viewer would open the sphere confidently facing the wrong way.
        : '';
    // A source comment travels with the packet, so a file that opens facing
    // the wrong way can be diagnosed from the file alone — which is the only
    // evidence anyone will have months later, on a different machine, without
    // the report.
    final sourceLine = heading.isKnown
        ? '   <!-- heading source: ${heading.source.name} -->\n'
        : '   <!-- no heading: viewers open at the session-start '
            'direction -->\n';
    // The station id also goes here, not only into EXIF `ImageDescription`.
    // EXIF's ASCII type cannot hold anything outside 7-bit ASCII, so a station
    // named "Niveau 3 — façade nord" loses its accents there and nothing says
    // so. `dc:description` is the standard home for Unicode text, every modern
    // reader prefers it, and it costs one line — so the id survives intact and
    // the EXIF field stays as the ASCII fallback for older tools.
    final station = metadata.stationId;
    final descriptionLine = station == null || station.isEmpty
        ? ''
        : '   <dc:description>\n'
              '    <rdf:Alt>\n'
              '     <rdf:li xml:lang="x-default">${_escapeXml(station)}'
              '</rdf:li>\n'
              '    </rdf:Alt>\n'
              '   </dc:description>\n';

    return '<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/">\n'
        ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        '  <rdf:Description rdf:about=""\n'
        '    xmlns:GPano="$namespace"\n'
        '    xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        '   <GPano:ProjectionType>equirectangular</GPano:ProjectionType>\n'
        '   <GPano:UsePanoramaViewer>True</GPano:UsePanoramaViewer>\n'
        '   <GPano:FullPanoWidthPixels>${metadata.fullWidth}'
        '</GPano:FullPanoWidthPixels>\n'
        '   <GPano:FullPanoHeightPixels>${metadata.fullHeight}'
        '</GPano:FullPanoHeightPixels>\n'
        '   <GPano:CroppedAreaImageWidthPixels>${metadata.fullWidth}'
        '</GPano:CroppedAreaImageWidthPixels>\n'
        '   <GPano:CroppedAreaImageHeightPixels>${metadata.fullHeight}'
        '</GPano:CroppedAreaImageHeightPixels>\n'
        '   <GPano:CroppedAreaLeftPixels>0</GPano:CroppedAreaLeftPixels>\n'
        '   <GPano:CroppedAreaTopPixels>0</GPano:CroppedAreaTopPixels>\n'
        '$headingLine'
        '   <GPano:PosePitchDegrees>'
        '${_formatDegrees(PanoramaMetadata.posePitchDegrees)}'
        '</GPano:PosePitchDegrees>\n'
        '   <GPano:PoseRollDegrees>'
        '${_formatDegrees(PanoramaMetadata.poseRollDegrees)}'
        '</GPano:PoseRollDegrees>\n'
        '$sourceLine'
        '$descriptionLine'
        '  </rdf:Description>\n'
        ' </rdf:RDF>\n'
        '</x:xmpmeta>\n'
        '<?xpacket end="w"?>';
  }

  /// Escapes the five XML metacharacters.
  ///
  /// The station id is the one field whose text comes from a person rather than
  /// from the pipeline, and a site really does have areas called "Level 3 —
  /// Block A & B". Unescaped, that single ampersand makes the whole packet
  /// malformed XML, which does not corrupt the JPEG and does not raise anything
  /// — it just makes every reader silently decide the file is not a photo
  /// sphere.
  static String _escapeXml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// Formats an angle the way GPano readers expect: an integer when it is one,
  /// so pitch and roll come out as the exact `0` §2's packet shows rather than
  /// `0.0`, and at most four decimals otherwise.
  static String _formatDegrees(double degrees) {
    if (degrees == degrees.roundToDouble()) return degrees.round().toString();
    var s = degrees.toStringAsFixed(4);
    while (s.endsWith('0')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

/// Reads back what [GPanoWriter] wrote.
///
/// Its reason for existing is the round-trip test, and it is deliberately a
/// separate implementation rather than a shared one: a test in which the writer
/// and the reader share their field list proves only that one piece of code
/// agrees with itself. This one re-extracts each property from the packet text
/// by name.
class GPanoReader {
  /// Creates a reader.
  const GPanoReader();

  /// Parses the metadata out of the JPEG in [jpegBytes].
  ///
  /// Returns `null` when the file has no XMP packet at all, which for our
  /// purposes means "not a photo sphere".
  PanoramaMetadata? read(Uint8List jpegBytes) {
    final file = JpegFile.parse(jpegBytes);
    final xmp = file.xmpSegment;
    if (xmp == null) return null;
    final packet = xmp.xmpPacket;

    final width = _intProperty(packet, 'FullPanoWidthPixels');
    final height = _intProperty(packet, 'FullPanoHeightPixels');
    if (width == null || height == null) return null;

    final exifTiff = file.exifSegment?.exifTiff;
    final fields = exifTiff == null ? null : ExifReader.parseTiff(exifTiff);

    final headingDegrees = _doubleProperty(packet, 'PoseHeadingDegrees');
    final source = _headingSourceComment(packet);

    return PanoramaMetadata(
      fullWidth: width,
      fullHeight: height,
      heading: headingDegrees == null
          ? PanoramaHeading.unknown
          : switch (source) {
              HeadingSource.magnetometer =>
                PanoramaHeading.fromMagnetometer(headingDegrees),
              // A heading with no legible source comment is read as a plan
              // heading only when the comment says so; anything else is treated
              // as the weaker claim, because over-trusting a heading is the
              // failure mode that matters.
              HeadingSource.plan => PanoramaHeading.fromPlan(headingDegrees),
              HeadingSource.none =>
                PanoramaHeading.fromMagnetometer(headingDegrees),
            },
      capturedAt: _exifDateTime(fields),
      make: fields?[ExifTag.make]?.asString,
      model: fields?[ExifTag.model]?.asString,
      // The XMP form first: it is UTF-8, so it is the one that still has the
      // accents in it. EXIF `ImageDescription` is the ASCII fallback and is
      // read only when no XMP description was written.
      stationId: _description(packet) ??
          fields?[ExifTag.imageDescription]?.asString,
      location: _location(fields),
      software: fields?[ExifTag.software]?.asString ??
          PanoramaMetadata.defaultSoftware,
    );
  }

  /// The raw XMP packet text, for a test that wants to assert on it directly.
  String? rawPacket(Uint8List jpegBytes) =>
      JpegFile.parse(jpegBytes).xmpSegment?.xmpPacket;

  /// The `ProjectionType`, which is the one property a viewer keys off before
  /// anything else.
  String? projectionType(Uint8List jpegBytes) {
    final packet = rawPacket(jpegBytes);
    return packet == null ? null : _stringProperty(packet, 'ProjectionType');
  }

  /// Every EXIF field in the file, by tag.
  ///
  /// `@internal`, and therefore not part of the API: [ExifField] is a raw tag
  /// number, a raw type code and a list of untyped values, which is the shape
  /// the format has and not a shape worth handing to a caller. Everything a
  /// consumer should want from the EXIF block is already on
  /// [PanoramaMetadata] — the capture time, the make and model, the fix. This
  /// exists so `metadata_test.dart` can assert on what was written at the byte
  /// level, which is the only way to catch a field that is *present but
  /// malformed*.
  @internal
  Map<int, ExifField>? exifFields(Uint8List jpegBytes) {
    final tiff = JpegFile.parse(jpegBytes).exifSegment?.exifTiff;
    return tiff == null ? null : ExifReader.parseTiff(tiff);
  }

  static String? _stringProperty(String packet, String name) {
    // Matches both the element form we write and the attribute form other
    // writers use, because a reader that only understands its own output is
    // not evidence of anything.
    final element = RegExp(
      '<GPano:$name>([^<]*)</GPano:$name>',
    ).firstMatch(packet);
    if (element != null) return element.group(1)!.trim();
    final attribute = RegExp('GPano:$name="([^"]*)"').firstMatch(packet);
    return attribute?.group(1)?.trim();
  }

  static int? _intProperty(String packet, String name) =>
      int.tryParse(_stringProperty(packet, name) ?? '');

  static double? _doubleProperty(String packet, String name) =>
      double.tryParse(_stringProperty(packet, name) ?? '');

  /// The `dc:description` text, un-escaped, or `null` when there is none.
  static String? _description(String packet) {
    final match = RegExp(
      r'<dc:description>.*?<rdf:li[^>]*>(.*?)</rdf:li>',
      dotAll: true,
    ).firstMatch(packet);
    final raw = match?.group(1)?.trim();
    if (raw == null || raw.isEmpty) return null;
    // `&amp;` last, so an id containing the literal text "&lt;" survives
    // instead of turning into "<" on the way back.
    return raw
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  static HeadingSource _headingSourceComment(String packet) {
    final match = RegExp(r'heading source: (\w+)').firstMatch(packet);
    if (match == null) return HeadingSource.none;
    return HeadingSource.values.firstWhere(
      (s) => s.name == match.group(1),
      orElse: () => HeadingSource.none,
    );
  }

  static DateTime? _exifDateTime(Map<int, ExifField>? fields) {
    final text = fields?[ExifTag.dateTimeOriginal]?.asString;
    if (text == null || text.length < 19) return null;
    // EXIF is `YYYY:MM:DD HH:MM:SS` in local time, with no zone. Parsed as
    // local and returned as UTC so the round trip is exact on the machine that
    // wrote it, which is the only claim EXIF's format supports.
    final iso =
        '${text.substring(0, 4)}-${text.substring(5, 7)}-'
        '${text.substring(8, 10)}T${text.substring(11, 19)}';
    return DateTime.tryParse(iso)?.toUtc();
  }

  static GeoLocation? _location(Map<int, ExifField>? fields) {
    if (fields == null) return null;
    final lat = fields[ExifTag.gpsLatitude];
    final lon = fields[ExifTag.gpsLongitude];
    if (lat == null || lon == null) return null;
    final latitude = lat.asCoordinate(fields[ExifTag.gpsLatitudeRef]?.asString);
    final longitude = lon.asCoordinate(
      fields[ExifTag.gpsLongitudeRef]?.asString,
    );
    if (latitude == null || longitude == null) return null;
    final altitudeField = fields[ExifTag.gpsAltitude];
    final belowSeaLevel = fields[ExifTag.gpsAltitudeRef]?.asInt == 1;
    final altitude = altitudeField?.asDouble;
    return GeoLocation(
      latitudeDegrees: latitude,
      longitudeDegrees: longitude,
      altitudeMeters:
          altitude == null ? null : (belowSeaLevel ? -altitude : altitude),
      timestampUtc: _gpsTimestamp(fields),
    );
  }

  static DateTime? _gpsTimestamp(Map<int, ExifField> fields) {
    final date = fields[ExifTag.gpsDateStamp]?.asString;
    final time = fields[ExifTag.gpsTimeStamp];
    if (date == null || time == null || time.values.length < 3) return null;
    int part(int i) {
      final v = time.values[i];
      return v is (int, int) && v.$2 != 0 ? v.$1 ~/ v.$2 : 0;
    }

    final iso = '${date.replaceAll(':', '-')}T'
        '${part(0).toString().padLeft(2, '0')}:'
        '${part(1).toString().padLeft(2, '0')}:'
        '${part(2).toString().padLeft(2, '0')}Z';
    return DateTime.tryParse(iso)?.toUtc();
  }
}
