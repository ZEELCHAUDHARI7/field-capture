import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:sphere_view/src/utils/math_utils.dart';

import 'capture_fixtures.dart';

/// Phase 08 §6, tests 1–5: the plan, and the proof that it covers the sphere.
///
/// The plan builder is a pure function of the measured intrinsics, which is the
/// whole argument for testing it here rather than on a device: the previous
/// implementation hard-coded 8 shots per ring at an assumed 52° HFOV, and the
/// only way that survives is if nothing ever checks the arithmetic against the
/// optics it claims to be derived from.
void main() {
  const builder = PlanBuilder();

  /// Shot counts per ring, in shooting order.
  List<int> ringCounts(CapturePlan plan) {
    final counts = <int, int>{};
    for (final target in plan.targets) {
      counts[target.ringIndex] = (counts[target.ringIndex] ?? 0) + 1;
    }
    return [
      for (final index in plan.ringIndices) counts[index]!,
    ];
  }

  /// Ring pitches in deg, in shooting order.
  List<double> ringPitches(CapturePlan plan) => [
    for (final index in plan.ringIndices)
      plan.targetsInRing(index).first.pitch / deg,
  ];

  group('test 1 — every fixture intrinsics set produces a plan the validator '
      'accepts', () {
    for (final device in fleet) {
      test(device.name, () {
        // `buildPlan` throws unless the coverage proof passes, so reaching the
        // assertions at all is most of the test. The rest names the numbers so
        // a regression says which criterion moved.
        final plan = builder.buildPlan(
          intrinsics: device.intrinsics,
          captureNadir: true,
        );
        final coverage = plan.coverage;

        expect(
          coverage.fractionCoveredAtLeastOnce,
          greaterThanOrEqualTo(1 - CoverageReport.coverageTolerance),
          reason: 'S5a: ${device.note}',
        );
        expect(
          coverage.minimumPairwiseOverlap,
          greaterThanOrEqualTo(CoverageReport.minimumAdjacentOverlap),
          reason: 'S5b, the criterion feature matching actually needs',
        );
        expect(
          coverage.fractionCoveredAtLeastTwice,
          greaterThanOrEqualTo(CoverageReport.minimumDoubleCoverage),
          reason: 'S5c, the floor against degenerate plans',
        );
        expect(coverage.gapCount, 0);
        expect(coverage.latticePointCount, greaterThanOrEqualTo(39000));

        // S7's budget is 90 s. At roughly 2.5 s a bracketed position, anything
        // past ~36 positions cannot fit however good the guidance is.
        expect(plan.length, lessThanOrEqualTo(36), reason: 'S7 headroom');
      });
    }

    test('and with the nadir skipped, only the declared cap is uncovered', () {
      for (final device in fleet) {
        final plan = builder.buildPlan(intrinsics: device.intrinsics);
        final skipped = CoverageValidator.nadirCapFraction(
          90 - device.intrinsics.vfovDegrees / 2,
        );
        final missing = 1 - plan.coverage.fractionCoveredAtLeastOnce;
        // The hole must be no larger than the shot that was declined: a plan
        // cannot pass by leaving a gap bigger than the frame it skipped.
        expect(
          missing,
          lessThanOrEqualTo(skipped + 1e-9),
          reason: '${device.name} left more uncovered than one nadir frame',
        );
        expect(missing, greaterThan(0), reason: '${device.name} nadir is a hole');
      }
    });
  });

  group('test 2 — a plan that cannot succeed is refused before the camera '
      'opens', () {
    test('ω = 0.05 is rejected, with a message naming what failed', () {
      expect(
        () => builder.buildPlan(
          intrinsics: fovIntrinsics(50, 69),
          overlapFraction: 0.05,
        ),
        throwsA(
          isA<InsufficientCoverageException>()
              .having(
                (e) => e.failedCriteria,
                'failedCriteria',
                isNotEmpty,
              )
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('refused before the camera opened'),
                  contains('S5'),
                ),
              ),
        ),
      );
    });

    test('the refusal quotes the plan it actually measured', () {
      // The message must describe the plan that was rejected, not some earlier
      // candidate — a rejection pointing at the wrong numbers is worse than no
      // numbers, because it sends the reader to the wrong lever.
      try {
        builder.buildPlan(
          intrinsics: fovIntrinsics(50, 69),
          overlapFraction: 0.05,
        );
        fail('expected the plan to be refused');
      } on InsufficientCoverageException catch (e) {
        expect(e.overlapFraction, 0.05);
        expect(e.positions, greaterThan(0));
        expect(e.intrinsics!.hfovDegrees, closeTo(50, 0.05));
        expect(e.coverage.gapCount, greaterThan(0));
      }
    });

    test('enforceCoverage: false still measures, it just does not refuse', () {
      // The one legitimate caller is the Phase 02 harness, whose `sparse_plan`
      // profile exists to show what a 15%-overlap plan does to the output.
      final plan = builder.buildPlan(
        intrinsics: fovIntrinsics(50, 69),
        overlapFraction: 0.15,
        enforceCoverage: false,
      );
      expect(plan.coverage.isAcceptable, isFalse);
      expect(plan.coverage.minimumPairwiseOverlap, lessThan(0.25));
    });

    test('an overlap outside [0, 1) is a programming error, not a refusal', () {
      expect(
        () => builder.buildPlan(
          intrinsics: fovIntrinsics(50, 69),
          overlapFraction: 1.0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('test 3 — the worked example of Math §8 reproduces exactly', () {
    // h = 50°, v = 69°, ω = 0.33:
    //   Δpitch = 69 · 0.67 = 46.2°
    //   ring φ =   0°: Δyaw = 33.5°/1.000 → n = 11
    //   ring φ = ±46°: Δyaw = 33.5°/0.695 → n =  8
    //   two shots at each pole, the second rolled 90°
    // → 11 + 8 + 8 + 2 = 29 nadir-skipped, 31 with the nadir.
    final intrinsics = fovIntrinsics(50, 69);

    test('the fixture really is 50° × 69°', () {
      expect(intrinsics.hfovDegrees, closeTo(50, 0.05));
      expect(intrinsics.vfovDegrees, closeTo(69, 0.05));
    });

    test('29 positions with the nadir skipped, as 11 / 8 / 2 / 8', () {
      final plan = builder.buildPlan(intrinsics: intrinsics);
      expect(plan.length, 29);
      // Shooting order, not geometric order: equator, up, zenith, down.
      expect(ringCounts(plan), [11, 8, 2, 8]);
      expect(
        ringPitches(plan).map((p) => p.round()),
        [0, 46, 90, -46],
      );
    });

    test('31 with the nadir captured', () {
      final plan = builder.buildPlan(
        intrinsics: intrinsics,
        captureNadir: true,
      );
      expect(plan.length, 31);
      expect(ringCounts(plan), [11, 8, 2, 8, 2]);
      expect(ringPitches(plan).map((p) => p.round()), [0, 46, 90, -46, -90]);
    });

    test('two frames at each pole, the second rolled 90°', () {
      // Math §8, as corrected by the rasteriser: a lone polar frame covers the
      // ±70° caps exactly once, which pins double coverage near 90% however
      // tight the rings get. The roll is what makes the second frame a
      // different view rather than a duplicate.
      final plan = builder.buildPlan(
        intrinsics: intrinsics,
        captureNadir: true,
      );
      for (final label in ['zenith', 'nadir']) {
        final pole = plan.targets.where((t) => t.ringLabel == label).toList();
        expect(pole, hasLength(2), reason: label);
        expect(pole.every((t) => t.isPole), isTrue);
        expect(
          MathUtils.wrapPi(pole[1].yaw - pole[0].yaw).abs(),
          closeTo(math.pi / 2, 1e-12),
          reason: '$label: the second frame is rolled a quarter turn',
        );
        // Same direction, different orientation — which is exactly why aim
        // error cannot be a yaw comparison here (§7 pitfall 3).
        expect(
          pole[0].direction.distanceTo(pole[1].direction),
          closeTo(0, 1e-12),
        );
        expect(pole[0].screenUp.dot(pole[1].screenUp), closeTo(0, 1e-12));
      }
    });

    test('the measured coverage is the one Math §8 quotes as passing', () {
      final plan = builder.buildPlan(
        intrinsics: intrinsics,
        captureNadir: true,
      );
      expect(plan.coverage.fractionCoveredAtLeastOnce, 1.0);
      // Math §8's table records ~80% here, measured on the equal-area lat/lon
      // sampler this validator replaced. The Fibonacci lattice reads a couple
      // of points lower on the same plan — a lat/lon grid's columns can align
      // with a ring's seams, and the golden angle has no rational period, which
      // is the reason for the change. Both are far above the 70% floor, and the
      // floor is what S5c is: a floor, reported and not tuned to.
      expect(plan.coverage.fractionCoveredAtLeastTwice, greaterThan(0.70));
      expect(plan.coverage.fractionCoveredAtLeastTwice, lessThan(0.85));
    });
  });

  group('test 4 — rings are staggered so vertical seams do not stack', () {
    test('no two rings share a yaw value, on any fixture', () {
      for (final device in fleet) {
        final plan = builder.buildPlan(
          intrinsics: device.intrinsics,
          captureNadir: true,
        );
        final byRing = <int, List<double>>{};
        for (final target in plan.targets) {
          // Poles are excluded: their "yaw" is a roll about the optical axis,
          // not a heading, so comparing it with a ring's headings compares two
          // different quantities that happen to share a field.
          if (target.isPole) continue;
          byRing.putIfAbsent(target.ringIndex, () => []).add(target.yaw);
        }
        final rings = byRing.keys.toList();
        for (var a = 0; a < rings.length; a++) {
          for (var b = a + 1; b < rings.length; b++) {
            for (final yawA in byRing[rings[a]]!) {
              for (final yawB in byRing[rings[b]]!) {
                expect(
                  MathUtils.wrapPi(yawA - yawB).abs(),
                  greaterThan(1e-6),
                  reason:
                      '${device.name}: rings ${rings[a]} and ${rings[b]} both '
                      'shoot yaw ${yawA / deg}°, so their vertical seams '
                      'land in the same column',
                );
              }
            }
          }
        }
      }
    });

    test('vertically adjacent rings are offset by about half a step', () {
      final plan = builder.buildPlan(intrinsics: fovIntrinsics(50, 69));
      // Rings 0 and +1 in shooting order.
      final equator = plan.targetsInRing(0);
      final upper = plan.targetsInRing(1);
      final step = 2 * math.pi / upper.length;
      final nearest = upper
          .map(
            (u) => equator
                .map((e) => MathUtils.wrapPi(u.yaw - e.yaw).abs())
                .reduce(math.min),
          )
          .reduce(math.max);
      // Half of the *upper* ring's step is the most any of its frames can be
      // from an equator frame once the two counts differ; what matters is that
      // it is nowhere near zero.
      expect(nearest, greaterThan(step / 8));
    });

    test('the north and south rings do not mirror onto each other', () {
      // Rings +k and −k have the same |φ|, so the same shot count and the same
      // step. A stagger built only from step parity gives them *identical* yaw
      // sets, and the half-step rule then achieves nothing between them.
      final plan = builder.buildPlan(intrinsics: fovIntrinsics(50, 69));
      final up = plan.targetsInRing(1).map((t) => t.yaw).toList();
      final down = plan.targetsInRing(3).map((t) => t.yaw).toList();
      expect(up, hasLength(down.length));
      for (final a in up) {
        for (final b in down) {
          expect(MathUtils.wrapPi(a - b).abs(), greaterThan(1e-6));
        }
      }
    });
  });

  group('test 5 — the order is for the human holding the tablet', () {
    final plan = builder.buildPlan(
      intrinsics: fovIntrinsics(50, 69),
      captureNadir: true,
    );

    test('the equator ring comes first, whole', () {
      // Rule 5: if the session is abandoned halfway, the useful part is done —
      // and on a site walk the content a manager cares about is at eye level.
      final equator = plan.targets.take(11);
      expect(equator.every((t) => t.pitch == 0), isTrue);
      expect(plan.targets[11].pitch, greaterThan(0));
    });

    test('then up, zenith, down, nadir', () {
      expect(ringPitches(plan).map((p) => p.round()), [0, 46, 90, -46, -90]);
    });

    test('a session abandoned at any point has shot a contiguous prefix of '
        'the useful rings', () {
      // The order is only worth anything if quitting early is graceful, so
      // check the property that makes it so: the equator is complete before
      // anything else starts.
      var seenNonEquator = false;
      for (final target in plan.targets) {
        if (target.pitch != 0) seenNonEquator = true;
        if (seenNonEquator) {
          expect(
            target.pitch != 0 || target.ringIndex != 0,
            isTrue,
            reason: 'the equator ring was resumed after leaving it',
          );
        }
      }
    });

    test('every ring turns the same way — yaw always decreasing', () {
      for (final index in plan.ringIndices) {
        final ring = plan.targetsInRing(index);
        if (ring.first.isPole) continue;
        final step = 2 * math.pi / ring.length;
        for (var i = 1; i < ring.length; i++) {
          // Through wrapPi, per §7 pitfall 2. An unwrapped comparison would
          // report a 330° jump instead of a −33° step exactly once per ring —
          // at the ±180° meridian, which is also where the wrap seam lives, so
          // the two bugs would present as one.
          expect(
            MathUtils.wrapPi(ring[i].yaw - ring[i - 1].yaw),
            closeTo(-step, 1e-9),
            reason: 'ring $index reversed direction at shot $i',
          );
        }
      }
    });

    test('indexInRing counts in shooting order', () {
      for (final index in plan.ringIndices) {
        final ring = plan.targetsInRing(index);
        for (var i = 0; i < ring.length; i++) {
          expect(ring[i].indexInRing, i);
        }
      }
      for (var i = 0; i < plan.length; i++) {
        expect(plan.targets[i].index, i);
      }
    });

    test('each ring starts near where the previous one ended', () {
      double? previousEnd;
      for (final index in plan.ringIndices) {
        final ring = plan.targetsInRing(index);
        if (ring.first.isPole) continue;
        final step = 2 * math.pi / ring.length;
        if (previousEnd != null) {
          expect(
            MathUtils.wrapPi(ring.first.yaw - previousEnd).abs(),
            lessThanOrEqualTo(step / 2 + 1e-9),
            reason:
                'entering ring $index costs more than half a step of extra '
                'turning, so the user is being sent back across the room',
          );
        }
        previousEnd = ring.last.yaw;
      }
    });

    test('the first target is the heading the session started at', () {
      // Yaw 0 is where the user was already pointing (Math §1.1), so the first
      // shot asks them to do nothing at all.
      expect(plan.targets.first.yaw, 0);
      expect(plan.targets.first.pitch, 0);
    });

    test('ring labels are distinct and speakable', () {
      final labels = {for (final t in plan.targets) t.ringIndex: t.ringLabel};
      expect(labels.values.toSet(), hasLength(labels.length));
      expect(labels.values, contains('middle row'));
      expect(labels.values, contains('zenith'));
      expect(labels.values, contains('nadir'));
    });
  });

  group('the plan is derived, never hard-coded', () {
    test('a different field of view gives a different plan', () {
      // Architecture §2 defect 2: the old planner assumed 52° HFOV and 8 shots
      // per ring on every device. Real main-camera HFOV spans 46°–56°, and at
      // the ends of that range the ring structure genuinely differs.
      final narrow = builder.buildPlan(intrinsics: fourThree(46));
      final wide = builder.buildPlan(intrinsics: fourThree(56));
      expect(narrow.length, greaterThan(wide.length));
      expect(ringCounts(narrow).first, greaterThan(ringCounts(wide).first));
    });

    test('the yaw step widens with pitch by 1/cos φ', () {
      final plan = builder.buildPlan(intrinsics: fovIntrinsics(50, 69));
      final equator = plan.targetsInRing(0);
      final upper = plan.targetsInRing(1);
      final equatorStep = 2 * math.pi / equator.length;
      final upperStep = 2 * math.pi / upper.length;
      expect(upperStep, greaterThan(equatorStep));
      // 11 → 8 shots is the 1/cos(46.2°) = 1.44 widening, after re-dividing
      // evenly so the ring closes with no gap at the wrap.
      expect(upperStep / equatorStep, closeTo(11 / 8, 1e-12));
    });

    test('every ring divides the circle evenly, so nothing is left at the '
        'wrap', () {
      for (final device in fleet) {
        final plan = builder.buildPlan(
          intrinsics: device.intrinsics,
          captureNadir: true,
        );
        for (final index in plan.ringIndices) {
          final ring = plan.targetsInRing(index);
          if (ring.first.isPole) continue;
          final step = 2 * math.pi / ring.length;
          final closing = MathUtils.wrapPi(ring.first.yaw - ring.last.yaw);
          expect(
            closing,
            closeTo(-step, 1e-9),
            reason: '${device.name} ring $index leaves a gap at the wrap',
          );
        }
      }
    });
  });

  group('the validator is a proof, not a restatement of the arithmetic', () {
    test('it rasterises on a Fibonacci lattice, not a lat/lon grid', () {
      // The distinction is the whole reason the number can be believed: a
      // lat/lon grid at 1° puts as many samples in the last degree below the
      // zenith as across the entire equator, so a passing polar score can hide
      // an equatorial hole. Check the sampling is equal-area by counting how
      // many points land in the polar caps against how much area they hold.
      const validator = CoverageValidator();
      final plan = builder.buildPlan(intrinsics: fovIntrinsics(50, 69));
      final report = validator.validate(plan, plan.intrinsics);
      expect(report.latticePointCount, closeTo(40000, 1));

      // A single frustum's coverage must equal its solid angle, whatever the
      // pitch — which is exactly what a lat/lon grid gets wrong.
      double coveredBy(double pitch) {
        final target = CaptureTarget(
          index: 0,
          ringIndex: 0,
          indexInRing: 0,
          yaw: 0,
          pitch: pitch,
          ringLabel: 'probe',
        );
        return validator
            .validate(
              CapturePlan(
                targets: [target],
                intrinsics: plan.intrinsics,
                overlapFraction: 0.33,
                coverage: plan.coverage,
              ),
              plan.intrinsics,
            )
            .fractionCoveredAtLeastOnce;
      }

      final atEquator = coveredBy(0);
      final atPole = coveredBy(math.pi / 2);
      expect(
        atPole,
        closeTo(atEquator, 0.005),
        reason: 'one frame covers the same *area* wherever it is pointed; a '
            'lattice that disagrees is oversampling somewhere',
      );
    });

    test('coverage is measured against the eroded frame, as Phase 04 '
        'composites it', () {
      // §7 pitfall 1. Validating against the un-eroded rectangle certifies
      // coverage the compositor then discards, and the resulting hole is
      // invisible to every test because both halves look correct alone.
      final plan = builder.buildPlan(intrinsics: fovIntrinsics(50, 69));
      final eroded = const CoverageValidator().validate(plan, plan.intrinsics);
      final unEroded = const CoverageValidator(borderErosionFraction: 0)
          .validate(plan, plan.intrinsics);
      expect(
        unEroded.fractionCoveredAtLeastOnce,
        greaterThanOrEqualTo(eroded.fractionCoveredAtLeastOnce),
      );
      expect(
        unEroded.fractionCoveredAtLeastTwice,
        greaterThan(eroded.fractionCoveredAtLeastTwice),
        reason: 'if erosion changed nothing, it is not being applied',
      );
      expect(
        const CoverageValidator().borderErosionFraction,
        CoverageValidator.defaultBorderErosionFraction,
      );
    });

    test('the gap list stays bounded while the count stays exact', () {
      // A plan that skips the nadir leaves ~6% of 40 000 points uncovered by
      // design; recording every one would add ~150 KB to each station's
      // manifest to describe a hole the plan already declared.
      final plan = builder.buildPlan(intrinsics: fovIntrinsics(50, 69));
      expect(plan.coverage.gapCount, greaterThan(200));
      expect(plan.coverage.gaps.length, lessThanOrEqualTo(512));
      // The sample must still span the gap, not be truncated from the front.
      final pitches = plan.coverage.gaps.map((g) => g.pitch).toList();
      expect(pitches.every((p) => p < 0), isTrue, reason: 'nadir cap');
    });

    test('a plan whose frames all point one way fails S5a, not S5b', () {
      final intrinsics = fovIntrinsics(50, 69);
      final targets = [
        for (var i = 0; i < 3; i++)
          CaptureTarget(
            index: i,
            ringIndex: 0,
            indexInRing: i,
            yaw: i * 0.05,
            pitch: 0,
            ringLabel: 'middle row',
          ),
      ];
      final report = const CoverageValidator().validate(
        CapturePlan(
          targets: targets,
          intrinsics: intrinsics,
          overlapFraction: 0.33,
          coverage: const CoverageReport(
            fractionCoveredAtLeastOnce: 0,
            fractionCoveredAtLeastTwice: 0,
            gaps: [],
          ),
        ),
        intrinsics,
      );
      expect(report.fractionCoveredAtLeastOnce, lessThan(0.1));
      expect(report.minimumPairwiseOverlap, greaterThan(0.8));
      expect(report.isAcceptable, isFalse);
    });
  });
}
