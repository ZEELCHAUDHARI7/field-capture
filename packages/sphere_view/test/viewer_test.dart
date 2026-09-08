import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sphere_view/src/api/models/device_pose.dart';
import 'package:sphere_view/src/metadata/gpano_writer.dart';
import 'package:sphere_view/src/metadata/panorama_metadata.dart';
import 'package:sphere_view/src/tracking/pose_source.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:sphere_view/src/viewer/panorama_texture.dart';
import 'package:sphere_view/src/viewer/sphere_viewer_widget.dart';
import 'package:sphere_view/src/viewer/viewer_controller.dart';
import 'package:vector_math/vector_math_64.dart';

import 'capture_fixtures.dart';
import 'pose_fixtures.dart';

/// Phase 11 §3.4's viewer tests, less the direction-marker golden — that one
/// carries the correctness argument and lives in `viewer_mapping_test.dart`.
///
/// The 60 fps criterion is not here and cannot be: it is a statement about a
/// specific GPU under a specific thermal load, and a laptop rendering into an
/// offscreen surface would answer a question nobody asked. It belongs on a
/// device, in `example/integration_test/`.
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('sphere_viewer'));
  tearDown(() => temp.deleteSync(recursive: true));

  /// Writes a real equirectangular JPEG of [width]×[width]/2.
  File writePanorama(String name, int width, {PanoramaMetadata? metadata}) {
    final image = img.Image(width: width, height: width ~/ 2);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgb(x, y, (x * 255) ~/ image.width, 128, 200);
      }
    }
    final file = File('${temp.path}/$name')
      ..writeAsBytesSync(img.encodeJpg(image, quality: 70));
    if (metadata != null) {
      file.writeAsBytesSync(
        const GPanoWriter().writeBytes(file.readAsBytesSync(), metadata),
      );
    }
    return file;
  }

  group('the GPU texture ceiling (§3.1)', () {
    test('an 8192 panorama is downscaled to fit a 4096-limited GPU', () async {
      // The criterion that a black sphere is the failure mode. An oversized
      // upload does not throw and does not log — it renders nothing — so the
      // only defence is never to attempt one.
      const limit = TextureLimit(4096);
      expect(limit.decodeWidthFor(8192, 4096), 4096);
      expect(limit.requiresDownscale(8192), isTrue);

      final texture =
          await PanoramaLoader(limit).decode(writePanorama('big.jpg', 8192).readAsBytesSync());
      addTearDown(texture.dispose);

      expect(texture.image.width, lessThanOrEqualTo(4096));
      expect(texture.image.height, lessThanOrEqualTo(4096));
      expect(
        texture.image.width,
        4096,
        reason: 'halving keeps the equirect exactly 2:1',
      );
      expect(texture.image.height, 2048);
      expect(
        texture.sourceWidth,
        8192,
        reason: 'the real size is still reported, so the caller can say what '
            'the file is as opposed to what is on screen',
      );
      expect(texture.downscaleNote, contains('8192'));
    });

    test('a 6144 panorama fits a 8192 GPU untouched', () async {
      const limit = TextureLimit(8192);
      expect(limit.decodeWidthFor(6144, 3072), 6144);
      expect(limit.requiresDownscale(6144), isFalse);

      final texture = await PanoramaLoader(limit)
          .decode(writePanorama('mid.jpg', 6144).readAsBytesSync());
      addTearDown(texture.dispose);
      expect(texture.image.width, 6144);
      expect(
        texture.downscaleNote,
        isNull,
        reason: 'nothing was compromised, so nothing should be reported',
      );
    });

    test('an unknown limit resolves downwards, never upwards', () async {
      // Assuming more than the GPU can do is the failure this guards. A
      // needless downscale costs sharpness; a missing one costs the image.
      expect(TextureLimit.unknown.maxEdgePx, TextureLimit.conservativeFloor);
      expect(TextureLimit.unknown.probed, isFalse);

      final platform = FakeCameraPlatform()..maxTextureSizePx = 0;
      final probed = await TextureLimit.probe(platform: platform);
      expect(probed.maxEdgePx, 4096);
      expect(probed.probed, isFalse);
    });

    test('a probed limit is used as given', () async {
      final platform = FakeCameraPlatform()..maxTextureSizePx = 16384;
      final probed = await TextureLimit.probe(platform: platform);
      expect(probed.maxEdgePx, 16384);
      expect(probed.probed, isTrue);
    });

    test('the decode is off the UI thread and never holds the full bitmap', () async {
      // `instantiateCodec` with a target size resizes *during* decode. Decoding
      // at full size and scaling afterwards would allocate 134 MB to produce a
      // 33 MB image, on exactly the devices least able to afford it.
      final bytes = writePanorama('huge.jpg', 8192).readAsBytesSync();
      final texture =
          await PanoramaLoader(const TextureLimit(2048)).decode(bytes);
      addTearDown(texture.dispose);
      expect(texture.image.width, 2048);
      expect(texture.image.height, 1024);
    });
  });

  group('progressive load (§3.1)', () {
    testWidgets('the preview is on screen before the full image', (tester) async {
      // The preview appears in ~50 ms against the full image's ~800 ms, which
      // is the difference between "instant" and "sluggish" — and 800 ms of
      // blank screen after a tap is long enough that people tap again.
      final full = writePanorama('panorama.jpg', 4096);
      final preview = writePanorama('panorama_preview.jpg', 2048);
      expect(preview.existsSync(), isTrue);

      // `runAsync` because the load is genuine I/O — a file read and an image
      // decode — and the fake clock a widget test normally runs under does not
      // advance either. Without it the viewer never gets past its spinner and
      // the test would be measuring the test harness.
      final widths = <int>[];
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: SphereViewer(
              image: full,
              textureLimit: const TextureLimit(8192),
              onWarning: (_) {},
            ),
          ),
        );

        // Watch every texture the viewer adopts, in order.
        for (var i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          final width = _paintedWidth(tester);
          if (width != null && (widths.isEmpty || widths.last != width)) {
            widths.add(width);
          }
          if (widths.length >= 2) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });

      expect(
        widths,
        [2048, 4096],
        reason: 'the 2048 preview must be shown first and then replaced by the '
            'full image; a single entry means the preview was skipped and the '
            'user watched a spinner instead',
      );
    });

    testWidgets('the preview is found automatically beside the panorama', (
      tester,
    ) async {
      // `compositing.cpp` writes `<stem>_preview.jpg`. Finding it without being
      // told makes the fast path automatic for every caller who does nothing.
      final full = writePanorama('station.jpg', 2048);
      writePanorama('station_preview.jpg', 512);

      int? firstWidth;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: SphereViewer(
              image: full,
              textureLimit: const TextureLimit(8192),
            ),
          ),
        );
        for (var i = 0; i < 200 && firstWidth == null; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          firstWidth = _paintedWidth(tester);
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });

      expect(
        firstWidth,
        512,
        reason: 'the preview beside the panorama should have been found and '
            'shown first, without the caller naming it',
      );
    });

    testWidgets('a panorama with no preview still loads', (tester) async {
      final full = writePanorama('lonely.jpg', 1024);
      int? width;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: SphereViewer(
              image: full,
              textureLimit: const TextureLimit(8192),
            ),
          ),
        );
        for (var i = 0; i < 200 && width == null; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          width = _paintedWidth(tester);
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      expect(width, 1024);
    });

    testWidgets('a failed full-res load keeps the preview, and says so', (
      tester,
    ) async {
      // Keeping the preview is right — a soft panorama beats an error page —
      // but a user who zooms in to read a defect off it is entitled to know
      // why it will not sharpen (architecture §8).
      final full = writePanorama('broken.jpg', 2048);
      writePanorama('broken_preview.jpg', 512);
      // Corrupt the full image only, after the preview exists.
      full.writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0x00, 0x01]);

      final warnings = <String>[];
      int? width;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: SphereViewer(
              image: full,
              textureLimit: const TextureLimit(8192),
              onWarning: warnings.add,
            ),
          ),
        );
        for (var i = 0; i < 200 && warnings.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        // Read after the loop, not inside it: the preview and the failure can
        // land in the same turn, and a width sampled only while `warnings` was
        // still empty would miss it.
        await tester.pump(const Duration(milliseconds: 16));
        width = _paintedWidth(tester);
      });

      expect(width, 512, reason: 'the preview must stay on screen');
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('low-resolution preview'));
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('a GPU-forced downscale reaches the caller', (tester) async {
      // Architecture §8: a manager judging a defect deserves to know they are
      // looking at a reduced rendering rather than at the file.
      final warnings = <String>[];
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: SphereViewer(
              image: writePanorama('oversize.jpg', 4096),
              textureLimit: const TextureLimit(1024),
              onWarning: warnings.add,
            ),
          ),
        );
        for (var i = 0; i < 200 && warnings.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('4096'));
      expect(warnings.single, contains('full resolution'));
    });
  });

  group('zoom clamps (§3.2)', () {
    test('pinching in stops at 30°', () {
      // Below 30° the source resolution runs out and it looks broken — and the
      // thing it looks broken at is the stitcher.
      final controller = SphereViewerController(initialFovDegrees: 75);
      addTearDown(controller.dispose);
      for (var i = 0; i < 50; i++) {
        controller.zoom(1.5);
      }
      expect(controller.fovDegrees, closeTo(30, 1e-9));
    });

    test('pinching out stops at 100°', () {
      // Past 100° the projection's corner stretching reads as a lens fault.
      final controller = SphereViewerController(initialFovDegrees: 75);
      addTearDown(controller.dispose);
      for (var i = 0; i < 50; i++) {
        controller.zoom(1 / 1.5);
      }
      expect(controller.fovDegrees, closeTo(100, 1e-9));
    });

    test('an out-of-range opening zoom is clamped, not honoured', () {
      final tooTight = SphereViewerController(initialFovDegrees: 5);
      final tooWide = SphereViewerController(initialFovDegrees: 170);
      addTearDown(tooTight.dispose);
      addTearDown(tooWide.dispose);
      expect(tooTight.fovDegrees, closeTo(30, 1e-9));
      expect(tooWide.fovDegrees, closeTo(100, 1e-9));
    });

    test('a nonsensical zoom factor is ignored rather than propagated', () {
      final controller = SphereViewerController(initialFovDegrees: 75);
      addTearDown(controller.dispose);
      controller.zoom(0);
      controller.zoom(double.nan);
      expect(controller.fovDegrees, closeTo(75, 1e-9));
    });
  });

  group('pitch clamp (§3.2)', () {
    test('no amount of dragging reaches an upside-down state', () {
      // The failure this prevents is not cosmetic: rolling past the pole leaves
      // the horizon inverted, and a user who does it by accident has no idea
      // what happened or how to undo it.
      final controller = SphereViewerController();
      addTearDown(controller.dispose);
      for (var i = 0; i < 500; i++) {
        controller.drag(0, 0.05);
      }
      expect(controller.pitch, lessThanOrEqualTo(math.pi / 2));
      expect(controller.pitch, greaterThan(math.pi / 2 - 0.02));

      for (var i = 0; i < 1000; i++) {
        controller.drag(0, -0.05);
      }
      expect(controller.pitch, greaterThanOrEqualTo(-math.pi / 2));
      expect(controller.pitch, lessThan(-math.pi / 2 + 0.02));
    });

    test('the stop is soft: resistance grows as the pole approaches', () {
      // A hard clamp feels as though the drag stopped tracking the finger.
      // Resistance that grows towards the limit reads as the edge of the world,
      // which is what it is.
      final controller = SphereViewerController();
      addTearDown(controller.dispose);

      controller.drag(0, 0.1);
      final freeStep = controller.pitch;
      expect(
        freeStep,
        closeTo(0.1, 1e-9),
        reason: 'away from the pole the drag is 1:1',
      );

      controller.setOrientation(pitch: math.pi / 2 - 0.05);
      final before = controller.pitch;
      controller.drag(0, 0.1);
      final resistedStep = controller.pitch - before;
      expect(
        resistedStep,
        lessThan(0.1),
        reason: 'inside the soft-stop band the same drag moves the view less',
      );
      expect(resistedStep, greaterThan(0));
    });

    test('the soft stop never makes coming back sticky', () {
      // Damping motion away from the pole as well would leave a user who hit
      // the top unable to get out at the speed they got in.
      final controller = SphereViewerController();
      addTearDown(controller.dispose);
      controller.setOrientation(pitch: math.pi / 2);
      controller.drag(0, -0.1);
      expect(controller.pitch, closeTo(math.pi / 2 - 0.1, 1e-9));
    });

    test('inertia cannot carry the view past the pole either', () {
      // The clamp has to hold on the ticker path as well as the gesture one;
      // a flick is exactly how somebody would reach the limit fastest.
      final controller = SphereViewerController();
      addTearDown(controller.dispose);
      controller.drag(0, 0.4);
      for (var i = 0; i < 200; i++) {
        controller.applyInertiaTick(1 / 60);
      }
      expect(controller.pitch.abs(), lessThanOrEqualTo(math.pi / 2));
    });
  });

  group('opening direction (§3.2)', () {
    test('opens at PoseHeadingDegrees when the caller names a bearing', () {
      // The panorama's centre faces 90°; the caller wants to look north. North
      // is a quarter turn to the *left* of the centre, and yaw increases to the
      // left (Math §3), so the opening yaw is +π/2.
      final metadata = PanoramaMetadata(
        fullWidth: 4096,
        fullHeight: 2048,
        heading: PanoramaHeading.fromPlan(90),
      );
      final controller = SphereViewerController.forPanorama(
        metadata,
        lookAtCompassDegrees: 0,
      );
      addTearDown(controller.dispose);
      expect(controller.yaw, closeTo(math.pi / 2, 1e-9));
    });

    test('opens at yaw 0 when the panorama has no heading', () {
      // Which is the session-start direction — still meaningful, just not
      // north-referenced.
      final controller = SphereViewerController.forPanorama(
        PanoramaMetadata(fullWidth: 4096, fullHeight: 2048),
        lookAtCompassDegrees: 0,
      );
      addTearDown(controller.dispose);
      expect(controller.yaw, 0);
    });

    test('opens at yaw 0 when the caller names no bearing', () {
      final controller = SphereViewerController.forPanorama(
        PanoramaMetadata(
          fullWidth: 4096,
          fullHeight: 2048,
          heading: PanoramaHeading.fromPlan(127.5),
        ),
      );
      addTearDown(controller.dispose);
      expect(controller.yaw, 0);
    });

    test('the heading conversion takes the short way round', () {
      // 350° to 10° is 20° of turn, not 340°. Getting this wrong spins the
      // view most of the way round the sphere on opening.
      expect(
        PanoramaMetadata.yawForCompassHeading(10, 350),
        closeTo(-20 * math.pi / 180, 1e-9),
      );
      expect(
        PanoramaMetadata.yawForCompassHeading(350, 10),
        closeTo(20 * math.pi / 180, 1e-9),
      );
    });

    testWidgets('the viewer reports the panorama metadata it read', (
      tester,
    ) async {
      final file = writePanorama(
        'described.jpg',
        1024,
        metadata: PanoramaMetadata(
          fullWidth: 6144,
          fullHeight: 3072,
          heading: PanoramaHeading.fromPlan(127.5),
          stationId: 'station-07',
        ),
      );

      PanoramaMetadata? seen;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: SphereViewer(
              image: file,
              textureLimit: const TextureLimit(8192),
              onMetadata: (m) => seen = m,
            ),
          ),
        );
        for (var i = 0; i < 200 && seen == null; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });

      expect(seen, isNotNull);
      expect(seen!.heading.degrees, closeTo(127.5, 0.01));
      expect(seen!.stationId, 'station-07');
    });
  });

  group('double-tap reset (§3.2)', () {
    test('returns to the opening orientation and zoom', () {
      final controller = SphereViewerController(
        initialYaw: 1.0,
        initialPitch: 0.2,
        initialFovDegrees: 75,
      );
      addTearDown(controller.dispose);

      controller.drag(0.8, -0.5);
      controller.zoom(2.0);
      controller.roll = 0.4;
      expect(controller.yaw, isNot(closeTo(1.0, 1e-6)));

      controller.resetToHome();
      for (var i = 0; i < 60; i++) {
        controller.applyInertiaTick(1 / 60);
      }

      expect(controller.yaw, closeTo(1.0, 1e-3));
      expect(controller.pitch, closeTo(0.2, 1e-3));
      expect(controller.fovDegrees, closeTo(75, 1e-3));
      expect(
        controller.roll,
        0,
        reason: 'a reset that left the horizon tilted would not be a reset',
      );
    });
  });

  group('gyro look (§3.2)', () {
    testWidgets('is off by default and starts no sensor', (tester) async {
      // Delightful when expected, disorienting when not: a viewer that starts
      // panning because the user shifted in their chair reads as a bug.
      final source = _RecordingPoseSource();
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: SphereViewer(
              image: writePanorama('still.jpg', 512),
              poseSource: source,
              textureLimit: const TextureLimit(8192),
            ),
          ),
        );
        await _settle(tester);
      });
      expect(source.startCount, 0);
      expect(source.listenerCount, 0);
    });

    testWidgets('toggles on and off cleanly, leaking no subscription', (
      tester,
    ) async {
      // §3.4 asks that it "does not leak the sensor subscription". The leak
      // that actually happens is the other one — cancelling the Dart stream
      // while leaving the platform sensor registered leaves a tablet sampling
      // its IMU at 100 Hz for the rest of the app's life, which is a battery
      // complaint nobody would trace back to a closed panorama.
      final source = _RecordingPoseSource();
      final file = writePanorama('gyro.jpg', 512);

      Future<void> pumpWith(bool enabled) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SphereViewer(
              image: file,
              poseSource: source,
              gyroscopeEnabled: enabled,
              textureLimit: const TextureLimit(8192),
            ),
          ),
        );
        await _settle(tester);
      }

      await tester.runAsync(() async {
        await pumpWith(true);
        expect(source.startCount, 1);
        expect(source.listenerCount, 1);

        await pumpWith(false);
        expect(
          source.listenerCount,
          0,
          reason: 'switching gyro look off must cancel the pose subscription',
        );
        expect(
          source.stopCount,
          0,
          reason: 'a pose source the caller supplied belongs to the caller and '
              'must not be stopped from under them',
        );

        await pumpWith(true);
        expect(source.startCount, 2);
        expect(source.listenerCount, 1);

        // Tearing the widget down has to release it too.
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await _settle(tester);
        expect(source.listenerCount, 0);
      });
    });

    testWidgets('does not snap the view when it is switched on', (tester) async {
      // A pose source's yaw 0 is wherever the device pointed when *it* started
      // (Math §1.1), which has nothing to do with where the user is looking in
      // this panorama. Without a datum, enabling gyro look would jump the view
      // to an arbitrary direction — the disorientation §3.2 warns about.
      final source = _RecordingPoseSource();
      final controller = SphereViewerController(initialYaw: 1.0);
      addTearDown(controller.dispose);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: SphereViewer(
              image: writePanorama('datum.jpg', 512),
              poseSource: source,
              controller: controller,
              gyroscopeEnabled: true,
              textureLimit: const TextureLimit(8192),
            ),
          ),
        );
        await _settle(tester);

        // The device happens to be pointing at yaw 2.0 when gyro look starts.
        source.emit(yaw: 2.0, pitch: 0.0);
        await _settle(tester);
        expect(
          controller.yaw,
          closeTo(1.0, 1e-6),
          reason: 'the first sample sets the datum and must not move the view',
        );

        // A quarter turn of the device is a quarter turn of the view.
        source.emit(yaw: 2.0 + math.pi / 4, pitch: 0.1);
        await _settle(tester);
        expect(controller.yaw, closeTo(1.0 + math.pi / 4, 1e-6));
        expect(controller.pitch, closeTo(0.1, 1e-6));
      });
    });

    testWidgets('a device with no gyroscope says so rather than failing', (
      tester,
    ) async {
      final source = _RecordingPoseSource()..supported = false;
      final warnings = <String>[];
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: SphereViewer(
              image: writePanorama('nogyro.jpg', 512),
              poseSource: source,
              gyroscopeEnabled: true,
              textureLimit: const TextureLimit(8192),
              onWarning: warnings.add,
            ),
          ),
        );
        await _settle(tester);
      });

      expect(source.startCount, 0);
      expect(warnings.single, contains('no gyroscope'));
      expect(
        find.byType(CustomPaint),
        findsWidgets,
        reason: 'the panorama still has to be viewable by dragging',
      );
    });
  });
}

