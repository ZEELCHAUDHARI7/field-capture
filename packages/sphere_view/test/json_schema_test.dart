import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'fixtures.dart';

/// Every model must survive a trip through real JSON text.
///
/// Not just `fromJson(toJson(x))` — that would pass even if a field were an
/// object `jsonEncode` cannot represent, or a `double` the decoder widens
/// differently. JSON is both the on-disk bundle format and the native ABI
/// (architecture §6.4, §6.6), so the thing that has to work is
/// `jsonDecode(jsonEncode(toJson(x)))`, which is what these assert.
void main() {
  /// Encodes to text, decodes, and rebuilds — the whole path a model takes on
  /// its way to C++ or to disk.
  T through<T>(
    Map<String, Object?> Function() encode,
    T Function(Map<String, Object?>) decode,
  ) => decode(jsonDecode(jsonEncode(encode())) as Map<String, Object?>);

  group('intrinsics', () {
    test('ImageSize', () {
      const original = ImageSize(3024.5, 4032.25);
      final decoded = through(original.toJson, ImageSize.fromJson);
      expect(decoded, original);
      expect(decoded.width, original.width);
      expect(decoded.height, original.height);
    });

    test('BrownConradyDistortion', () {
      final decoded = through(
        sampleDistortion.toJson,
        BrownConradyDistortion.fromJson,
      );
      expect(decoded, sampleDistortion);
      expect(decoded.openCvCoefficients, sampleDistortion.openCvCoefficients);
    });

    test('LookupTableDistortion', () {
      final decoded = through(
        sampleLookupTable.toJson,
        LookupTableDistortion.fromJson,
      );
      expect(decoded, sampleLookupTable);
      expect(decoded.magnifications, sampleLookupTable.magnifications);
    });

    test('DistortionModel dispatches on its type discriminator', () {
      expect(
        through(sampleDistortion.toJson, DistortionModel.fromJson),
        isA<BrownConradyDistortion>(),
      );
      expect(
        through(sampleLookupTable.toJson, DistortionModel.fromJson),
        isA<LookupTableDistortion>(),
      );
      expect(
        () => DistortionModel.fromJson(const {'type': 'fisheye'}),
        throwsA(isA<SphereJsonFormatException>()),
      );
    });

    test('CameraIntrinsics, with and without a distortion model', () {
      expect(
        through(sampleIntrinsics.toJson, CameraIntrinsics.fromJson),
        sampleIntrinsics,
      );

      // A device that reports no distortion must round-trip as "none", never
      // as zero coefficients — the difference is what StitchReport surfaces.
      final noDistortion = CameraIntrinsics(
        fx: sampleIntrinsics.fx,
        fy: sampleIntrinsics.fy,
        cx: sampleIntrinsics.cx,
        cy: sampleIntrinsics.cy,
        imageSize: sampleIntrinsics.imageSize,
        source: IntrinsicsSource.exifFallback,
      );
      final decoded = through(noDistortion.toJson, CameraIntrinsics.fromJson);
      expect(decoded, noDistortion);
      expect(decoded.distortion, isNull);
    });

    test('every IntrinsicsSource value survives by name', () {
      for (final source in IntrinsicsSource.values) {
        final k = sampleIntrinsics.copyWith(source: source);
        expect(through(k.toJson, CameraIntrinsics.fromJson).source, source);
      }
    });
  });

  group('pose', () {
    test('DevicePose', () {
      final original = samplePose();
      final decoded = through(original.toJson, DevicePose.fromJson);
      expect(decoded, original);
      expect(decoded.timestampUs, original.timestampUs);
      expect(decoded.toOpenCvRotation(), original.toOpenCvRotation());
    });
  });

  group('plan', () {
    test('CaptureTarget', () {
      for (final target in sampleTargets) {
        expect(through(target.toJson, CaptureTarget.fromJson), target);
      }
    });

    test('CoverageReport, including its gap records', () {
      final decoded = through(sampleCoverage.toJson, CoverageReport.fromJson);
      expect(decoded, sampleCoverage);
      expect(decoded.gaps, sampleCoverage.gaps);
      expect(decoded.isAcceptable, isFalse);
    });

    test('an empty gap list stays a list', () {
      const perfect = CoverageReport(
        fractionCoveredAtLeastOnce: 1.0,
        // What ω = 0.33 actually measures — see Math §8. Deliberately below the
        // 0.95 an earlier S5 asked for, because a fixture that only passes at
        // ~49% overlap would quietly re-assert the criterion the derivation
        // there disproved.
        fractionCoveredAtLeastTwice: 0.807,
        minimumPairwiseOverlap: 0.32,
        gaps: [],
      );
      final decoded = through(perfect.toJson, CoverageReport.fromJson);
      expect(decoded, perfect);
      expect(decoded.isAcceptable, isTrue);
    });

    test('S5b fails a plan whose neighbours barely overlap', () {
      // The sparse_plan case: the sphere is covered, but no adjacent pair shares
      // enough for the matcher. S5a alone would pass this.
      const sparse = CoverageReport(
        fractionCoveredAtLeastOnce: 1.0,
        fractionCoveredAtLeastTwice: 0.72,
        minimumPairwiseOverlap: 0.15,
        gaps: [],
      );
      expect(sparse.isAcceptable, isFalse);
    });

    test('a bundle written before S5b existed still loads', () {
      // The replay corpus is permanent (arch §6.6): a manifest missing the newer
      // key must load rather than throw, or every recorded regression case dies
      // the day a metric is added.
      final legacy = {
        'fraction_covered_at_least_once': 1.0,
        'fraction_covered_at_least_twice': 0.81,
        'gaps': <Object?>[],
      };
      final decoded = CoverageReport.fromJson(legacy);
      expect(decoded.fractionCoveredAtLeastOnce, 1.0);
      expect(decoded.minimumPairwiseOverlap, 0.0);
    });

    test('CapturePlan', () {
      final decoded = through(samplePlan.toJson, CapturePlan.fromJson);
      expect(decoded, samplePlan);
      expect(decoded.targets, samplePlan.targets);
      expect(decoded.ringIndices, [0, 1]);
      expect(decoded.targetsInRing(0), hasLength(2));
    });
  });

  group('captured data', () {
    test('ExposureShot, with and without optional fields', () {
      for (final shot in sampleShots) {
        expect(through(shot.toJson, ExposureShot.fromJson), shot);
      }
    });

    test('CapturedPosition', () {
      for (final position in samplePositions) {
        expect(
          through(position.toJson, CapturedPosition.fromJson),
          position,
        );
      }
    });
  });

  group('config', () {
    test('ExposureStrategy, both variants', () {
      const locked = ExposureStrategy.locked();
      expect(through(locked.toJson, ExposureStrategy.fromJson), locked);

      const bracket = ExposureStrategy.bracket3(evSpread: 1.75);
      final decoded = through(bracket.toJson, ExposureStrategy.fromJson);
      expect(decoded, bracket);
      expect(decoded.evBiases, [-1.75, 0.0, 1.75]);
      expect(decoded.shotsPerPosition, 3);

      expect(
        () => ExposureStrategy.fromJson(const {'type': 'bracket5'}),
        throwsA(isA<SphereJsonFormatException>()),
      );
    });

    test('SphereCaptureConfig, defaults and overrides', () {
      const defaults = SphereCaptureConfig();
      expect(
        through(defaults.toJson, SphereCaptureConfig.fromJson),
        defaults,
      );

      const custom = SphereCaptureConfig(
        exposure: ExposureStrategy.locked(),
        overlapFraction: 0.4,
        captureNadir: true,
        autoShutter: false,
        aimToleranceDegrees: 2.5,
        steadinessThresholdRadPerSec: 0.08,
        dwell: Duration(milliseconds: 500),
        minSharpness: 61.5,
        qualityTier: QualityTier.high,
      );
      final decoded = through(custom.toJson, SphereCaptureConfig.fromJson);
      expect(decoded, custom);
      expect(decoded.qualityTier, QualityTier.high);
    });

    test('a null qualityTier stays null — it means "probe the RAM"', () {
      const config = SphereCaptureConfig();
      expect(config.qualityTier, isNull);
      final decoded = through(config.toJson, SphereCaptureConfig.fromJson);
      expect(decoded.qualityTier, isNull);
    });

    test('QualityTier geometry matches architecture §6.5', () {
      expect(QualityTier.low.outputWidth, 4096);
      expect(QualityTier.low.outputHeight, 2048);
      expect(QualityTier.low.stripCount, 4);
      expect(QualityTier.mid.outputWidth, 6144);
      expect(QualityTier.mid.outputHeight, 3072);
      expect(QualityTier.mid.stripCount, 6);
      expect(QualityTier.high.outputWidth, 8192);
      expect(QualityTier.high.outputHeight, 4096);
      expect(QualityTier.high.stripCount, 8);
      for (final tier in QualityTier.values) {
        expect(
          tier.outputWidth,
          tier.outputHeight * 2,
          reason: 'equirectangular output is always 2:1',
        );
      }
    });
  });

  group('results', () {
    test('StitchProgress, with and without a message', () {
      const withMessage = StitchProgress(
        stage: StitchStage.blending,
        fraction: 0.7312456,
        message: 'strip 4 of 6',
      );
      expect(
        through(withMessage.toJson, StitchProgress.fromJson),
        withMessage,
      );

      const withoutMessage = StitchProgress(
        stage: StitchStage.fusing,
        fraction: 0.0,
      );
      final decoded = through(
        withoutMessage.toJson,
        StitchProgress.fromJson,
      );
      expect(decoded, withoutMessage);
      expect(decoded.message, isNull);
    });

    test('every StitchStage survives by name', () {
      for (final stage in StitchStage.values) {
        final progress = StitchProgress(stage: stage, fraction: 0.5);
        expect(
          through(progress.toJson, StitchProgress.fromJson).stage,
          stage,
        );
      }
    });

    test('StitchStage ordinals are the native ABI and must not move', () {
      // C++ writes the stage as an int32 and Dart reads it back with
      // StitchStage.values[stage] (architecture §6.3). Reordering this enum
      // silently remaps every progress report, so the order is pinned here.
      expect(StitchStage.values.map((s) => s.name).toList(), [
        'fusing',
        'undistorting',
        'findingFeatures',
        'matching',
        'adjusting',
        'warping',
        'compensating',
        'seaming',
        'blending',
        'fillingPoles',
        'encoding',
      ]);
    });

    test('StitchReport', () {
      final decoded = through(sampleReport.toJson, StitchReport.fromJson);
      expect(decoded, sampleReport);
      expect(decoded.warnings, sampleReport.warnings);
      expect(decoded.droppedPositionIndices, [4, 17]);
      expect(decoded.refinedIntrinsics.source,
          IntrinsicsSource.refinedByStitcher);
    });

    test('meetsQualityTargets follows the criteria it cites', () {
      // The fixture's coverage of 0.9987 now *passes* S5, and that is the fix
      // rather than a slip. The old test was `>= 1.0 - 1e-9` against a fraction
      // computed as `covered / 40000`, so one uncovered lattice point out of forty
      // thousand — which every real capture leaves — failed it by 2.5e-5 against a
      // tolerance 25 000x smaller. The gate was unreachable on hardware, which
      // silently disabled the example's storage policy instead of failing loudly.
      expect(sampleReport.meetsQualityTargets, isTrue);

      final passing = StitchReport(
        rmsReprojectionErrorPx: 0.62,
        loopClosureErrorDegrees: 0.11,
        maxGainRatio: 1.014,
        coverageFraction: 1.0,
        refinedFocalPx: 3251.0,
        refinedIntrinsics: sampleIntrinsics,
        residualTiltDegrees: 0.09,
        droppedPositionIndices: const [],
        warnings: const [],
        elapsedMs: 38000,
        tierUsed: QualityTier.mid,
      );
      expect(passing.meetsQualityTargets, isTrue);

      // Each criterion alone is sufficient to fail it.
      expect(_failing(passing, rms: 1.0).meetsQualityTargets, isFalse);
      expect(_failing(passing, loop: 0.25).meetsQualityTargets, isFalse);
      expect(_failing(passing, gain: 1.03).meetsQualityTargets, isFalse);
      expect(_failing(passing, tilt: 0.2).meetsQualityTargets, isFalse);
      // Coverage still gates — at a threshold a real capture can actually reach.
      expect(_failing(passing, coverage: 0.99).meetsQualityTargets, isFalse);
      expect(
        _failing(passing, coverage: 0.9987).meetsQualityTargets,
        isTrue,
        reason: 'a handful of uncovered lattice points is a passing sphere',
      );
    });

    test('StitchResult', () {
      final decoded = through(sampleResult.toJson, StitchResult.fromJson);
      expect(decoded, sampleResult);
      expect(decoded.report, sampleResult.report);
    });
  });

  group('guidance', () {
    test('GuidanceState', () {
      const state = GuidanceState(
        angularErrorRadians: 0.0312456,
        targetScreenOffsetX: -0.1734,
        targetScreenOffsetY: 0.4218,
        hint: GuidanceHint.turnRight,
        withinAimTolerance: false,
        steady: true,
        dwellProgress: 0.3125,
      );
      expect(through(state.toJson, GuidanceState.fromJson), state);
    });

    test('every GuidanceHint survives by name', () {
      for (final hint in GuidanceHint.values) {
        final state = GuidanceState(
          angularErrorRadians: 0,
          targetScreenOffsetX: 0,
          targetScreenOffsetY: 0,
          hint: hint,
          withinAimTolerance: true,
          steady: true,
          dwellProgress: 1,
        );
        expect(through(state.toJson, GuidanceState.fromJson).hint, hint);
      }
    });
  });

  group('equality and hashing', () {
    test('== and hashCode agree across every model', () {
      final pairs = <String, (Object, Object)>{
        'ImageSize': (const ImageSize(1, 2), const ImageSize(1, 2)),
        'BrownConradyDistortion': (sampleDistortion, sampleDistortion),
        'LookupTableDistortion': (sampleLookupTable, sampleLookupTable),
        'CameraIntrinsics': (sampleIntrinsics, sampleIntrinsics.copyWith()),
        'DevicePose': (samplePose(), samplePose()),
        'CaptureTarget': (sampleTargets.first, sampleTargets.first),
        'CoverageReport': (sampleCoverage, sampleCoverage),
        'CapturePlan': (samplePlan, samplePlan),
        'ExposureShot': (sampleShots.first, sampleShots.first),
        'CapturedPosition': (samplePositions.first, samplePositions.first),
        'LockedExposure': (
          const ExposureStrategy.locked(),
          const ExposureStrategy.locked(),
        ),
        'Bracket3Exposure': (
          const ExposureStrategy.bracket3(),
          const ExposureStrategy.bracket3(evSpread: 2.0),
        ),
        'SphereCaptureConfig': (
          const SphereCaptureConfig(),
          const SphereCaptureConfig(),
        ),
        'StitchReport': (sampleReport, sampleReport),
        'StitchResult': (sampleResult, sampleResult),
      };
      pairs.forEach((name, pair) {
        expect(pair.$1, pair.$2, reason: '$name ==');
        expect(pair.$1.hashCode, pair.$2.hashCode, reason: '$name hashCode');
      });
    });

    test('differing values compare unequal', () {
      expect(
        sampleIntrinsics.copyWith(fx: sampleIntrinsics.fx + 1e-9),
        isNot(sampleIntrinsics),
      );
      expect(
        const ExposureStrategy.bracket3(evSpread: 2.0),
        isNot(const ExposureStrategy.bracket3(evSpread: 1.5)),
      );
      expect(
        const ExposureStrategy.locked(),
        isNot(const ExposureStrategy.bracket3()),
      );
    });
  });
}

StitchReport _failing(
  StitchReport base, {
  double? rms,
  double? loop,
  double? gain,
  double? tilt,
  double? coverage,
}) => StitchReport(
  rmsReprojectionErrorPx: rms ?? base.rmsReprojectionErrorPx,
  loopClosureErrorDegrees: loop ?? base.loopClosureErrorDegrees,
  maxGainRatio: gain ?? base.maxGainRatio,
  coverageFraction: coverage ?? base.coverageFraction,
  refinedFocalPx: base.refinedFocalPx,
  refinedIntrinsics: base.refinedIntrinsics,
  residualTiltDegrees: tilt ?? base.residualTiltDegrees,
  droppedPositionIndices: base.droppedPositionIndices,
  warnings: base.warnings,
  elapsedMs: base.elapsedMs,
  tierUsed: base.tierUsed,
);
