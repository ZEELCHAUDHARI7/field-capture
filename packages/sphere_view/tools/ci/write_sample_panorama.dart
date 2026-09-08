// tools/ci/write_sample_panorama.dart — produce a panorama with real metadata,
// written by the shipping code, for `validate_metadata.sh` to hand to exiftool.
//
// The image is synthetic and small, and that is deliberate: what is being
// validated is the metadata, and a 6144-wide JPEG would make the check take
// minutes without testing one extra byte of the thing under test. The bytes
// that matter — the XMP packet and the EXIF block — are produced by
// `GPanoWriter` exactly as a real stitch produces them.

import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:sphere_view/src/metadata/gpano_writer.dart';
import 'package:sphere_view/src/metadata/panorama_metadata.dart';

Future<void> main(List<String> args) async {
  final outputPath = args.isEmpty ? 'build/metadata/sample_pano.jpg' : args[0];
  // The tier this is *describing*; the pixels below are a stand-in for it.
  const fullWidth = 6144;
  const fullHeight = 3072;

  final image = img.Image(width: 512, height: 256);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixelRgb(x, y, (x * 255) ~/ image.width, (y * 255) ~/ image.height, 96);
    }
  }

  final file = File(outputPath);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(img.encodeJpg(image, quality: 88));

  await const GPanoWriter().write(
    file,
    PanoramaMetadata(
      fullWidth: fullWidth,
      fullHeight: fullHeight,
      heading: PanoramaHeading.fromPlan(127.5),
      capturedAt: DateTime.utc(2026, 8, 11, 14, 32, 9),
      make: 'sphere_view',
      model: 'synthetic',
      stationId: 'station-07 / level-3-north',
      location: GeoLocation(
        latitudeDegrees: 51.5074,
        longitudeDegrees: -0.1278,
        altitudeMeters: 34.5,
        timestampUtc: DateTime.utc(2026, 8, 11, 13, 32, 9),
      ),
    ),
  );

  stdout.writeln('wrote $outputPath');
}
