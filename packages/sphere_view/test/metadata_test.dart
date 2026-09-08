import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:image/image.dart' as img;
import 'package:sphere_view/src/metadata/exif.dart';
import 'package:sphere_view/src/metadata/jpeg_segments.dart';

/// Phase 11 §2 — the metadata is criterion S10, and S10 is most of what makes
/// the output useful.
///
/// Without the XMP GPano block the file is "a wide JPEG": a construction record
/// attached to a plan and opened by somebody who does not have this app is a
/// 6144×3072 image they cannot navigate. With it, the same bytes open as an
/// interactive sphere in Google Photos, Facebook, Street View, Marzipano and
/// Pannellum. So these tests are not about tidiness; they are about whether the
/// artefact this package exists to produce works at all.
///
/// The round trip goes through [GPanoReader] and [ExifReader], which are written
/// against the byte layout rather than against [GPanoWriter]'s field list. A
/// test in which the writer and the reader share a table proves only that one
/// piece of code agrees with itself.
void main() {
  /// A small real JPEG. The `image` package's encoder writes `SOI`, `APP0`/JFIF,
  /// the tables and the scan — the same segment shapes OpenCV's encoder
  /// produces, and notably *no* XMP, which is the state §2 says to be defensive
  /// about rather than to assume.
  Uint8List baseJpeg({int width = 64, int height = 32}) {
    final image = img.Image(width: width, height: height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        image.setPixelRgb(x, y, x * 4 % 256, y * 8 % 256, 128);
      }
    }
    return Uint8List.fromList(img.encodeJpg(image, quality: 90));
  }

  PanoramaMetadata fullMetadata() => PanoramaMetadata(
    fullWidth: 6144,
    fullHeight: 3072,
    heading: PanoramaHeading.fromPlan(127.5),
    capturedAt: DateTime(2026, 8, 11, 14, 32, 9),
    make: 'Samsung',
    model: 'SM-X910',
    stationId: 'station-07 / level-3-north',
    location: GeoLocation(
      latitudeDegrees: 51.5074,
      longitudeDegrees: -0.1278,
      altitudeMeters: 34.5,
      timestampUtc: DateTime.utc(2026, 8, 11, 13, 32, 9),
    ),
  );

  group('the XMP packet', () {
    test('carries every GPano property Math §5 fixes', () {
      final packet = const GPanoWriter().buildXmpPacket(fullMetadata());

      expect(packet, contains(GPanoWriter.namespace));
      expect(
        packet,
        contains('<GPano:ProjectionType>equirectangular</GPano:ProjectionType>'),
      );
      expect(
        packet,
        contains('<GPano:UsePanoramaViewer>True</GPano:UsePanoramaViewer>'),
      );
      expect(packet, contains('<GPano:FullPanoWidthPixels>6144<'));
      expect(packet, contains('<GPano:FullPanoHeightPixels>3072<'));
      expect(packet, contains('<GPano:CroppedAreaImageWidthPixels>6144<'));
      expect(packet, contains('<GPano:CroppedAreaImageHeightPixels>3072<'));
      expect(packet, contains('<GPano:CroppedAreaLeftPixels>0<'));
      expect(packet, contains('<GPano:CroppedAreaTopPixels>0<'));
      expect(packet, contains('<GPano:PoseHeadingDegrees>127.5<'));
    });

    test(
      'writes pitch and roll as exactly 0, because §7 already levelled it',
      () {
        // Not a formatting preference. If either of these is ever non-zero it is
        // a bug in the Kabsch levelling (Math §7), and the only honest thing to
        // write here is the zero that says "already level" — a viewer handed a
        // non-zero pose would silently compensate for the tilt and nobody would
        // ever find the levelling bug.
        final packet = const GPanoWriter().buildXmpPacket(fullMetadata());
        expect(
          packet,
          contains('<GPano:PosePitchDegrees>0</GPano:PosePitchDegrees>'),
        );
        expect(
          packet,
          contains('<GPano:PoseRollDegrees>0</GPano:PoseRollDegrees>'),
        );
      },
    );

    test('omits PoseHeadingDegrees entirely when no heading is known', () {
      // Rather than writing 0, which is a real bearing — due north. A viewer
      // cannot tell "we do not know" from "it faces north" if we write the
      // same bytes for both, so it opens confidently in the wrong direction.
      final packet = const GPanoWriter().buildXmpPacket(
        PanoramaMetadata(fullWidth: 4096, fullHeight: 2048),
      );
      expect(packet, isNot(contains('PoseHeadingDegrees')));
      expect(packet, contains('no heading'));
    });

    test('records the heading source, so a wrong opening is diagnosable', () {
      // §2: never write a magnetometer heading as though it were reliable. The
      // file itself has to say where the number came from, because months later
      // on somebody else's machine the file is the only evidence there is.
      const writer = GPanoWriter();
      expect(
        writer.buildXmpPacket(
          PanoramaMetadata(
            fullWidth: 4096,
            fullHeight: 2048,
            heading: PanoramaHeading.fromMagnetometer(91.25),
          ),
        ),
        contains('heading source: magnetometer'),
      );
      expect(
        writer.buildXmpPacket(
          PanoramaMetadata(
            fullWidth: 4096,
            fullHeight: 2048,
            heading: PanoramaHeading.fromPlan(91.25),
          ),
        ),
        contains('heading source: plan'),
      );
    });

    test('stays far under the 64 KB APP1 limit', () {
      // §2 says to assert this rather than assume it. Ours is ~1 KB; the point
      // of the check is that a caller who starts writing long descriptions
      // finds out here rather than by producing a file whose segment length
      // field has wrapped.
      final packet = const GPanoWriter().buildXmpPacket(fullMetadata());
      expect(packet.length, lessThan(4096));
      expect(
        packet.length + JpegSegment.xmpHeader.length,
        lessThan(JpegSegment.maxPayloadBytes),
      );
    });
  });

  group('segment insertion', () {
    test('puts XMP immediately after SOI, ahead of APP0/JFIF', () {
      // Some readers only scan the first few segments before deciding a file
      // has no XMP, so position is a correctness property, not a tidiness one.
      final original = JpegFile.parse(baseJpeg());
      expect(
        original.segments.first.marker,
        JpegSegment.app0,
        reason: 'the fixture should start with a JFIF header to displace',
      );

      final written = const GPanoWriter().writeBytes(baseJpeg(), fullMetadata());
      final parsed = JpegFile.parse(written);
      expect(parsed.segments[0].isXmp, isTrue);
      expect(parsed.segments[1].isExif, isTrue);
      expect(
        parsed.segments[2].marker,
        JpegSegment.app0,
        reason: 'the original JFIF header must survive, just later',
      );
    });

    test('the result is still a valid, decodable JPEG', () {
      final written = const GPanoWriter().writeBytes(baseJpeg(), fullMetadata());
      final decoded = img.decodeJpg(written);
      expect(decoded, isNotNull);
      expect(decoded!.width, 64);
      expect(decoded.height, 32);
    });

    test('the scan data is untouched, byte for byte', () {
      // The scan is copied verbatim rather than re-encoded. Anything else risks
      // corrupting stuffed FF 00 bytes and restart markers, and the whole
      // reason this writer does segment surgery instead of a decode/encode
      // round trip is to avoid re-compressing a 6144-wide panorama.
      final source = baseJpeg();
      final before = JpegFile.parse(source).scan;
      final after =
          JpegFile.parse(const GPanoWriter().writeBytes(source, fullMetadata()))
              .scan;
      expect(after, equals(before));
    });

    test('a second write replaces the XMP rather than duplicating it', () {
      // Duplicate XMP packets make several readers ignore both, which is worse
      // than either one alone — so this is the difference between a file that
      // works after a re-write and one that silently stops being a photo
      // sphere.
      const writer = GPanoWriter();
      final once = writer.writeBytes(baseJpeg(), fullMetadata());
      final twice = writer.writeBytes(
        once,
        fullMetadata().copyWith(heading: PanoramaHeading.fromPlan(200.0)),
      );

      final parsed = JpegFile.parse(twice);
      expect(parsed.segments.where((s) => s.isXmp).length, 1);
      expect(parsed.segments.where((s) => s.isExif).length, 1);
      expect(
        const GPanoReader().read(twice)!.heading.degrees,
        closeTo(200.0, 1e-9),
      );
    });

    test('an APP1 that is neither XMP nor EXIF is left alone', () {
      // The identifier match has to be exact. A reader that matches loosely
      // would also match the extended-XMP segment, or somebody else's APP1, and
      // would silently delete data it did not write.
      final source = JpegFile.parse(baseJpeg());
      final foreign = JpegSegment.buildApp1(
        Uint8List.fromList('http://ns.adobe.com/xap/1.0/Extension '.codeUnits),
        Uint8List.fromList('not ours'.codeUnits),
      );
      final withForeign = source
          .withLeadingSegments([foreign], where: (_) => false)
          .toBytes();

      final written = const GPanoWriter().writeBytes(withForeign, fullMetadata());
      final parsed = JpegFile.parse(written);
      expect(
        parsed.segments.where(
          (s) => s.marker == JpegSegment.app1 && !s.isXmp && !s.isExif,
        ),
        hasLength(1),
      );
    });

    test('refuses a packet that will not fit in one segment', () {
      expect(
        () => JpegSegment.buildApp1(
          JpegSegment.xmpHeader,
          Uint8List(JpegSegment.maxPayloadBytes),
        ),
        throwsArgumentError,
      );
    });
  });

  group('round trip through an independent parser', () {
    test('every field survives', () {
      final metadata = fullMetadata();
      final written = const GPanoWriter().writeBytes(baseJpeg(), metadata);
      final read = const GPanoReader().read(written)!;

      expect(read.fullWidth, metadata.fullWidth);
      expect(read.fullHeight, metadata.fullHeight);
      expect(read.heading.degrees, closeTo(metadata.heading.degrees!, 0.01));
      expect(read.heading.source, metadata.heading.source);
      expect(read.make, metadata.make);
      expect(read.model, metadata.model);
      expect(read.stationId, metadata.stationId);
      expect(read.software, metadata.software);
      expect(
        read.capturedAt,
        metadata.capturedAt!.toUtc(),
        reason: 'DateTimeOriginal is written local and read back local',
      );
      expect(
        read.location!.latitudeDegrees,
        closeTo(metadata.location!.latitudeDegrees, 1e-6),
      );
      expect(
        read.location!.longitudeDegrees,
        closeTo(metadata.location!.longitudeDegrees, 1e-6),
      );
      expect(read.location!.altitudeMeters, closeTo(34.5, 1e-3));
      expect(read.location!.timestampUtc, metadata.location!.timestampUtc);
    });

    test('a southern, western, below-sea-level fix keeps its signs', () {
      // The EXIF coordinate encoding is unsigned magnitude plus a reference
      // character, so the sign lives in a separate field from the number. That
      // is exactly the shape that produces a panorama pinned to the wrong
      // hemisphere while every individual value looks right.
      final metadata = fullMetadata().copyWith(
        location: GeoLocation(
          latitudeDegrees: -33.8688,
          longitudeDegrees: -151.2093,
          altitudeMeters: -12.25,
        ),
      );
      final read = const GPanoReader()
          .read(const GPanoWriter().writeBytes(baseJpeg(), metadata))!;
      expect(read.location!.latitudeDegrees, closeTo(-33.8688, 1e-6));
      expect(read.location!.longitudeDegrees, closeTo(-151.2093, 1e-6));
      expect(read.location!.altitudeMeters, closeTo(-12.25, 1e-3));
    });

    test('reports equirectangular as the projection type', () {
      // This is the single property a viewer keys off before anything else, and
      // it is what `exiftool -ProjectionType` checks in CI.
      final written = const GPanoWriter().writeBytes(baseJpeg(), fullMetadata());
      expect(const GPanoReader().projectionType(written), 'equirectangular');
    });

    test('GPSImgDirection matches PoseHeadingDegrees and is true north', () {
      // Two representations of one fact in one file. If they can disagree they
      // eventually will, and a viewer that reads one while a map tool reads the
      // other would place the same panorama two ways.
      final written = const GPanoWriter().writeBytes(baseJpeg(), fullMetadata());
      final fields = const GPanoReader().exifFields(written)!;
      expect(
        fields[ExifTag.gpsImgDirection]!.asDouble,
        closeTo(fullMetadata().heading.degrees!, 0.01),
      );
      expect(fields[ExifTag.gpsImgDirectionRef]!.asString, 'T');
    });

    test('a file with no heading and no fix writes no GPS block', () {
      final written = const GPanoWriter().writeBytes(
        baseJpeg(),
        PanoramaMetadata(fullWidth: 4096, fullHeight: 2048, model: 'iPad'),
      );
      final fields = const GPanoReader().exifFields(written)!;
      expect(fields[ExifTag.gpsIfdPointer], isNull);
      expect(fields[ExifTag.model]!.asString, 'iPad');
    });

    test('orientation is 1, so no reader rotates out of the §3 mapping', () {
      final written = const GPanoWriter().writeBytes(baseJpeg(), fullMetadata());
      final fields = const GPanoReader().exifFields(written)!;
      expect(fields[ExifTag.orientation]!.asInt, 1);
    });

    test('a station id keeps its accents', () {
      // EXIF's ASCII type cannot hold them and drops them without saying so.
      // The XMP `dc:description` is UTF-8 and is where the id actually
      // survives — which matters because station names are written by people,
      // on sites that are not all English-speaking.
      final metadata = fullMetadata().copyWith(
        stationId: 'Niveau 3 — façade nord',
      );
      final written = const GPanoWriter().writeBytes(baseJpeg(), metadata);

      expect(const GPanoReader().read(written)!.stationId, 'Niveau 3 — façade nord');
      expect(
        const GPanoReader().exifFields(written)![ExifTag.imageDescription]!
            .asString,
        'Niveau 3  faade nord',
        reason: 'the EXIF fallback is ASCII-only by specification; it is kept '
            'for older tools and is not where the id is read from',
      );
    });

    test('a station id containing XML metacharacters is escaped', () {
      // "Level 3 — Block A & B" is an entirely ordinary name for an area of a
      // site. Unescaped, that ampersand makes the packet malformed XML — which
      // does not corrupt the JPEG and raises nothing, it just makes every
      // reader quietly decide the file is not a photo sphere.
      final metadata = fullMetadata().copyWith(
        stationId: 'Level 3 <Block A & B> "north"',
      );
      final written = const GPanoWriter().writeBytes(baseJpeg(), metadata);
      final packet = const GPanoReader().rawPacket(written)!;

      expect(packet, contains('&amp;'));
      expect(packet, isNot(contains('A & B')));
      expect(
        const GPanoReader().read(written)!.stationId,
        'Level 3 <Block A & B> "north"',
      );
    });

    test('the stored dimensions are the panorama, not the file', () {
      // Deliberate: PixelXDimension describes the panorama the metadata is
      // about. The fixture is 64x32 because a test does not need 18 megapixels.
      final written = const GPanoWriter().writeBytes(baseJpeg(), fullMetadata());
      final fields = const GPanoReader().exifFields(written)!;
      expect(fields[ExifTag.pixelXDimension]!.asInt, 6144);
      expect(fields[ExifTag.pixelYDimension]!.asInt, 3072);
    });
  });

  group('EXIF byte layout', () {
    test('an odd-length value keeps every later field readable', () {
      // A TIFF value longer than four bytes lives in the data area, and the
      // next one must start on a word boundary. An odd-length string that is
      // not padded shifts every subsequent offset by one — which produces a
      // file that parses correctly right up until the field after the odd one,
      // and is therefore the kind of bug that reaches production behind a
      // passing test that happened to use an even-length fixture.
      for (final id in ['abc', 'a' * 5, 'a' * 6, 'a' * 7, 'a' * 8]) {
        final tiff = ExifBuilder().buildTiff(
          PanoramaMetadata(
            fullWidth: 4096,
            fullHeight: 2048,
            stationId: id,
            make: 'M' * 9,
            model: 'X' * 11,
            capturedAt: DateTime.utc(2026, 8, 11),
            heading: PanoramaHeading.fromPlan(12.5),
            location: GeoLocation(
              latitudeDegrees: 1.5,
              longitudeDegrees: -2.5,
              altitudeMeters: 3.5,
            ),
          ),
        );
        final fields = ExifReader.parseTiff(tiff)!;
        expect(fields[ExifTag.imageDescription]!.asString, id, reason: id);
        expect(fields[ExifTag.make]!.asString, 'M' * 9, reason: id);
        expect(fields[ExifTag.model]!.asString, 'X' * 11, reason: id);
        expect(
          fields[ExifTag.gpsImgDirection]!.asDouble,
          closeTo(12.5, 0.01),
          reason: id,
        );
        expect(
          fields[ExifTag.gpsLatitude]!.asCoordinate('N'),
          closeTo(1.5, 1e-6),
          reason: id,
        );
      }
    });

    test('a truncated block is skipped rather than thrown on', () {
      // This is the one place the package parses bytes it did not write. A
      // reader that gives up on a whole block — or worse, reads past its end —
      // because of one bad field is how a single vendor's odd tag hides every
      // other tag in the file.
      final tiff = ExifBuilder().buildTiff(
        PanoramaMetadata(fullWidth: 4096, fullHeight: 2048, model: 'ok'),
      );
      for (var cut = 8; cut < tiff.length; cut += 3) {
        expect(
          () => ExifReader.parseTiff(Uint8List.sublistView(tiff, 0, cut)),
          returnsNormally,
          reason: 'truncated at $cut bytes',
        );
      }
    });
  });

  group('the metadata model', () {
    test('refuses a panorama that is not 2:1', () {
      expect(
        () => PanoramaMetadata(fullWidth: 4096, fullHeight: 4096),
        throwsArgumentError,
      );
    });

    test('applies §2 priority: the plan beats the magnetometer', () {
      final resolved = PanoramaHeading.resolve(
        planDegrees: 42.0,
        magnetometerDegrees: 310.0,
      );
      expect(resolved.source, HeadingSource.plan);
      expect(resolved.degrees, 42.0);
      expect(resolved.isTrustworthy, isTrue);
      expect(resolved.warning, isNull);
    });

    test('falls back to the magnetometer, and says so', () {
      final resolved = PanoramaHeading.resolve(magnetometerDegrees: 310.0);
      expect(resolved.source, HeadingSource.magnetometer);
      expect(resolved.isTrustworthy, isFalse);
      expect(resolved.warning?.code, StitchWarningCode.headingFromMagnetometer);
      expect(resolved.warning?.message, contains('compass'));
    });

    test('omits when there is nothing', () {
      final resolved = PanoramaHeading.resolve();
      expect(resolved.source, HeadingSource.none);
      expect(resolved.degrees, isNull);
      expect(resolved.warning, isNull);
    });

    test('wraps a heading into [0, 360)', () {
      expect(PanoramaHeading.fromPlan(-90).degrees, 270.0);
      expect(PanoramaHeading.fromPlan(450).degrees, 90.0);
      expect(PanoramaHeading.fromPlan(360).degrees, 0.0);
    });

    test('round-trips through JSON', () {
      final metadata = fullMetadata();
      expect(PanoramaMetadata.fromJson(metadata.toJson()), metadata);
    });

    test('refuses JSON where the heading and its source disagree', () {
      expect(
        () => PanoramaHeading.fromJson({'degrees': 12.0, 'source': 'none'}),
        throwsA(isA<Exception>()),
      );
      expect(
        () => PanoramaHeading.fromJson({'degrees': null, 'source': 'plan'}),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('writing to a file', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('sphere_meta'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('write() replaces the file in place and leaves it decodable', () async {
      final file = File('${temp.path}/panorama.jpg')
        ..writeAsBytesSync(baseJpeg());
      await const GPanoWriter().write(file, fullMetadata());

      final read = const GPanoReader().read(file.readAsBytesSync())!;
      expect(read.stationId, 'station-07 / level-3-north');
      expect(img.decodeJpg(file.readAsBytesSync()), isNotNull);
      expect(
        File('${file.path}.meta.tmp').existsSync(),
        isFalse,
        reason: 'the temporary file must be renamed away, not left behind',
      );
    });
  });

  group('JPEG parsing', () {
    test('rejects something that is not a JPEG', () {
      expect(
        () => JpegFile.parse(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(isA<JpegFormatException>()),
      );
    });

    test('rejects a truncated segment rather than reading past the end', () {
      final source = baseJpeg();
      expect(
        () => JpegFile.parse(Uint8List.sublistView(source, 0, 8)),
        throwsA(isA<JpegFormatException>()),
      );
    });

    test('parse → toBytes is the identity on a file it did not touch', () {
      final source = baseJpeg();
      expect(JpegFile.parse(source).toBytes(), equals(source));
    });
  });
}
