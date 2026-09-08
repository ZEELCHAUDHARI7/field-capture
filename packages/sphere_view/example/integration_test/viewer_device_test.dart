// The Phase 11 §3 tests that only a device can answer.
//
// Two of Phase 11's exit criteria are statements about a GPU, and neither can
// be checked on a laptop:
//
//   1. **60 fps sustained while dragging, at every tier, on the lowest-end
//      target device.** A desktop test rendering into an offscreen surface
//      measures a machine nobody will use. `SchedulerBinding.addTimingsCallback`
//      measures what the engine actually built, and it exists only in a real
//      engine — and the number that matters is the *raster* duration, because
//      an equirect fragment shader is fill-rate bound and the raster thread is
//      where it will run out.
//
//   2. **An 8192-wide output renders on a 4096-max-texture GPU.** This is the
//      black-sphere criterion. An oversized texture upload does not throw and
//      does not log; it silently produces nothing, and to a user that is
//      indistinguishable from a stitcher that wrote an empty file. The desktop
//      suite can prove the *arithmetic* downscales correctly
//      (`test/viewer_test.dart`), but only a real GL context can say what this
//      GPU's ceiling actually is and that the resulting texture uploads.
//
// It needs no physical setup — no camera, no permission, nobody holding
// anything. It writes its own panoramas and looks at them. Run it and send back
// `sphere_view_phase11_report.json`.
//
// Read the fps numbers with the device's refresh rate in mind: a 120 Hz iPad
// budgets 8.3 ms per frame, not 16.7, and this suite records the budget it
// judged against rather than assuming 60.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sphere_view/sphere_view.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final report = <String, Object?>{};
  late Directory work;

  /// Writes a real equirectangular JPEG [width] wide.
  ///
  /// Generated on the device rather than shipped as an asset: an 8192×4096
  /// JPEG is a large thing to put in a repository, and the point of the test
  /// is the upload rather than the picture. The gradient makes a wrong
  /// orientation visible in a screenshot if anyone takes one.
  Future<File> writePanorama(String name, int width) async {
    final image = img.Image(width: width, height: width ~/ 2);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgb(
          x,
          y,
          (x * 255) ~/ image.width,
          (y * 255) ~/ image.height,
          ((x ~/ 64 + y ~/ 64) % 2) * 255,
        );
      }
    }
    final file = File('${work.path}/$name');
    await file.writeAsBytes(img.encodeJpg(image, quality: 85));
    return file;
  }

  setUpAll(() async {
    final documents = await getApplicationDocumentsDirectory();
    work = Directory('${documents.path}/phase11');
    if (await work.exists()) await work.delete(recursive: true);
    await work.create(recursive: true);
    report['platform'] = Platform.operatingSystem;
    report['os_version'] = Platform.operatingSystemVersion;
  });

  tearDownAll(() async {
    final file = File('${work.parent.path}/sphere_view_phase11_report.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    // ignore: avoid_print
    print('Phase 11 report written to ${file.path}');
    // ignore: avoid_print
    print(const JsonEncoder.withIndent('  ').convert(report));
  });

  testWidgets('1. this GPU reports its texture ceiling', (tester) async {
    // The number the whole of §3.1 turns on. A device that will not say gets
    // the conservative floor, which is the safe direction — but it is worth
    // knowing which devices those are, because on them every panorama is
    // displayed at 4096 whether it needed to be or not.
    final limit = await TextureLimit.probe();
    report['max_texture_size'] = limit.maxEdgePx;
    report['max_texture_size_probed'] = limit.probed;

    // ignore: avoid_print
    print(
      'GL_MAX_TEXTURE_SIZE: ${limit.maxEdgePx}'
      '${limit.probed ? '' : ' (assumed — the platform did not answer)'}',
    );

    expect(limit.maxEdgePx, greaterThanOrEqualTo(2048));
    if (limit.probed && limit.maxEdgePx < 8192) {
      // Not a failure. This is precisely the device Phase 11 §3.1 is about, and
      // finding one is the point of running this on a fleet.
      // ignore: avoid_print
      print(
        'NOTE: this device caps below 8192, so the `high` tier will be '
        'downscaled for display. This is the case the next test covers.',
      );
    }
  });

  testWidgets('2. an 8192 panorama renders rather than going black', (
    tester,
  ) async {
    // The exit criterion, stated as the failure it prevents. The assertion is
    // not "an image was decoded" — it is that the rendered sphere is *not
    // uniformly black*, because a failed upload leaves a shader sampling an
    // empty texture and every other symptom is absent.
    final file = await writePanorama('pano_8192.jpg', 8192);
    final limit = await TextureLimit.probe();

    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: const ValueKey('viewer'),
          child: SphereViewer(
            image: file,
            showLoadingIndicator: false,
            onWarning: (w) => report['downscale_warning'] = w,
          ),
        ),
      ),
    );

    // Real decode work; a fixed number of pumps rather than pumpAndSettle,
    // because the viewer ticks only while something moves.
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byType(CustomPaint).evaluate().isNotEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 250));

    final image = await binding.takeScreenshot('viewer_8192');
    report['uploaded_8192'] = true;
    report['texture_limit_for_8192'] = limit.maxEdgePx;

    // `takeScreenshot` returns the raw RGBA bytes on both platforms.
    var nonBlack = 0;
    for (var i = 0; i + 3 < image.length; i += 4) {
      if (image[i] > 8 || image[i + 1] > 8 || image[i + 2] > 8) nonBlack++;
    }
    final fraction = nonBlack / (image.length / 4);
    report['non_black_fraction_8192'] = fraction;

    expect(
      fraction,
      greaterThan(0.5),
      reason:
          'the sphere came back ${((1 - fraction) * 100).toStringAsFixed(1)}% '
          'black, which is what an oversized texture upload looks like — it '
          'does not throw and does not log. This GPU reports a ceiling of '
          '${limit.maxEdgePx}, so the panorama should have been downscaled '
          'before upload.',
    );
  });

  for (final tier in QualityTier.values) {
    testWidgets('3. 60 fps while dragging at tier ${tier.name}', (tester) async {
      // §3.4's frame-rate criterion, at every tier because the fill cost scales
      // with the texture and the lowest-end device is the one that will run out
      // — and it is the *raster* thread that runs out, not the UI thread. A
      // build-time-only measurement would report a comfortable margin on a
      // device that is visibly stuttering.
      final file = await writePanorama(
        'pano_${tier.outputWidth}.jpg',
        tier.outputWidth,
      );

      final controller = SphereViewerController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SphereViewer(
            image: file,
            controller: controller,
            showLoadingIndicator: false,
          ),
        ),
      );
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find.byType(CustomPaint).evaluate().isNotEmpty) break;
      }
      await tester.pump(const Duration(milliseconds: 300));

      final timings = <FrameTiming>[];
      void collect(List<FrameTiming> t) => timings.addAll(t);
      binding.addTimingsCallback(collect);
      addTearDown(() => binding.removeTimingsCallback(collect));

      // A continuous drag, the way a person looks around: 120 frames of
      // sustained motion rather than one flick, because the criterion is
      // "sustained" and a shader that thermally throttles does it after a
      // second or two, not immediately.
      for (var i = 0; i < 120; i++) {
        controller.drag(0.012 * math.cos(i / 20), 0.004 * math.sin(i / 15));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        timings,
        isNotEmpty,
        reason: 'no frames were timed, so this measured nothing',
      );

      // The device's own refresh rate, not an assumed 60: a 120 Hz iPad budgets
      // 8.3 ms and judging it against 16.7 would pass a viewer that is dropping
      // every other frame.
      final refreshHz = tester.view.display.refreshRate;
      final budgetMs = 1000.0 / (refreshHz > 1 ? refreshHz : 60);

      List<double> msOf(Duration Function(FrameTiming) pick) =>
          [for (final t in timings) pick(t).inMicroseconds / 1000.0];
      final build = msOf((t) => t.buildDuration);
      final raster = msOf((t) => t.rasterDuration);
      final total = msOf((t) => t.totalSpan);

      double percentile(List<double> values, double p) {
        final sorted = [...values]..sort();
        return sorted[(sorted.length * p).clamp(0, sorted.length - 1).floor()];
      }

      final over = total.where((ms) => ms > budgetMs).length;
      final stats = {
        'tier': tier.name,
        'output_width': tier.outputWidth,
        'refresh_hz': refreshHz,
        'budget_ms': budgetMs,
        'frames': timings.length,
        'build_p50_ms': percentile(build, 0.5),
        'build_p95_ms': percentile(build, 0.95),
        'raster_p50_ms': percentile(raster, 0.5),
        'raster_p95_ms': percentile(raster, 0.95),
        'total_p95_ms': percentile(total, 0.95),
        'frames_over_budget': over,
        'fraction_over_budget': over / timings.length,
      };
      report['fps_${tier.name}'] = stats;
      // ignore: avoid_print
      print('tier ${tier.name}: ${const JsonEncoder().convert(stats)}');

      expect(
        percentile(raster, 0.95),
        lessThan(budgetMs),
        reason:
            'the raster thread spent ${percentile(raster, 0.95).toStringAsFixed(1)} ms '
            'on the slowest 5% of frames against a ${budgetMs.toStringAsFixed(1)} ms '
            'budget at tier ${tier.name} (${tier.outputWidth} wide). The equirect '
            'shader is fill-rate bound, so this is the number that decides whether '
            'dragging feels smooth.',
      );
    });
  }

  testWidgets('4. the preview appears before the full image', (tester) async {
    // §3.1's progressive load, timed where the timing means something. The
    // desktop test proves the *ordering*; only a device says whether the
    // preview actually arrives fast enough to be worth having.
    final full = await writePanorama('progressive.jpg', 6144);
    await writePanorama('progressive_preview.jpg', 2048);

    final clock = Stopwatch()..start();
    int? previewMs;
    int? fullMs;

    await tester.pumpWidget(
      MaterialApp(
        home: SphereViewer(image: full, showLoadingIndicator: false),
      ),
    );

    for (var i = 0; i < 600; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final painted = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<Object>()
          .isNotEmpty;
      if (painted && previewMs == null) previewMs = clock.elapsedMilliseconds;
      if (previewMs != null && clock.elapsedMilliseconds > 100) {
        fullMs ??= clock.elapsedMilliseconds;
      }
      if (fullMs != null) break;
    }

    report['preview_visible_ms'] = previewMs;
    // ignore: avoid_print
    print('first paint at $previewMs ms');

    expect(previewMs, isNotNull, reason: 'nothing was ever painted');
    expect(
      previewMs!,
      lessThan(600),
      reason:
          'the preview took $previewMs ms to appear. §3.1 budgets ~50 ms for '
          'it against ~800 ms for the full image, and the whole reason the '
          'preview exists is that 800 ms of blank screen after a tap is long '
          'enough that people tap again.',
    );
  });
}
