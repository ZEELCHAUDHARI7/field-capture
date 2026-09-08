import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'fixtures.dart';

/// Phase 12 §2 and §5 — the failure UX, asserted rather than reviewed.
///
/// Three properties, and the third is the one that took the design work:
///
/// 1. **Every code has a sentence.** Cheap, because the message table is a
///    `switch` expression with no `default`: a code without a case fails
///    `dart analyze`, so this suite only has to prove the sentences are not
///    empty or degenerate.
/// 2. **Every sentence is worth reading.** "Stitching may be imperfect" teaches
///    nothing and reads as a shrug, so a sentence has to name what happened and
///    either what to do about it or who owns it. That is checked mechanically
///    below, and the check is deliberately awkward to satisfy by accident.
/// 3. **Every code the native library can emit is a code Dart knows.** This is
///    the one a normal test suite would miss. The two enums are in different
///    languages, built by different toolchains, and matched by string — so a
///    rename on the C++ side would compile, ship, and degrade every warning of
///    that kind into `unrecognised` on a device, which is precisely the silent
///    loss of a compromise that architecture §8 forbids. So this suite reads
///    `sv_warnings.h` and compares the sets.
void main() {
  group('every warning code has a message', () {
    test('none is empty, degenerate or unpunctuated', () {
      for (final code in StitchWarningCode.values) {
        final message = StitchWarning(
          code,
          data: _sampleData(code),
          detail: 'the technical detail the stage wrote',
        ).message;

        expect(
          message,
          isNotEmpty,
          reason: '${code.wireName} has no user-facing sentence',
        );
        // The escape hatch is exempt from the *length* rule and only from that
        // one: its sentence is whatever a newer native library wrote, so this
        // side cannot bound it. Its own fallback — what it says when there is no
        // detail either — is held to the same bar as everything else, below.
        if (code != StitchWarningCode.unrecognised) {
          expect(
            message.length,
            greaterThan(60),
            reason:
                '${code.wireName} is too short to say what happened and what to '
                'do: "$message"',
          );
        }
        expect(
          message.length,
          lessThan(600),
          reason:
              '${code.wireName} is longer than anyone reads on a tablet in the '
              'sun: "$message"',
        );
        if (code != StitchWarningCode.unrecognised) {
          expect(
            message.trim().endsWith('.'),
            isTrue,
            reason: '${code.wireName} is not a finished sentence: "$message"',
          );
        }
      }
    });

    test('the escape hatch says something even with nothing to carry', () {
      const bare = StitchWarning(StitchWarningCode.unrecognised);
      expect(bare.message.length, greaterThan(60));
      expect(bare.message, contains('report'));
      expect(bare.message, contains('unaffected'));
    });

    test('none leaks an unresolved value into the sentence', () {
      // The failure this catches: a message reading `data['frames']` where the
      // site that raised it wrote `frame_count`. The fallback makes that a
      // plausible-looking "0 of 0 photos" rather than an error, so the only way
      // to see it is to render every message against the data its code declares
      // and look for the tell.
      for (final code in StitchWarningCode.values) {
        final message = StitchWarning(
          code,
          data: _sampleData(code),
          detail: 'detail',
        ).message;
        for (final tell in ['null', 'NaN', 'Infinity', '  ', '0x0', ' 0 of 0']) {
          expect(
            message,
            isNot(contains(tell)),
            reason:
                '${code.wireName} rendered "$tell", which means its message '
                'and the site that raises it disagree about a data key: '
                '"$message"',
          );
        }
      }
    });

    test('every sentence names a cause and an action, or says who owns it', () {
      // Not a style rule. A manager who is told only that something is wrong
      // has three options — re-shoot the station, ignore it, or stop trusting
      // the feature — and the sentence is the only thing that tells them which.
      // Where there is genuinely nothing they can do, saying so explicitly is
      // the honest answer and is accepted here; what is not accepted is a
      // sentence that leaves them to guess.
      const actionable = [
        // something the operator can do differently
        're-shoot', 'Re-shoot', 're-shooting', 'Re-shooting', 'Resuming',
        'standing', 'Standing', 'Stand still', 'stand', 'pivot', 'Pausing',
        'Holding', 'holding', 'Closing other apps', 'Completing every',
        'completing every', 'finishing the prompts', 'Including a corner',
        'shoot from', 'step back', 'Capturing from', 'Re-saving',
        'complete the ring', 'Out of direct sun',
        // or an explicit statement of who owns it
        'one for the developers', 'One for the developers', 'worth reporting',
        'Worth reporting', 'No action needed', 'nothing to do about it',
        'Nothing to do differently', 'needs re-shooting', 'is the only fix',
        'unaffected', 'Please report', 'please report',
        'It will carry on by', 're-stitching', 'leaving the lighting alone',
      ];
      // Collected rather than asserted one at a time: this check is a copy
      // review, and a reviewer wants the whole list of gaps rather than the first
      // one and another test run.
      final silent = <String>[];
      for (final code in StitchWarningCode.values) {
        // The escape hatch's sentence is whatever a newer native library wrote.
        // This side cannot make it actionable, and rewriting it would throw away
        // the only description of a warning it does not understand. Its own
        // fallback — tested separately above — does name who owns it.
        if (code == StitchWarningCode.unrecognised) continue;
        final message = StitchWarning(
          code,
          data: _sampleData(code),
          detail: 'detail',
        ).message;
        if (!actionable.any(message.contains)) {
          silent.add('${code.wireName}: "$message"');
        }
      }
      expect(
        silent,
        isEmpty,
        reason:
            'these tell the user something is wrong without telling them what '
            'to do or who owns it:\n  ${silent.join('\n  ')}',
      );
    });

    test('no sentence is one of the shrugs this table exists to replace', () {
      const shrugs = [
        'may be imperfect',
        'something went wrong',
        'an error occurred',
        'unknown error',
        'try again later',
        'unexpected',
      ];
      for (final code in StitchWarningCode.values) {
        final message = StitchWarning(code, data: _sampleData(code)).message;
        for (final shrug in shrugs) {
          expect(
            message.toLowerCase(),
            isNot(contains(shrug)),
            reason: '${code.wireName} is a shrug: "$message"',
          );
        }
      }
    });
  });

  group('the native enum and the Dart enum are the same set', () {
    // Read rather than duplicated. A list of expected names written here would
    // be a third copy, and the third copy is the one that goes stale.
    final header = File('src/sphere_stitch/sv_warnings.h');
    final source = File('src/sphere_stitch/sv_warnings.cpp');

    test('the header and its name table are both readable', () {
      expect(
        header.existsSync() && source.existsSync(),
        isTrue,
        reason:
            'this test is the only thing checking the two enums agree; if the '
            'files moved, point it at them rather than deleting it',
      );
    });

    test('every wire name the native side can emit exists in Dart', () {
      final names = _nativeWireNames(source.readAsStringSync());
      expect(
        names.length,
        greaterThan(20),
        reason:
            'parsed only ${names.length} names out of svWarningCodeName, which '
            'means the parse is wrong rather than the enum being small',
      );
      final known = {
        for (final code in StitchWarningCode.values) code.wireName,
      };
      for (final name in names) {
        expect(
          known,
          contains(name),
          reason:
              'the native library emits "$name" and no Dart code matches it, so '
              'every warning of that kind reaches a user as `unrecognised`',
        );
      }
    });

    test('no native code maps to the unrecognised escape hatch', () {
      final names = _nativeWireNames(source.readAsStringSync());
      for (final name in names) {
        expect(
          StitchWarningCode.fromWireName(name),
          isNot(StitchWarningCode.unrecognised),
          reason: '"$name" falls through to the escape hatch',
        );
      }
      // And the escape hatch's own name is not something C++ can produce, so a
      // warning can never *deliberately* arrive uncoded.
      expect(names, isNot(contains(StitchWarningCode.unrecognised.wireName)));
    });

    test('the enum declarations in the header match the name table', () {
      // `-Werror=switch` guarantees a declared code has a `case`, but not that
      // the `case` returns a distinct name — two codes returning the same string
      // would compile and would make one of them unreachable from Dart.
      final declared = RegExp(r'^\s*k([A-Z][A-Za-z0-9]*),\s*$', multiLine: true)
          .allMatches(header.readAsStringSync())
          .map((m) => m.group(1)!)
          .toList();
      final names = _nativeWireNames(source.readAsStringSync());
      expect(
        names.length,
        declared.length,
        reason:
            'the header declares ${declared.length} codes and the name table '
            'returns ${names.length} distinct names',
      );
      expect(names.toSet().length, names.length, reason: 'duplicate wire names');
    });
  });

  group('warnings survive the ABI', () {
    test('a coded warning round-trips through the report JSON', () {
      const warning = StitchWarning(
        StitchWarningCode.imuOnlyFrames,
        data: {'frames': 3, 'total': 29, 'min_inliers': 25},
        detail: 'three frames fell back',
      );
      final report = sampleReport.copyWithWarnings(const [warning]);
      final decoded = StitchReport.fromJson(
        jsonDecode(jsonEncode(report.toJson())) as Map<String, Object?>,
      );
      expect(decoded.warnings, [warning]);
      expect(decoded.warnings.single.message, contains('3 of 29 photos'));
    });

    test('a pre-Phase-12 bare string still loads, and still says something', () {
      // Committed bundles and baselines hold reports whose warnings are plain
      // sentences. Refusing to parse them would make a fixture unreadable;
      // dropping them would hide a compromise. So they arrive as
      // `unrecognised` carrying their own sentence — which is exactly what they
      // are: a warning whose cause was never recorded machine-readably.
      final legacy = {
        ...sampleReport.toJson(),
        'warnings': ['Nadir was not captured; the pole was filled.'],
      };
      final decoded = StitchReport.fromJson(legacy);
      expect(decoded.warnings.single.code, StitchWarningCode.unrecognised);
      expect(
        decoded.warnings.single.message,
        'Nadir was not captured; the pole was filled.',
      );
    });

    test('an unknown code keeps the native detail rather than vanishing', () {
      final future = {
        ...sampleReport.toJson(),
        'warnings': [
          {
            'code': 'a_code_from_a_newer_native_library',
            'detail': 'the newer library explained itself in English',
            'data': {'something': 1},
          },
        ],
      };
      final decoded = StitchReport.fromJson(future);
      expect(decoded.warnings.single.code, StitchWarningCode.unrecognised);
      expect(
        decoded.warnings.single.message,
        'the newer library explained itself in English',
      );
    });
  });

  group('the report turns its own numbers into coded warnings', () {
    test('a report that misses S1, S2, S4, S5 and tilt says so, five times', () {
      final report = StitchReport(
        rmsReprojectionErrorPx: 5.4,
        loopClosureErrorDegrees: 0.9,
        maxGainRatio: 1.12,
        coverageFraction: 0.94,
        refinedFocalPx: 3200,
        refinedIntrinsics: sampleIntrinsics,
        residualTiltDegrees: 1.4,
        droppedPositionIndices: const [3, 8, 19],
        warnings: const [],
        elapsedMs: 42000,
        tierUsed: QualityTier.mid,
      );
      final codes = CaptureWarnings.criteriaWarnings(
        report,
      ).map((w) => w.code).toSet();
      expect(codes, {
        StitchWarningCode.positionsDropped,
        StitchWarningCode.coverageIncomplete,
        StitchWarningCode.reprojectionAboveTarget,
        StitchWarningCode.loopClosureAboveTarget,
        StitchWarningCode.gainRatioAboveTarget,
        StitchWarningCode.residualTiltAboveTarget,
      });
    });

    test('a report that meets every criterion says nothing', () {
      final perfect = StitchReport(
        rmsReprojectionErrorPx: 0.4,
        loopClosureErrorDegrees: 0.1,
        maxGainRatio: 1.01,
        coverageFraction: 1.0,
        refinedFocalPx: 3200,
        refinedIntrinsics: sampleIntrinsics,
        residualTiltDegrees: 0.05,
        droppedPositionIndices: const [],
        warnings: const [],
        elapsedMs: 30000,
        tierUsed: QualityTier.mid,
      );
      expect(perfect.meetsQualityTargets, isTrue);
      expect(CaptureWarnings.criteriaWarnings(perfect), isEmpty);
      expect(CaptureWarnings.forReport(perfect), isEmpty);
    });
  });
}

