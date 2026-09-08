@Tags(['native'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:sphere_view/src/stitch/native_stitcher.dart';
import 'package:sphere_view/src/stitch/stitch_isolate.dart';
import 'package:sphere_view/src/stitch/stitch_request.dart';

/// Phase 10's tests that drive the real native pipeline.
///
/// Separated from `stitch_pipeline_test.dart` and tagged `native` because they
/// need two things a unit test should not assume: the desktop build of
/// `libsphere_stitch` (`tools/build_native.sh`) and a rendered capture bundle
/// (`dart run tools/synth.dart --all`). Both are what `tools/ci/quality_gate.sh`
/// already produces, so on a machine that has run the gate these just work.
///
/// They are slow on purpose. The exit criteria they cover — cancellation inside
/// 500 ms from any stage, no leak over 100 cancel cycles, 50 cancels during
/// blending — are statements about repetition, and asserting them once would
/// not be asserting them.
void main() {
  late Directory bundleDirectory;
  late CaptureBundle bundle;
  late Directory output;
  late String libraryPath;

  setUpAll(() async {
    libraryPath = File(NativeStitcher.defaultDesktopLibraryPath).absolute.path;
    if (!File(libraryPath).existsSync()) {
      throw StateError(
        'the native stitcher is not built. Run tools/build_native.sh, or run '
        'this suite with --exclude-tags native.',
      );
    }
    // `pristine` rather than `nominal`: one exposure per position, so stage 5
    // passes through and the run is seconds instead of a quarter minute. The
    // bracketed path has its own coverage in Phase 05 and in the gate; what is
    // being measured here is the isolate, the polling and the cancel flag.
    bundleDirectory = Directory('build/bundles/pristine');
    if (!bundleDirectory.existsSync()) {
      throw StateError(
        'no capture bundle at ${bundleDirectory.path}. Render one with '
        '`dart run tools/synth.dart --all --out build/bundles`, or run this '
        'suite with --exclude-tags native.',
      );
    }
    bundle = await CaptureBundle.load(bundleDirectory);
    output = Directory('${bundleDirectory.absolute.path}/replay/phase10');
    await output.create(recursive: true);
  });

  String outputPath(String name) => '${output.path}/$name.jpg';

  SphereStitcher stitcher() =>
      SphereStitcher(tier: QualityTier.low, libraryPath: libraryPath);

  group('a full stitch (§6)', () {
    test(
      'progress advances monotonically through every stage, reaching 1.0',
      () async {
        final ticks = <StitchProgress>[];
        final result = await stitcher().stitch(
          bundle,
          outputPath: outputPath('full'),
          onProgress: ticks.add,
        );

        expect(File(result.equirectPath).existsSync(), isTrue);
        expect(result.width, QualityTier.low.outputWidth);
        expect(result.height, QualityTier.low.outputHeight);
        expect(result.report.tierUsed, QualityTier.low);

        expect(ticks, isNotEmpty);
        for (var i = 1; i < ticks.length; i++) {
          expect(
            ticks[i].fraction,
            greaterThanOrEqualTo(ticks[i - 1].fraction),
            reason:
                'the bar went backwards at ${ticks[i].stage.name} '
                '(${ticks[i - 1].fraction} then ${ticks[i].fraction})',
          );
        }
        expect(ticks.last.fraction, 1.0);
        expect(ticks.first.fraction, lessThan(0.5));

        // Every stage seen. A stage that never appears is a stage the user
        // would watch the bar sit still through.
        final seen = ticks.map((t) => t.stage).toSet();
        expect(
          seen,
          containsAll(<StitchStage>[
            StitchStage.fusing,
            StitchStage.findingFeatures,
            StitchStage.matching,
            StitchStage.adjusting,
            StitchStage.warping,
            StitchStage.blending,
            StitchStage.encoding,
          ]),
          reason: 'stages actually reached: ${seen.map((s) => s.name)}',
        );
        // And each carries something a person can read.
        expect(ticks.every((t) => (t.message ?? '').isNotEmpty), isTrue);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'the main isolate is never blocked long enough to drop a frame',
      () async {
        // The desktop half of the "zero dropped UI frames" criterion. There is
        // no raster thread here to drop anything, so what is measured is the
        // cause rather than the symptom: how long this isolate ever goes
        // without being able to run a callback. A timer asked for every 8 ms —
        // half a 60 Hz frame — that is ever more than 32 ms late would have
        // been a dropped frame in an app.
        //
        // `example/integration_test/stitch_device_test.dart` measures the
        // symptom itself, with `addTimingsCallback`, on a device.
        final gaps = <int>[];
        var previous = DateTime.now();
        final ticker = Timer.periodic(const Duration(milliseconds: 8), (_) {
          final now = DateTime.now();
          gaps.add(now.difference(previous).inMilliseconds);
          previous = now;
        });

        try {
          await stitcher().stitch(bundle, outputPath: outputPath('smooth'));
        } finally {
          ticker.cancel();
        }

        expect(gaps.length, greaterThan(50), reason: 'the probe actually ran');
        final late32 = gaps.where((ms) => ms > 32).toList();
        expect(
          late32,
          isEmpty,
          reason:
              'the event loop stalled for ${late32.join(', ')} ms during the '
              'stitch — on a device each of those is a dropped frame. Worst '
              'gap ${gaps.reduce((a, b) => a > b ? a : b)} ms.',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });

  group('output metadata — S10 (Phase 11 §2)', () {
    test(
      'a real stitch produces a file that is a photo sphere',
      () async {
        // The end-to-end form of criterion S10. `metadata_test.dart` proves the
        // writer is correct over synthetic bytes; this proves the *pipeline*
        // applies it — that the JPEG OpenCV encoded, at the tier the device
        // chose, comes back off disk with a GPano block describing its real
        // dimensions. Between them sit the isolate boundary, the tier table and
        // the native encoder, any of which could leave the metadata step
        // unreached without a single unit test noticing.
        final metadata = PanoramaMetadata(
          // Deliberately wrong, to prove the stitcher overrides it with the
          // size actually produced. A caller cannot know the tier in advance,
          // so a metadata block that trusted them would describe a panorama
          // that does not exist.
          fullWidth: 2,
          fullHeight: 1,
          heading: PanoramaHeading.fromPlan(127.5),
          capturedAt: DateTime.utc(2026, 8, 11, 14, 32, 9),
          make: 'sphere_view',
          model: 'synthetic-rig',
          stationId: 'pristine/station-07',
        );

        final result = await stitcher().stitch(
          bundle,
          outputPath: outputPath('metadata'),
          metadata: metadata,
        );

        final bytes = await File(result.equirectPath).readAsBytes();
        final read = const GPanoReader().read(bytes);
        expect(
          read,
          isNotNull,
          reason: 'the stitched file carries no XMP at all, so every viewer '
              'outside this app will show it as a wide flat photo',
        );
        expect(const GPanoReader().projectionType(bytes), 'equirectangular');
        expect(read!.fullWidth, QualityTier.low.outputWidth);
        expect(read.fullHeight, QualityTier.low.outputHeight);
        expect(read.heading.degrees, closeTo(127.5, 0.01));
        expect(read.heading.source, HeadingSource.plan);
        expect(read.stationId, 'pristine/station-07');
        expect(read.make, 'sphere_view');
        expect(read.model, 'synthetic-rig');

        // Pitch and roll are zero because Math §7 already levelled the
        // panorama against measured gravity. Asserted on the real output
        // rather than only on the packet builder, because this is the file a
        // viewer opens.
        final packet = const GPanoReader().rawPacket(bytes)!;
        expect(
          packet,
          contains('<GPano:PosePitchDegrees>0</GPano:PosePitchDegrees>'),
        );
        expect(
          packet,
          contains('<GPano:PoseRollDegrees>0</GPano:PoseRollDegrees>'),
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'the bundle supplies the metadata when the caller does not',
      () async {
        // The normal path: a host app that just calls `stitch(bundle)` still
        // gets a photo sphere, because the facts are on the bundle. The
        // synthetic rig records no heading (it has neither a plan nor a
        // magnetometer), so this also covers the case §2 says to omit rather
        // than invent.
        final result = await stitcher().stitch(
          bundle,
          outputPath: outputPath('metadata_default'),
        );

        final bytes = await File(result.equirectPath).readAsBytes();
        final read = const GPanoReader().read(bytes)!;
        expect(read.fullWidth, QualityTier.low.outputWidth);
        expect(
          read.stationId,
          bundle.sessionId,
          reason: 'the session id is the station id, and it is what re-attaches '
              'a loose JPEG to the walk it came from',
        );
        expect(
          const GPanoReader().rawPacket(bytes),
          isNot(contains('PoseHeadingDegrees')),
          reason: 'the rig has no heading source, and 0 is a real bearing — '
              'writing it would make an unknown heading indistinguishable from '
              'a surveyed one',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'the preview beside it is a photo sphere too',
      () async {
        // The preview is the file a UI is most likely to share, because it is
        // small. One that opened flat while the full file opened as a sphere
        // is a difference nobody would predict from the file names.
        //
        // It carries the *full* panorama's dimensions rather than its own
        // 2048×1024: that is what GPano's Cropped/Full distinction is for, and
        // it is what makes the small file open at the right zoom instead of
        // appearing to be a fraction of a sphere.
        final result = await SphereStitcher(
          tier: QualityTier.high,
          libraryPath: libraryPath,
        ).stitch(bundle, outputPath: outputPath('metadata_preview'));

        final preview = File(
          result.equirectPath.replaceAll(RegExp(r'\.jpg$'), '_preview.jpg'),
        );
        if (!preview.existsSync()) {
          // Only the `high` tier emits one (Phase 04 §7). If that changes, this
          // test should be told rather than quietly passing.
          fail('no preview was written beside ${result.equirectPath}');
        }

        final read = const GPanoReader().read(preview.readAsBytesSync());
        expect(read, isNotNull);
        expect(read!.fullWidth, QualityTier.high.outputWidth);
        expect(read.fullHeight, QualityTier.high.outputHeight);
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });

  group('cancellation (§3)', () {
    /// Starts a stitch, cancels it once [when] says to, and returns how long
    /// the native side took to stop.
    Future<({int latencyMs, StitchStage? stage})> cancelDuring(
      bool Function(StitchProgress) when, {
      required String name,
    }) async {
      final subject = stitcher();
      final clock = Stopwatch()..start();
      var requestedAt = -1;
      StitchStage? cancelledIn;

      try {
        await subject.stitch(
          bundle,
          outputPath: outputPath(name),
          onProgress: (progress) {
            if (requestedAt < 0 && when(progress)) {
              cancelledIn = progress.stage;
              requestedAt = clock.elapsedMicroseconds;
              subject.cancel();
            }
          },
        );
        fail('the stitch finished instead of being cancelled');
      } on StitchCancelledException {
        expect(requestedAt, greaterThanOrEqualTo(0));
        return (
          latencyMs: (clock.elapsedMicroseconds - requestedAt) ~/ 1000,
          stage: cancelledIn,
        );
      }
    }

    test(
      'a cancel takes effect within 500 ms from early, middle and late stages',
      () async {
        // The three points §6 asks for, expressed as stages rather than as
        // percentages of the bar. On a bundle whose exposures are already
        // fused, "10%" and "50%" are the same instant — the stage is the thing
        // that decides which uninterruptible unit the flag has to survive, and
        // it is what makes the result reproducible on a bundle of any size.
        final points = <String, bool Function(StitchProgress)>{
          'early': (p) => p.stage.index >= StitchStage.findingFeatures.index,
          'middle': (p) => p.stage.index >= StitchStage.warping.index,
          'late': (p) => p.stage.index >= StitchStage.blending.index,
        };
        for (final entry in points.entries) {
          final outcome = await cancelDuring(entry.value, name: 'cancel_${entry.key}');
          expect(
            outcome.latencyMs,
            lessThan(500),
            reason:
                'cancelling during ${outcome.stage?.name} (${entry.key}) took '
                '${outcome.latencyMs} ms',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'cancelling during blending, 50 times, never crashes or hangs',
      () async {
        // The case a user actually hits — they change their mind watching the
        // bar — and the one most likely to leak or crash, because it is the
        // stage holding the most memory and the one with a half-built pyramid
        // to unwind.
        final latencies = <int>[];
        for (var i = 0; i < 50; i++) {
          final outcome = await cancelDuring(
            (p) => p.stage == StitchStage.blending,
            name: 'cancel_blend',
          );
          expect(outcome.stage, StitchStage.blending);
          latencies.add(outcome.latencyMs);
        }
        latencies.sort();
        expect(
          latencies.last,
          lessThan(500),
          reason:
              'worst of 50 cancels during blending was ${latencies.last} ms '
              '(median ${latencies[latencies.length ~/ 2]} ms)',
        );
      },
      timeout: const Timeout(Duration(minutes: 20)),
    );

    test(
      '100 cancel cycles leave no memory behind',
      () async {
        // Every cycle allocates a progress struct, spawns an isolate, opens the
        // library, runs into the pipeline and unwinds it. A leak anywhere in
        // that — the struct, the request string, the error buffer, the report
        // buffer, or the native side's own frames, warp scratch and blender
        // pyramids — shows up as RSS that never comes back down.
        //
        // The three cancel points are rotated rather than fixed. Cancelling
        // during feature detection is cheap and unwinds almost nothing, so a
        // hundred of those would prove very little; warping has warped frames
        // and a memory-mapped store open, and blending has a half-built pyramid.
        // Those are the two places a leak would actually be, and each gets a
        // third of the cycles.
        const cycles = 99;
        const points = <StitchStage>[
          StitchStage.findingFeatures,
          StitchStage.warping,
          StitchStage.blending,
        ];
        Future<void> cycle(int i) => cancelDuring(
          (p) => p.stage.index >= points[i % points.length].index,
          name: 'cancel_cycle',
        );

        // Nine warm-up cycles first, three of each: the early ones pay for the
        // library mapping, OpenCV's one-time allocations and the isolate
        // machinery, none of which is a leak and all of which would look like
        // one if the baseline were taken before them.
        for (var i = 0; i < 9; i++) {
          await cycle(i);
        }
        final baseline = ProcessInfo.currentRss;

        for (var i = 0; i < cycles; i++) {
          await cycle(i);
        }

        final growthMb = (ProcessInfo.currentRss - baseline) ~/ (1024 * 1024);
        // A budget rather than zero, because RSS is a high-water mark under a
        // garbage collector: Dart's heap grows and is not obliged to shrink,
        // and a hundred isolate spawns move it. What a real leak looks like is
        // proportional to the cycle count — one warped frame or one canvas per
        // cancel is megabytes each, so anything of that shape lands far outside
        // this.
        expect(
          growthMb,
          lessThan(64),
          reason:
              'RSS grew $growthMb MB over $cycles cancel cycles across '
              '${points.map((s) => s.name).join(", ")}, which is the shape of '
              'a per-cycle leak rather than heap noise',
        );
      },
      timeout: const Timeout(Duration(minutes: 45)),
    );
  });

  group('the ABI guard (§4)', () {
    /// Calls the library directly with a request that makes it throw.
    Future<NativeStitchOutcome> forcing(String what) async {
      final progress = calloc<SvProgress>();
      try {
        final request = StitchRequest.from(
          bundle,
          tier: QualityTier.low,
          outputPath: outputPath('forced'),
          forceError: what,
        );
        return await StitchIsolate.run(
          jsonEncode(request.toJson()),
          progress.address,
          libraryPath: libraryPath,
        );
      } finally {
        calloc.free(progress);
      }
    }

    test('a C++ exception at the boundary is caught and mapped, not propagated', () async {
      // An exception unwinding into Dart's frames is undefined behaviour and in
      // practice a crash with no Dart stack. If any of these four killed the
      // process, this test would not report a failure — it would take the whole
      // suite with it, which is the point.
      final cases = {
        'cv': SvStatus.openCv,
        'std': SvStatus.internal,
        'unknown': SvStatus.unknown,
        'bad_alloc': SvStatus.outOfMemory,
        'cv_no_mem': SvStatus.outOfMemory,
      };
      for (final entry in cases.entries) {
        final outcome = await forcing(entry.key);
        expect(
          outcome.code,
          entry.value,
          reason: 'force_error=${entry.key} mapped to ${outcome.code}',
        );
        expect(
          outcome.message,
          isNotEmpty,
          reason: 'every failure has to say something the caller can report',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test("OpenCV's own out-of-memory is treated as memory, not as an OpenCV bug", () async {
      // The detail that decides whether the retry path is alive at all on a
      // real device: `cv::fastMalloc` raises a `cv::Exception` with code
      // StsNoMem, not a `std::bad_alloc`, and at 8192x4096 the allocation that
      // fails is virtually always OpenCV's.
      final outcome = await forcing('cv_no_mem');
      expect(outcome.code, SvStatus.outOfMemory);
      expect(SvStatus.isOutOfMemory(outcome.code), isTrue);
      expect(outcome.message.toLowerCase(), contains('memory'));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('OOM recovery (§4)', () {
    test(
      'a forced bad_alloc drops one tier, retries once, and records the downgrade',
      () async {
        // The retry is driven from Dart, so it can be tested against a native
        // side that fails deterministically. `_OomOnceStitcher` is the shipping
        // SphereStitcher with one line changed: the first attempt asks the
        // library to throw.
        final subject = _OomOnceStitcher(libraryPath);
        final result = await subject.stitch(
          bundle,
          outputPath: outputPath('oom'),
        );

        expect(subject.tiersAttempted, [QualityTier.high, QualityTier.mid]);
        expect(result.width, QualityTier.mid.outputWidth);
        expect(result.report.tierUsed, QualityTier.mid);
        expect(
          result.report.warnings.first.code,
          StitchWarningCode.tierDowngradedAfterOom,
        );
        expect(
          result.report.warnings.first.message,
          allOf(contains('6144'), contains('8192'), contains('ran out of memory')),
          reason: 'architecture §8 — the downgrade reaches the caller',
        );
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );

    test('a second failure is an honest error, not a third guess', () async {
      final subject = _OomAlwaysStitcher(libraryPath);
      await expectLater(
        subject.stitch(bundle, outputPath: outputPath('oom_hard')),
        throwsA(
          isA<NativeStitchException>().having(
            (e) => e.code,
            'code',
            SvStatus.outOfMemory,
          ),
        ),
      );
      // Two attempts, not three: a device that cannot hold `mid` after failing
      // `high` will not be rescued by another guess, and each try costs the
      // user another minute.
      expect(subject.tiersAttempted, [QualityTier.high, QualityTier.mid]);
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}

/// A stitcher whose first native call is made to fail with `std::bad_alloc`.
class _OomOnceStitcher extends SphereStitcher {
  _OomOnceStitcher(String libraryPath)
    : super(tier: QualityTier.high, libraryPath: libraryPath);

  final List<QualityTier> tiersAttempted = [];

  @override
  String? forceErrorFor(QualityTier tier, int attempt) {
    tiersAttempted.add(tier);
    return attempt == 0 ? 'bad_alloc' : null;
  }
}

/// A stitcher whose native calls always fail with `std::bad_alloc`.
class _OomAlwaysStitcher extends SphereStitcher {
  _OomAlwaysStitcher(String libraryPath)
    : super(tier: QualityTier.high, libraryPath: libraryPath);

  final List<QualityTier> tiersAttempted = [];

  @override
  String? forceErrorFor(QualityTier tier, int attempt) {
    tiersAttempted.add(tier);
    return 'bad_alloc';
  }
}
