import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:sphere_view/src/stitch/native_stitcher.dart';
import 'package:sphere_view/src/stitch/stitch_progress_mapper.dart';
import 'package:sphere_view/src/stitch/stitch_request.dart';

import 'capture_fixtures.dart';
import 'fixtures.dart';

/// Phase 10's tests that need neither the native library nor a bundle of
/// JPEGs — the shared-memory ABI, the tier arithmetic, the request shape and
/// the background queue. The ones that drive real C++ live in
/// `stitch_native_test.dart`.
void main() {
  group('the shared-memory ABI (§2, §7.6)', () {
    test('SvProgress is exactly the 12 bytes sphere_stitch.h declares', () {
      // Not pedantry. The struct is a raw overlay on memory C++ also writes,
      // so a layout difference is not an error — it is `cancel` reading
      // whatever happens to sit at offset 12, which presents as cancellation
      // silently not working on one platform.
      expect(sizeOf<SvProgress>(), 12);
      SvProgressAbi.assertLayout();
    });

    test('a Pointer round-trips across the isolate boundary by address', () async {
      // The whole trick the progress design rests on (§2.1). A Pointer is not
      // sendable; an int is; and both isolates share one process address
      // space, so what the worker writes through `Pointer.fromAddress` is
      // visible here with no copying and no synchronisation.
      final progress = calloc<SvProgress>();
      try {
        expect(progress.ref.stage, 0);
        expect(progress.ref.permille, 0);
        expect(progress.ref.cancel, 0, reason: 'calloc must zero it — §7.3');

        final address = progress.address;
        final echoed = await Isolate.run(() {
          final there = Pointer<SvProgress>.fromAddress(address);
          there.ref.stage = 8;
          there.ref.permille = 640;
          return there.ref.cancel;
        });

        expect(echoed, 0, reason: 'the worker saw the value this isolate wrote');
        expect(progress.ref.stage, 8);
        expect(progress.ref.permille, 640);

        // And the other direction, which is cancellation.
        progress.ref.cancel = 1;
        final sawCancel = await Isolate.run(
          () => Pointer<SvProgress>.fromAddress(address).ref.cancel,
        );
        expect(sawCancel, 1);
      } finally {
        calloc.free(progress);
      }
    });
  });

  group('progress mapping (§2)', () {
    test('the stage weights sum to exactly 1000', () {
      final total = StitchProgressMapper.stageWeightsPermille.values
          .fold<int>(0, (a, b) => a + b);
      expect(total, 1000);
      // Every stage weighted, or a stage would contribute nothing and the bar
      // would stall through it.
      expect(
        StitchProgressMapper.stageWeightsPermille.keys.toSet(),
        StitchStage.values.toSet(),
      );
    });

    test('progress advances monotonically through every stage to 1.0', () {
      final mapper = StitchProgressMapper();
      var last = -1.0;
      final seen = <StitchStage>{};
      for (final stage in StitchStage.values) {
        for (final permille in const [0, 250, 500, 750, 1000]) {
          final fraction = mapper.fractionFor(stage, permille);
          expect(
            fraction,
            greaterThanOrEqualTo(last),
            reason: 'went backwards at ${stage.name} $permille',
          );
          expect(fraction, inInclusiveRange(0.0, 1.0));
          last = fraction;
        }
        seen.add(stage);
      }
      expect(seen, StitchStage.values.toSet());
      expect(last, closeTo(1.0, 1e-9), reason: 'the last stage spends the last weight');
      expect(mapper.completed.fraction, 1.0);
    });

    test('a stale or out-of-order read never moves the bar backwards', () {
      // The poller reads two int32s that C++ writes independently, so it can
      // observe a new stage with the old stage's count. It must not be
      // possible for that to show the user a bar that retreats.
      final mapper = StitchProgressMapper();
      final forward = mapper.fractionFor(StitchStage.blending, 900);
      expect(mapper.fractionFor(StitchStage.fusing, 10), forward);
      expect(mapper.fractionFor(StitchStage.warping, 0), forward);
    });

    test('an out-of-range stage ordinal is clamped, not thrown', () {
      // The ABI hazard the StitchStage doc warns about. A progress tick is not
      // worth failing a stitch that is otherwise working.
      final progress = calloc<SvProgress>();
      try {
        progress.ref.stage = 99;
        progress.ref.permille = 500;
        final tick = StitchProgressMapper().read(progress);
        expect(tick.stage, StitchStage.values.last);
      } finally {
        calloc.free(progress);
      }
    });
  });

  group('memory tiers (§4)', () {
    test('the tier probe returns a stable value across 20 calls', () async {
      // The point of using *total* memory rather than available: twenty calls
      // must give one answer, or output resolution stops being deterministic
      // per device and a bug report stops being actionable.
      final platform = FakeCameraPlatform()
        ..totalMemoryMb = 3900
        ..availableMemoryMb = -1;
      final tiers = <QualityTier>{};
      for (var i = 0; i < 20; i++) {
        tiers.add(await MemoryTier.probe(platform: platform));
      }
      expect(tiers, {QualityTier.mid});
    });

    test('the thresholds are architecture §6.5s table', () {
      expect(MemoryTier.forTotalMemoryMb(2048), QualityTier.low);
      expect(MemoryTier.forTotalMemoryMb(3071), QualityTier.low);
      expect(MemoryTier.forTotalMemoryMb(3072), QualityTier.mid);
      expect(MemoryTier.forTotalMemoryMb(6143), QualityTier.mid);
      expect(MemoryTier.forTotalMemoryMb(6144), QualityTier.high);
      expect(MemoryTier.forTotalMemoryMb(12288), QualityTier.high);
    });

    test('an unavailable headroom figure does not downgrade anything', () {
      // Android returns -1 because it has no honest per-process number. Reading
      // that as bad news would put every Android tablet a tier below the one it
      // can run.
      final probe = MemoryTier.resolve(totalMb: 8192, availableMb: -1);
      expect(probe.tier, QualityTier.high);
      expect(probe.wasDowngraded, isFalse);
      expect(probe.warning, isNull);
    });

    test('the iOS pre-flight drops a tier when headroom is short, and says so', () {
      // The case iOS cannot recover from: it kills on memory pressure with no
      // signal, so the only defence is asking before starting.
      final probe = MemoryTier.resolve(totalMb: 8192, availableMb: 500);
      expect(probe.tierFromTotalMemory, QualityTier.high);
      expect(probe.tier, QualityTier.mid);
      expect(probe.wasDowngraded, isTrue);
      expect(probe.warning?.code, StitchWarningCode.tierDowngradedBeforeStart);
      expect(probe.warning?.message, contains('6144'));
      expect(
        probe.warning?.message,
        contains('only 500 MB of memory was free'),
        reason: 'architecture §8 — the compromise has to reach the caller',
      );
    });

    test('a headroom figure below every tier lands on the smallest', () {
      final probe = MemoryTier.resolve(totalMb: 8192, availableMb: 10);
      expect(probe.tier, QualityTier.low);
      expect(probe.warning, isNotNull);
    });

    test('a platform that will not answer falls back low rather than failing', () async {
      final probe = await MemoryTier.probeDetailed(platform: _RefusingPlatform());
      expect(probe.tier, MemoryTier.fallbackTier);
      expect(probe.tier, QualityTier.low);
      expect(probe.warning, isNotNull);
    });

    test('degrade walks down one step and stops at the bottom', () {
      expect(MemoryTier.degrade(QualityTier.high), QualityTier.mid);
      expect(MemoryTier.degrade(QualityTier.mid), QualityTier.low);
      expect(MemoryTier.degrade(QualityTier.low), isNull);
    });
  });

  group('the request payload (§6.4)', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('sv_request');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('capture_quarter_turns is lifted to the top level', () {
      // registration.cpp reads it from the request root, while bundle.json
      // carries it nested. The synthetic harness always records 0, so nothing
      // in the gate can see the difference — but on a tablet whose camera is
      // mounted a quarter turn off the display, leaving it nested rolls every
      // bundle-adjustment seed and presents as a stitcher bug.
      final bundle = sampleBundle(root).copyWith(captureQuarterTurns: 3);
      final json = StitchRequest.from(
        bundle,
        tier: QualityTier.mid,
        outputPath: '${root.path}/out.jpg',
      ).toJson();

      expect(json['capture_quarter_turns'], 3);
      expect(
        (json['bundle'] as Map)['capture_quarter_turns'],
        3,
        reason: 'and it stays in the bundle, which is the portable record',
      );
    });

    test('the tier decides the canvas — no output_width is sent', () {
      // `tools/replay` overrides the width so S6 compares like with like. The
      // device must not, or the tier stops being the memory ceiling it exists
      // to be.
      final json = StitchRequest.from(
        sampleBundle(root),
        tier: QualityTier.low,
        outputPath: '${root.path}/out.jpg',
      ).toJson();
      final compositing = json['compositing_options'] as Map;

      expect(compositing.containsKey('output_width'), isFalse);
      expect(json['tier'], 'low');
      expect(compositing['strip_count'], QualityTier.low.stripCount);
      expect(compositing['wrap_pad'], StitchRequest.defaultWrapPadPx);
      expect(
        compositing['emit_debug_maps'],
        isFalse,
        reason: 'the label map alone is 134 MB at high tier',
      );
    });

    test('the schema version matches the native header', () async {
      final header = await File('src/sphere_stitch/sphere_stitch.h').readAsString();
      final match = RegExp(
        r'#define SV_SCHEMA_VERSION\s+(\d+)',
      ).firstMatch(header);
      expect(match, isNotNull, reason: 'the header still declares a version');
      expect(int.parse(match!.group(1)!), StitchRequest.schemaVersion);
    });

    test('the SV_ERR_* codes match the native header', () async {
      // Two lists of integers in two languages, which is exactly the shape of
      // thing that drifts. A wrong code here means an out-of-memory failure
      // stops being retried and starts being reported.
      final header = await File('src/sphere_stitch/sphere_stitch.h').readAsString();
      int declared(String name) => int.parse(
        RegExp('#define $name\\s+(-?\\d+)').firstMatch(header)!.group(1)!,
      );
      expect(declared('SV_OK'), SvStatus.ok);
      expect(declared('SV_ERR_CANCELLED'), SvStatus.cancelled);
      expect(declared('SV_ERR_INSUFFICIENT'), SvStatus.insufficient);
      expect(declared('SV_ERR_INTERNAL'), SvStatus.internal);
      expect(declared('SV_ERR_OUT_OF_MEMORY'), SvStatus.outOfMemory);
      expect(declared('SV_ERR_OPENCV'), SvStatus.openCv);
      expect(declared('SV_ERR_UNKNOWN'), SvStatus.unknown);
    });

    test('the stage ordinals match the native header', () async {
      // `StitchStage.values[stage]` is read straight off shared memory, so an
      // inserted value silently remaps every progress report the user sees.
      final header = await File('src/sphere_stitch/sphere_stitch.h').readAsString();
      const names = {
        StitchStage.fusing: 'SV_STAGE_FUSING',
        StitchStage.undistorting: 'SV_STAGE_UNDISTORTING',
        StitchStage.findingFeatures: 'SV_STAGE_FINDING_FEATURES',
        StitchStage.matching: 'SV_STAGE_MATCHING',
        StitchStage.adjusting: 'SV_STAGE_ADJUSTING',
        StitchStage.warping: 'SV_STAGE_WARPING',
        StitchStage.compensating: 'SV_STAGE_COMPENSATING',
        StitchStage.seaming: 'SV_STAGE_SEAMING',
        StitchStage.blending: 'SV_STAGE_BLENDING',
        StitchStage.fillingPoles: 'SV_STAGE_FILLING_POLES',
        StitchStage.encoding: 'SV_STAGE_ENCODING',
      };
      for (final entry in names.entries) {
        final declared = int.parse(
          RegExp('#define ${entry.value}\\s+(\\d+)').firstMatch(header)!.group(1)!,
        );
        expect(
          declared,
          entry.key.index,
          reason: '${entry.value} and StitchStage.${entry.key.name} disagree',
        );
      }
    });
  });

  group('the thermal rule for background work (§5)', () {
    test('the queue refuses at serious where a user-requested stitch warns', () {
      expect(
        ThermalPolicy.forStitch(ThermalState.serious).action,
        ThermalAction.warn,
      );
      expect(
        ThermalPolicy.forBackgroundStitch(ThermalState.serious).action,
        ThermalAction.refuse,
      );
      for (final state in [ThermalState.nominal, ThermalState.fair]) {
        expect(ThermalPolicy.forBackgroundStitch(state).allowed, isTrue);
      }
      expect(
        ThermalPolicy.forBackgroundStitch(ThermalState.critical).allowed,
        isFalse,
      );
    });
  });
}

/// A platform whose memory probe fails, for the fallback branch.
class _RefusingPlatform implements SphereCameraPlatform {
  @override
  Future<int> totalPhysicalMemoryMb() async =>
      throw StateError('no such service');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not modelled by this fake',
  );
}