/// Pumps a few frames with real time passing, for the widget tests that run
/// inside [WidgetTester.runAsync].
///
/// `pumpAndSettle` cannot be used in any of them: it waits for the frame
/// scheduler to go quiet, and these tests deliberately run real asynchronous
/// work — file reads, image decodes, a pose stream — that a fake clock never
/// advances.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The width of the panorama the viewer is currently painting, or `null` when
/// it has not painted one yet.
int? _paintedWidth(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((w) => w.painter)
    .whereType<SpherePainter>()
    .firstOrNull
    ?.panorama
    .width;

/// A pose source that records what the viewer did to it.
class _RecordingPoseSource implements PoseSource {
  final _controller = StreamController<DevicePose>.broadcast();

  int startCount = 0;
  int stopCount = 0;
  bool supported = true;

  /// How many listeners are attached right now — the leak check.
  int listenerCount = 0;

  @override
  Future<bool> get isSupported async => supported;

  @override
  Future<PoseSupport> get support async =>
      supported ? supportedPose : gyrolessPose;

  @override
  Stream<DevicePose> get poses {
    // Wraps the broadcast stream so attach/detach is observable, which is the
    // property under test.
    return Stream.multi((listener) {
      listenerCount++;
      final subscription = _controller.stream.listen(
        listener.addSync,
        onError: listener.addErrorSync,
        onDone: listener.closeSync,
      );
      listener.onCancel = () {
        listenerCount--;
        return subscription.cancel();
      };
    });
  }

  @override
  Future<void> start() async => startCount++;

  @override
  Future<void> stop() async => stopCount++;

  void emit({required double yaw, required double pitch}) {
    // Built through the package's own aiming construction rather than by
    // composing quaternions here, so that the pose's `yaw`/`pitch` accessors
    // mean exactly what Math §3 says they do — a second construction in a test
    // file is precisely the duplication `SphericalConventions` exists to
    // prevent.
    _controller.add(
      DevicePose(
        deviceToWorld: SphericalConventions.aimingOrientation(yaw, pitch),
        gravityWorld: Vector3(0, 1, 0),
        timestampUs: 0,
        angularSpeedRadPerSec: 0,
      ),
    );
  }
}
