import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'capture_fixtures.dart';
import 'pose_fixtures.dart';

/// Phase 12 §1 — the capability probe, over every capability set the fleet has.
///
/// The sets below are not hypothetical. Each is a device the matrix names:
/// a `LEGACY` rugged tablet with no `MANUAL_SENSOR`, a base iPad with no
/// calibrated intrinsics, a Galaxy Tab S with everything, and a phone with no
/// gyroscope at all. The last one is the only refusal, and it is the reason this
/// class exists rather than a `bool supportsHdr` somewhere in the session.
void main() {
  group('the probe answers for each device in the matrix', () {
    test('a full-stack tablet is `full` and brackets', () async {
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(
          cameras: [
            fullCapabilityCamera(id: 'rear'),
          ],
          totalMemoryMb: 8192,
          availableMemoryMb: 4096,
        ),
        poseSource: FakePoseSource(),
      );
      expect(report.capability, SphereCapability.full);
      expect(report.isSupported, isTrue);
      expect(report.supportsBracketing, isTrue);
      expect(report.tier, QualityTier.high);
      // A bracket asked for on a capable device is honoured.
      expect(
        report.exposureFor(const ExposureStrategy.bracket3()),
        isA<Bracket3Exposure>(),
      );
      // But a caller who asked for nothing in particular gets the documented
      // default, `auto`, not the most this device could manage. `configFrom` used
      // to overwrite it with `bracket3` on every capable tablet — which is the
      // configuration measured at S4 = 1.315 against a 1.03 target, so the
      // default that exists precisely to avoid that was unreachable on hardware.
      expect(
        report.configFrom(const SphereCaptureConfig()).exposure,
        isA<AutoExposure>(),
      );
      // Deliberately left null: `null` means "probe at stitch time", which is a
      // better measurement than this one. This probe reads *total* RAM at the
      // entry point; the stitch reads what is actually free when it runs, on a
      // device that has since been holding a camera and a hundred JPEGs. Stamping
      // the entry-point answer into the bundle would freeze the worse of the two.
      expect(
        report.configFrom(const SphereCaptureConfig()).qualityTier,
        isNull,
      );
      expect(report.warnings, isEmpty);
      expect(report.headline, 'Ready.');
    });

    test('a LEGACY camera is `noBracketing`, and falls back to locked', () async {
      // The device the phase doc says determines whether this ships. A `LEGACY`
      // camera has no `MANUAL_SENSOR`, so it cannot bracket — and R3 §8 is
      // explicit that the hardware level alone does not decide it, which is why
      // both flags are read.
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(
          cameras: [
            fullCapabilityCamera(
              id: 'rear',
              supportsBracketing: false,
              hasManualSensor: false,
              hardwareLevel: 'LEGACY',
              maxBracketCount: 1,
            ),
          ],
          totalMemoryMb: 3072,
          availableMemoryMb: -1,
        ),
        poseSource: FakePoseSource(),
      );
      expect(report.capability, SphereCapability.noBracketing);
      expect(report.isSupported, isTrue);
      // A bracket asked for here cannot be honoured, so it is downgraded rather
      // than accepted and silently returning one frame per position — which a
      // frame gate expecting three would reject at *every* position.
      final downgraded = report.exposureFor(const ExposureStrategy.bracket3());
      expect(downgraded, isA<LockedExposure>());
      expect(downgraded.shotsPerPosition, 1);
      expect(
        report.warnings.map((w) => w.code),
        contains(StitchWarningCode.bracketingUnavailable),
      );
      // And it says so in words, at the entry point, before the walk.
      expect(report.headline, contains('single-exposure only'));
    });

    test('a bracketing flag without MANUAL_SENSOR still means no bracket', () async {
      // R3 §8's trap, as its own case: the flag says yes and the capability that
      // actually delivers the exposures is absent. Believing the flag gives a
      // session that asks for three frames, receives one, and rejects every
      // position as an incomplete bracket — a device that captures nothing,
      // presenting as a device with no HDR.
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(
          cameras: [
            fullCapabilityCamera(
              id: 'rear',
              supportsBracketing: true,
              hasManualSensor: false,
              hardwareLevel: 'LIMITED',
            ),
          ],
          totalMemoryMb: 4096,
        ),
        poseSource: FakePoseSource(),
      );
      expect(report.capability, SphereCapability.noBracketing);
      expect(report.supportsBracketing, isFalse);
    });

    test('a bracket of two is not a bracket of three', () async {
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(
          cameras: [fullCapabilityCamera(id: 'rear', maxBracketCount: 2)],
          totalMemoryMb: 4096,
        ),
        poseSource: FakePoseSource(),
      );
      expect(report.capability, SphereCapability.noBracketing);
      expect(report.maxBracketCount, 2);
    });

    test('a base iPad is `noDistortionModel` and still captures', () async {
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(
          cameras: [
            fullCapabilityCamera(
              id: 'rear',
              hasDistortionModel: false,
              hardwareLevel: 'unknown',
              isLogicalMultiCamera: false,
            ),
          ],
          totalMemoryMb: 4096,
        ),
        poseSource: FakePoseSource(),
      );
      expect(report.capability, SphereCapability.noDistortionModel);
      expect(report.isSupported, isTrue);
      expect(
        report.exposureFor(const ExposureStrategy.bracket3()),
        isA<Bracket3Exposure>(),
      );
      expect(
        report.warnings.map((w) => w.code),
        contains(StitchWarningCode.noDistortionModel),
      );
    });

    test('no gyroscope is a refusal, with a reason that names the hardware', () async {
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(
          cameras: [fullCapabilityCamera(id: 'rear')],
          totalMemoryMb: 8192,
        ),
        poseSource: FakePoseSource(supportOverride: gyrolessPose),
      );
      expect(report.capability, SphereCapability.unsupportedNoGyro);
      expect(report.isSupported, isFalse);
      expect(report.blockingReason, isNotNull);
      // "Not supported" sends a manager back to the office; naming the missing
      // part sends them to a different tablet.
      expect(report.blockingReason, contains('gyroscope'));
      expect(report.headline, contains('gyroscope'));
    });

    test('the worst of two findings is the one reported, and both are kept',
        () async {
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(
          cameras: [
            fullCapabilityCamera(
              id: 'rear',
              supportsBracketing: false,
              hasManualSensor: false,
              hasDistortionModel: false,
              hardwareLevel: 'LEGACY',
              maxBracketCount: 1,
            ),
          ],
          totalMemoryMb: 2048,
        ),
        poseSource: FakePoseSource(),
      );
      // One verdict — the dynamic range, because it is visible in every window
      // rather than in the last pixel of a join…
      expect(report.capability, SphereCapability.noBracketing);
      // …and both facts still reach the user.
      expect(
        report.warnings.map((w) => w.code).toSet(),
        containsAll([
          StitchWarningCode.bracketingUnavailable,
          StitchWarningCode.noDistortionModel,
        ]),
      );
      // 2 GB is the `low` tier, which is the whole point of probing RAM here.
      expect(report.tier, QualityTier.low);
    });
  });

  group('the probe is safe to call at an entry point', () {
    test('a motion probe that throws refuses rather than propagating', () async {
      // A `probe` that threw would push every caller into a try/catch around
      // "may I show this button", and the natural way to write that is to show
      // the button and catch later — which is the mid-flow discovery the gate
      // exists to prevent.
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(
          cameras: [fullCapabilityCamera(id: 'rear')],
          totalMemoryMb: 8192,
        ),
        poseSource: FakePoseSource(throwOnSupport: true),
      );
      expect(report.capability, SphereCapability.unsupportedNoGyro);
      expect(report.blockingReason, contains('gyroscope'));
    });

    test('no usable rear camera refuses rather than throwing', () async {
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(cameras: const [], totalMemoryMb: 8192),
        poseSource: FakePoseSource(),
              nativeProbe: () => null,
      );
      expect(report.isSupported, isFalse);
      expect(report.blockingReason, contains('camera'));
    });

    test('a memory probe that fails degrades the tier and says so', () async {
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(
          cameras: [fullCapabilityCamera(id: 'rear')],
          throwOnMemory: true,
        ),
        poseSource: FakePoseSource(),
      );
      expect(report.tier, QualityTier.low);
      expect(
        report.warnings.map((w) => w.code),
        contains(StitchWarningCode.memoryProbeUnavailable),
      );
    });

    test('it opens no camera', () async {
      // The property that keeps the gate at the entry point rather than one
      // screen later: an entry-point check that costs a camera open is one
      // callers move, and a moved gate is no gate.
      final platform = FakeCameraPlatform(
        cameras: [fullCapabilityCamera(id: 'rear')],
        totalMemoryMb: 8192,
      );
      await SphereCapabilityProbe.probe(
        camera: platform,
        poseSource: FakePoseSource(),
              nativeProbe: () => null,
      );
      expect(platform.openCalls, 0);
      expect(platform.meteringCalls, 0);
    });
  });

  group('the report is readable months later', () {
    test('it serialises every fact the verdict was made from', () async {
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(
          cameras: [
            fullCapabilityCamera(
              id: 'rear-0',
              supportsBracketing: false,
              hasManualSensor: false,
              hardwareLevel: 'LEGACY',
              maxBracketCount: 1,
            ),
          ],
          totalMemoryMb: 3072,
        ),
        poseSource: FakePoseSource(),
      );
      final json = report.toJson();
      expect(json['capability'], 'noBracketing');
      expect(json['hardware_level'], 'LEGACY');
      expect(json['has_manual_sensor'], false);
      expect(json['camera_id'], 'rear-0');
      expect(json['total_physical_memory_mb'], 3072);
      expect(json['pose_support'], isA<Map<String, Object?>>());
      expect((json['warnings']! as List), isNotEmpty);
    });

    test('configFrom downgrades what it must and keeps what it can', () {
      const report = SphereCapabilityReport(
        capability: SphereCapability.noBracketing,
        tier: QualityTier.low,
        poseSupport: supportedPose,
        supportsBracketing: false,
        maxBracketCount: 1,
        hasDistortionModel: true,
        hasManualSensor: false,
        hardwareLevel: 'LEGACY',
        cameraId: 'rear',
        totalPhysicalMemoryMb: 3072,
        warnings: [],
      );
      // `auto` survives even here. This device cannot *bracket*, and `auto` does
      // not ask it to — one frame per position, metered per frame, which a LEGACY
      // camera does perfectly well. Forcing `locked` instead (the old behaviour)
      // bought the 2 s metering sweep and a hard AE lock that was measured not to
      // hold, in exchange for nothing.
      final config = report.configFrom(const SphereCaptureConfig());
      expect(config.exposure, isA<AutoExposure>());
      // Null, so the stitch probes. See the note above.
      expect(config.qualityTier, isNull);

      // What it must downgrade, it does.
      final asked = report.configFrom(
        const SphereCaptureConfig(exposure: ExposureStrategy.bracket3()),
      );
      expect(asked.exposure, isA<LockedExposure>());

      // And a tier the caller chose deliberately is not overwritten by the probe.
      final pinned = report.configFrom(
        const SphereCaptureConfig(qualityTier: QualityTier.high),
      );
      expect(pinned.qualityTier, QualityTier.high);
    });
  });
    test('refuses when the native stitcher will not load on this ABI', () async {
      // Capture would work perfectly and produce nothing: the library ships
      // arm64-v8a only, so an x86_64 emulator or a 32-bit tablet takes every
      // frame and fails at the far end, after ninety seconds and a walk to the
      // next station. Phase 12 §1 gates at the entry point for exactly this.
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(),
        poseSource: FakePoseSource(),
        nativeProbe: () => "dlopen failed: library 'libsphere_stitch.so' not found",
      );
      expect(report.capability, SphereCapability.unsupportedNoNativeLibrary);
      expect(report.isSupported, isFalse);
      expect(report.blockingReason, contains('libsphere_stitch.so'));
    });

    test('a loadable stitcher does not block the feature', () async {
      final report = await SphereCapabilityProbe.probe(
        camera: FakeCameraPlatform(),
        poseSource: FakePoseSource(),
        nativeProbe: () => null,
      );
      expect(report.capability, isNot(SphereCapability.unsupportedNoNativeLibrary));
      expect(report.isSupported, isTrue);
    });

}
