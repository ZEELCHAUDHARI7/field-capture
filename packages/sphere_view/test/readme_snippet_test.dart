import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sphere_view/sphere_view.dart';

/// Compiles the README's usage snippets.
///
/// Exit criterion for Phase 01 is that the snippet compiles "as a test, not by
/// eye" — because a README example is the first thing a consumer copies and the
/// last thing anyone re-checks after an API change. Reading it and nodding is
/// not a check; making the analyser and the compiler read it is.
///
/// The functions below are never *called*: their bodies would throw
/// `UnimplementedError` at this phase, and running them proves nothing about
/// what this test is for. Type-checking them is the whole assertion. When the
/// implementations land, these become live smoke tests for free.
void main() {
  test('the README capture-and-stitch snippet type-checks', () {
    expect(captureAndStitch, isA<Function>());
  });

  test('the README background-queue snippet type-checks', () {
    expect(stitchInTheBackground, isA<Function>());
  });

  test('the README viewer snippets type-check', () {
    expect(viewExistingPanorama, isA<Function>());
    expect(viewFromProvider, isA<Function>());
    expect(driveViewerProgrammatically, isA<Function>());
    expect(openFacingNorth, isA<Function>());
    expect(gyroLook, isA<Function>());
  });

  test('the README metadata snippet type-checks', () {
    expect(recordWhichWayItFaces, isA<Function>());
  });

  test('README claims about the viewer clamps hold', () {
    // The README states the pinch bounds as fact. If they move, the sentence
    // is wrong and a reader will trust it over the code.
    expect(SphereViewerController.minimumFovDegrees, 30);
    expect(SphereViewerController.maximumFovDegrees, 100);

    final controller = SphereViewerController();
    addTearDown(controller.dispose);
    for (var i = 0; i < 40; i++) {
      controller.zoom(1.5);
    }
    expect(controller.fovDegrees, closeTo(30, 1e-9));
  });

  test('the README configuration snippet type-checks', () {
    // This one is const, so it is genuinely evaluated — the defaults it
    // spells out must actually be the defaults.
    expect(readmeConfig.overlapFraction, 0.33);
    expect(readmeConfig.aimToleranceDegrees, 4.0);
    expect(readmeConfig.steadinessThresholdRadPerSec, 0.12);
    expect(readmeConfig.dwell, const Duration(milliseconds: 350));
    expect(readmeConfig.captureNadir, isTrue);
    expect(readmeConfig, const SphereCaptureConfig());
  });

  test('README claims about the public API surface hold', () {
    // The README says output size is not a user setting. If a field for it
    // ever appears, this and the surrounding prose both need revisiting.
    expect(const SphereCaptureConfig().qualityTier, isNull);
  });
}

// ── README § Usage → "Capture, stitch, view" ────────────────────────────────

/// Verbatim from the README.
Future<StitchResult?> captureAndStitch(BuildContext context) async {
  final session = await SphereCaptureSession.create(
    config: const SphereCaptureConfig(),
  );
  if (!context.mounted) return null;

  final bundle = await Navigator.push<CaptureBundle>(
    context,
    MaterialPageRoute(
      builder: (_) => SphereCaptureView(
        session: session,
        onCompleted: (bundle) => Navigator.pop(context, bundle),
      ),
    ),
  );
  if (bundle == null) return null;

  final result = await SphereStitcher().stitch(
    bundle,
    onProgress: (p) =>
        debugPrint('${p.stage.name} ${(p.fraction * 100).round()}%'),
  );

  if (!result.report.meetsQualityTargets) {
    for (final warning in result.report.warnings) {
      debugPrint(warning.message);
    }
  }
  return result;
}

// ── README § Usage → "Stitch in the background instead" ─────────────────────

/// Verbatim from the README.
Future<void> stitchInTheBackground(CaptureBundle bundle) async {
  final queue = StitchQueue(directory: await getApplicationSupportDirectory());
  await queue.load(); // picks up anything a previous run left behind
  await queue.enqueue(bundle); // returns immediately; the manager keeps walking
  await queue.start();

  queue.events.listen((event) {
    if (event.result != null) debugPrint('${event.entry.sessionId} done');
  });
}

// ── README § Usage → "View an existing equirectangular image" ───────────────

/// Verbatim from the README.
Widget viewExistingPanorama() =>
    SphereViewer(image: File('path/to/panorama.jpg'), showControls: true);

/// Verbatim from the README.
Widget viewFromProvider() =>
    const SphereViewer(imageProvider: AssetImage('assets/sample_pano.jpg'));

// ── README § Usage → "Which way does the panorama face?" ────────────────────

/// Verbatim from the README.
void recordWhichWayItFaces(SphereCaptureSession session) {
  // Best source: the manager drew a path on a plan whose north is surveyed, so
  // the facing direction at a station is arithmetic. Costs the user nothing.
  session.setPlanHeading(127.5);

  // Fallback. Indoors the compass is wrong by tens of degrees — rebar, lift
  // motors, steel studs — so it is recorded as what it is and a warning reaches
  // `report.warnings`.
  session.setMagnetometerHeading(310.0);

  // Optional, and supplied rather than measured: this package holds no location
  // permission and deliberately does not ask for one.
  session.setLocation(
    GeoLocation(latitudeDegrees: 51.5074, longitudeDegrees: -0.1278),
  );
}

// ── README § Usage → "Open facing a particular direction" ───────────────────

/// Verbatim from the README.
Widget openFacingNorth(File file, PanoramaMetadata metadata) => SphereViewer(
  image: file,
  controller: SphereViewerController.forPanorama(
    metadata, // from onMetadata, or GPanoReader
    lookAtCompassDegrees: 0, // open looking north
  ),
);

// ── README § Usage → "Optional gyro look" ───────────────────────────────────

/// Verbatim from the README.
Widget gyroLook(File file) => SphereViewer(image: file, gyroscopeEnabled: true);

// ── README § Usage → "Drive the viewer programmatically" ────────────────────

/// Verbatim from the README.
Widget driveViewerProgrammatically(File file) {
  final controller = SphereViewerController(initialFovDegrees: 90);
  final viewer = SphereViewer(image: file, controller: controller);
  // later:
  controller.animateTo(yaw: 3.141592653589793 / 2, fovDegrees: 60);
  controller.autoRotateSpeed = 0.25; // rad/s
  return viewer;
}

// ── README § Configuration ──────────────────────────────────────────────────

/// Verbatim from the README.
const SphereCaptureConfig readmeConfig = SphereCaptureConfig(
  exposure: ExposureStrategy.auto(),
  overlapFraction: 0.33,
  captureNadir: true,
  autoShutter: true,
  aimToleranceDegrees: 4.0,
  steadinessThresholdRadPerSec: 0.12,
  dwell: Duration(milliseconds: 350),
);