/// The wire names `svWarningCodeName` can return, in declaration order.
///
/// Parsed out of the `switch` rather than out of the enum, because the name is
/// what crosses the boundary — a code whose `case` returns the wrong string is
/// invisible in the enum declaration and fatal at the boundary.
List<String> _nativeWireNames(String source) => RegExp(
  r'case SvWarningCode::k[A-Za-z0-9]+:\s*\n?\s*return "([a-z0-9_]+)";',
).allMatches(source).map((m) => m.group(1)!).toList();

/// Representative data for [code], as the site that raises it writes it.
///
/// An exhaustive `switch`, so adding a code forces its author to state what data
/// its sentence needs — which is the only way the "no unresolved value" test
/// above can mean anything.
Map<String, Object?> _sampleData(StitchWarningCode code) => switch (code) {
  StitchWarningCode.framesDownscaled => const {
    'oversampling': 3.55,
    'decode_reduction': 1,
    'decoded_width': 1512,
    'output_width': 6144,
  },
  StitchWarningCode.bracketRefused => const {
    'position': 7,
    'reason': 'The estimated shift of 41 px exceeds the 1.5% limit',
  },
  StitchWarningCode.bracketCompromised => const {
    'position': 12,
    'reason': 'One exposure was dropped, so two of three were fused',
  },
  StitchWarningCode.bracketsRejected => const {
    'rejected': 3,
    'positions': 29,
  },
  StitchWarningCode.exposureMetadataDisagrees => const {'stops': 1.4},
  StitchWarningCode.noDistortionModel => const {
    'intrinsics_source': 'derivedFromPhysics',
  },
  StitchWarningCode.distortionLutUnfittable => const {},
  StitchWarningCode.distortionEstimated => const {'k1': -0.09},
  StitchWarningCode.weakIntrinsics => const {
    'intrinsics_source': 'exifFallback',
  },
  StitchWarningCode.imuOnlyFrames => const {
    'frames': 3,
    'total': 29,
    'min_inliers': 25,
  },
  StitchWarningCode.mostlyImuOnly => const {'fraction': 0.74},
  StitchWarningCode.nothingRegistered => const {},
  StitchWarningCode.matchGraphSplit => const {'components': 2},
  StitchWarningCode.bundleAdjustmentPartialFailure => const {'frames': 6},
  StitchWarningCode.bundleAdjustmentFailed => const {},
  StitchWarningCode.imuOnlyDominatesResidual => const {
    'rms_all_px': 9.03,
    'rms_registered_px': 1.4,
    'imu_only_frames': 4,
    'registered_frames': 25,
  },
  StitchWarningCode.inconsistentInliersDiscarded => const {'fraction': 0.18},
  StitchWarningCode.frameWarpedOffCanvas => const {},
  StitchWarningCode.wrapPadUnreached => const {},
  StitchWarningCode.gainCompensationFailed => const {},
  StitchWarningCode.gainRatioTooLarge => const {'max_gain_ratio': 1.84},
  StitchWarningCode.seamFindingFailed => const {},
  StitchWarningCode.stripBlendMismatch => const {
    'levels': 4,
    'strip_pad_px': 128,
    'bands': 5,
  },
  StitchWarningCode.focalRefinementRejected => const {
    'seed_focal_px': 3045.0,
    'max_ratio': 1.20,
  },
  StitchWarningCode.solutionCollapsed => const {
    'solved_spread_degrees': 41.0,
    'measured_spread_degrees': 172.0,
  },
  StitchWarningCode.nothingCovered => const {},
  StitchWarningCode.previewNotWritten => const {},
  StitchWarningCode.debugMapNotWritten => const {},
  StitchWarningCode.planCannotRegister => const {
    'minimum_pairwise_overlap': 0.15,
    'fraction_covered_once': 0.92,
  },
  StitchWarningCode.registrationOnlyRun => const {},
  StitchWarningCode.reprojectionAboveTarget => const {
    'rms_px': 5.4,
    'target_px': 1.0,
  },
  StitchWarningCode.loopClosureAboveTarget => const {
    'degrees': 0.9,
    'target_degrees': 0.25,
  },
  StitchWarningCode.gainRatioAboveTarget => const {
    'max_gain_ratio': 1.12,
    'target': 1.03,
  },
  StitchWarningCode.residualTiltAboveTarget => const {
    'degrees': 1.4,
    'target_degrees': 0.2,
  },
  StitchWarningCode.coverageIncomplete => const {'fraction': 0.94},
  StitchWarningCode.positionsDropped => const {'count': 3},
  StitchWarningCode.tierDowngradedBeforeStart => const {
    'width': 4096,
    'height': 2048,
    'requested_width': 6144,
    'requested_height': 3072,
    'total_mb': 4096,
    'available_mb': 310,
    'estimated_peak_mb': 400,
  },
  StitchWarningCode.tierDowngradedAfterOom => const {
    'width': 4096,
    'height': 2048,
    'requested_width': 6144,
    'requested_height': 3072,
  },
  StitchWarningCode.memoryProbeUnavailable => const {},
  StitchWarningCode.metadataNotWritten => const {},
  StitchWarningCode.headingFromMagnetometer => const {'degrees': 214.0},
  StitchWarningCode.thermalPause => const {'state': 'serious'},
  StitchWarningCode.bracketingUnavailable => const {'mode': 'singleShot'},
  StitchWarningCode.positionsNotCaptured => const {
    'missing': 11,
    'planned': 29,
  },
  StitchWarningCode.unrecognised => const {},
};
