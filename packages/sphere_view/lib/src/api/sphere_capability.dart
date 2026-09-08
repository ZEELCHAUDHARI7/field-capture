import '../camera/camera_platform.dart';
import '../camera/camera_probe.dart';
import '../camera/pigeon_camera_platform.dart';
import '../stitch/memory_tier.dart';
import '../stitch/native_stitcher.dart';
import '../tracking/platform_ahrs_pose_source.dart';
import '../tracking/pose_frame_conversion.dart';
import '../tracking/pose_source.dart';
import 'models/sphere_capture_config.dart';
import 'models/stitch_warning.dart';

/// What this device can do with a 360 capture — the whole answer, in one value.
///
/// Phase 12 §1's rule is about *when* this is asked, not about what it returns:
/// gate at the **feature entry point**, not mid-flow. Discovering on site that a
/// tablet cannot do this is acceptable; discovering it after 25 captures is not,
/// and neither is discovering it at the stitch, an hour later, back in the site
/// office.
///
/// The values are ordered worst-first, so `SphereCapability.values.indexOf` is a
/// severity and [SphereCapabilityReport.capability] can be the single worst thing
/// found rather than a list a caller has to reduce itself.
enum SphereCapability {
  /// The native stitching library will not load on this device's ABI.
  ///
  /// **The feature must be hidden.** Capture would work perfectly and then
  /// produce nothing: `libsphere_stitch.so` ships `arm64-v8a` only, so on an
  /// `x86_64` emulator or a 32-bit `armeabi-v7a` tablet the frames are taken,
  /// the queue accepts the bundle, and the stitch fails at the far end — after
  /// the operator has spent ninety seconds and walked to the next station.
  ///
  /// Checked here rather than left to the stitch because this is precisely the
  /// mid-flow discovery Phase 12 §1 exists to prevent, and because the bundle it
  /// would leave behind is not wasted: build the library for that ABI and every
  /// bundle already on disk stitches.
  unsupportedNoNativeLibrary,

  /// No gyroscope. **The feature must be hidden**, not merely degraded.
  ///
  /// There is no useful reduced mode: without a gyroscope there is no attitude
  /// source that tracks a pan, so every frame would be seeded from accelerometer
  /// tilt with no heading at all. The panorama would not merely be worse, it
  /// would be wrong, and the operator would only find out after walking the
  /// building.
  unsupportedNoGyro,

  /// Works, with less dynamic range: no hardware exposure bracket, so capture
  /// falls back to `ExposureStrategy.locked()`.
  ///
  /// This is the fleet's low end — a `LEGACY` Android camera has no
  /// `MANUAL_SENSOR`, so it cannot bracket at all — and it is a real loss on a
  /// site interior with a window: one exposure cannot hold 12 EV. Recorded in
  /// the report so the missing dynamic range is never mistaken for a stitching
  /// fault.
  noBracketing,

  /// Works, with slightly worse geometry: the device publishes no lens
  /// distortion model, so bundle adjustment absorbs what it can and S1/S3 come
  /// out a little worse. Expected on single-lens iPads (R2).
  noDistortionModel,

  /// Everything is available.
  full;

  /// Whether the feature may be offered at all.
  bool get isSupported =>
      this != SphereCapability.unsupportedNoGyro &&
      this != SphereCapability.unsupportedNoNativeLibrary;

  /// Whether this is the worse of two.
  bool isWorseThan(SphereCapability other) => index < other.index;
}

/// The capability, the tier, and every fact the decision was made from.
///
/// A record rather than a bare [SphereCapability] for the reason architecture §8
/// gives: a compromise that is not visible is a compromise that gets blamed on
/// something else. A caller showing "HDR unavailable on this tablet" needs to
/// know *why* — no `MANUAL_SENSOR`, on a `LEGACY` camera — because that is the
/// sentence that stops a site team from concluding the app is broken.
class SphereCapabilityReport {
  /// Creates a report.
  const SphereCapabilityReport({
    required this.capability,
    required this.tier,
    required this.poseSupport,
    required this.supportsBracketing,
    required this.maxBracketCount,
    required this.hasDistortionModel,
    required this.hasManualSensor,
    required this.hardwareLevel,
    required this.cameraId,
    required this.totalPhysicalMemoryMb,
    required this.warnings,
    this.blockingReason,
  });

  /// The single worst thing found.
  final SphereCapability capability;

  /// The output size this device will produce, from [MemoryTier].
  final QualityTier tier;

  /// What the motion hardware can do, including the refusal reason.
  final PoseSupport poseSupport;

  /// Whether a hardware exposure bracket is available on the camera capture
  /// would use.
  final bool supportsBracketing;

  /// How many exposures one bracket may hold here. Never assumed to be 3 (R3).
  final int maxBracketCount;

  /// Whether a lens distortion model can be obtained.
  final bool hasDistortionModel;

  /// Android `MANUAL_SENSOR`. The real gate for a bracket rather than
  /// [hardwareLevel] — R3 §8 is explicit that `LIMITED` devices may or may not
  /// have it.
  final bool hasManualSensor;

  /// Android `INFO_SUPPORTED_HARDWARE_LEVEL`, or `unknown` on iOS.
  final String hardwareLevel;

  /// The camera capture would use, so a capability answer can be traced to the
  /// hardware it describes.
  final String cameraId;

  /// Total RAM as the platform reports it, which is what chose [tier].
  final int totalPhysicalMemoryMb;

  /// The compromises this device imposes, coded, ready to be carried into
  /// `StitchReport.warnings` and shown with everything else.
  ///
  /// Populated for the *degraded* capabilities, not for the refusal: a refusal is
  /// not a compromise to record against a panorama, because there will not be
  /// one.
  final List<StitchWarning> warnings;

  /// Why the feature cannot run at all, or `null` when it can.
  ///
  /// Plain language, and it names the hardware: "this tablet has no gyroscope"
  /// sends somebody to a different tablet, where "not supported" sends them back
  /// to the office.
  final String? blockingReason;

  /// Whether the feature may be offered.
  bool get isSupported => capability.isSupported;

  /// The one line to put in front of the user at the entry point.
  ///
  /// Deliberately short and deliberately not cheerful about a degraded device.
  /// The [warnings] are where the detail lives.
  String get headline => switch (capability) {
    SphereCapability.unsupportedNoGyro =>
      blockingReason ?? 'This device cannot capture a 360 panorama.',
    SphereCapability.unsupportedNoNativeLibrary =>
      blockingReason ?? 'This device cannot process a 360 panorama.',
    SphereCapability.noBracketing =>
      'Ready — single-exposure only on this tablet, so bright windows and deep '
          'shadows will lose detail.',
    SphereCapability.noDistortionModel =>
      'Ready — this tablet publishes no lens calibration, so joins will be '
          'very slightly less exact.',
    SphereCapability.full => 'Ready.',
  };

  /// The exposure strategy this device can actually honour.
  ///
  /// The point of returning it from the probe rather than leaving it to the
  /// session is that the *caller* configures the session, and a caller that
  /// asks for a 3-shot bracket on a `LEGACY` camera gets one frame per position
  /// — which a frame gate expecting three would reject at **every** position.
  /// That is a device that captures nothing at all, dressed as a device with no
  /// HDR.
  ///
  /// It answers "can this device do what was asked", which is why it takes the
  /// request. It used to be a getter that answered "what is the most this device
  /// can do", and [configFrom] applied it unconditionally — so every caller
  /// silently got `bracket3` on a capable tablet, which is the exact
  /// configuration measured at S4 = 1.315 against a 1.03 target, and the
  /// documented `auto` default was unreachable on real hardware.
  ExposureStrategy exposureFor(ExposureStrategy requested) => switch (requested) {
    Bracket3Exposure() when !(supportsBracketing && maxBracketCount >= 3) =>
      const ExposureStrategy.locked(),
    _ => requested,
  };

  /// The config to run a session with on this device.
  ///
  /// Only ever **downgrades**: what the caller asked for is honoured unless this
  /// device cannot honour it.
  ///
  /// The tier is deliberately *not* filled in. `qualityTier: null` means "probe
  /// at stitch time", and that is the better measurement — this probe reads
  /// **total** RAM at the entry point, while the stitch reads what is actually
  /// available at the moment it runs, minutes later, on a device that has since
  /// been holding a camera and a hundred JPEGs. Stamping [tier] here would freeze
  /// the worse of the two answers into the bundle. A caller that genuinely wants
  /// to force a tier still can, and it is then honoured all the way through.
  SphereCaptureConfig configFrom(SphereCaptureConfig base) =>
      base.copyWith(exposure: exposureFor(base.exposure));

  /// For `device_info`, the device matrix row, and a bug report.
  Map<String, Object?> toJson() => {
    'capability': capability.name,
    'tier': tier.name,
    'supports_bracketing': supportsBracketing,
    'max_bracket_count': maxBracketCount,
    'has_distortion_model': hasDistortionModel,
    'has_manual_sensor': hasManualSensor,
    'hardware_level': hardwareLevel,
    'camera_id': cameraId,
    'total_physical_memory_mb': totalPhysicalMemoryMb,
    'pose_support': poseSupport.toJson(),
    'blocking_reason': blockingReason,
    'warnings': [for (final warning in warnings) warning.toJson()],
  };

  @override
  String toString() =>
      'SphereCapabilityReport(${capability.name}, ${tier.name}, '
      'bracket ${supportsBracketing ? maxBracketCount : 'none'}, '
      'distortion $hasDistortionModel)';
}

/// Answers "can this device do this, and how well" before the feature is
/// offered.
///
/// Cheap on purpose. It reads the motion capabilities, the camera *descriptors*
/// and the total RAM — it does **not** open the camera, meter, or lock anything.
/// An entry-point gate that costs a camera open would either be slow enough that
/// callers move it later in the flow, which defeats it, or would fight with the
/// session's own open a moment later.
///
/// Everything it needs is on `CameraDescriptor`: `supportsBracketing`,
/// `hasDistortionModel`, `hasManualSensor` and `hardwareLevel` are all queried
/// from the platform's camera characteristics rather than from an open session,
/// which is exactly why Phase 06 put them there.
abstract final class SphereCapabilityProbe {
  /// Probes [camera] and [poseSource], defaulting to the real platform.
  ///
  /// The order is the point, and it is the same order [SphereCaptureSession.create]
  /// uses: motion first, because that is the only hard refusal and it costs one
  /// platform call; then memory, because the tier it chooses is what the caller
  /// will show; then the camera, which is the most expensive of the three.
  ///
  /// Never throws for an unsupported device. A probe that threw would push every
  /// caller into a `try`/`catch` around the question "may I show this button",
  /// and the natural way to write that is to show the button and catch later —
  /// which is the mid-flow discovery this exists to prevent.
  static Future<SphereCapabilityReport> probe({
    SphereCameraPlatform? camera,
    PoseSource? poseSource,
    String? Function()? nativeProbe,
  }) async {
    final platform = camera ?? PigeonCameraPlatform();
    final poses = poseSource ?? PlatformAhrsPoseSource();

    PoseSupport support;
    try {
      support = await poses.support;
    } on Object catch (error) {
      // A motion probe that fails is not the same as a device without a
      // gyroscope, but the safe reading is the same one: refuse. A capture that
      // proceeds on an unknown attitude source produces a panorama nobody can
      // trust, and the refusal is recoverable — the user tries another tablet —
      // where the bad panorama is not.
      support = PoseSupport(
        hasGyroscope: false,
        hasAccelerometer: false,
        hasFusedRotation: false,
        hasGravity: false,
        usesMagnetometer: false,
        // The Android frame is the arbitrary choice a refused device forces:
        // nothing will read it, and inventing an `unknown` value would put a
        // case into `PoseReferenceFrame` that the conversion in Math §2 has no
        // matrix for.
        frame: PoseReferenceFrame.androidGameRotationVector,
        minDelayUs: 0,
        detail: 'the motion capability probe failed: $error',
        unsupportedReason:
            'This device would not report whether it has a gyroscope, so a 360 '
            'capture cannot be started on it. A 360 needs one to track which '
            'way the tablet is pointing.',
      );
    }

    final tierProbe = await MemoryTier.probeDetailed(platform: platform);

    // Can the stitcher actually run here?
    //
    // Cheap — one `sv_version()` — and it belongs beside the other refusals
    // rather than at the end of the pipeline. `libsphere_stitch.so` is built for
    // `arm64-v8a` only, so on an `x86_64` emulator or a 32-bit tablet every
    // frame would be captured perfectly and the stitch would fail ninety seconds
    // later, which is the mid-flow discovery this whole probe exists to prevent.
    // Injectable so a test can exercise the refusal without an ABI to run it
    // on — and so the other capability tests do not silently depend on whether
    // the host happens to have run `tools/build_native.sh`.
    final String? nativeError = (nativeProbe ?? NativeStitcher.probeError)();
    if (nativeError != null) {
      return SphereCapabilityReport(
        capability: SphereCapability.unsupportedNoNativeLibrary,
        tier: tierProbe.tier,
        poseSupport: support,
        supportsBracketing: false,
        maxBracketCount: 1,
        hasDistortionModel: false,
        hasManualSensor: false,
        hardwareLevel: 'unknown',
        cameraId: '',
        totalPhysicalMemoryMb: tierProbe.totalPhysicalMemoryMb,
        warnings: const [],
        blockingReason:
            'This device cannot process a 360 panorama: the stitching library '
            'is not available for its processor. Captured frames would be kept '
            'but could not be turned into a sphere. ($nativeError)',
      );
    }

    // The camera is described, not opened. `selectCaptureCamera` is the same
    // selection the session will make, so the capability answer describes the
    // camera capture will actually use rather than the first one listed.
    CameraDescriptor? selected;
    String? cameraError;
    try {
      selected = (await CameraProbe(platform).selectCaptureCamera()).camera;
    } on Object catch (error) {
      cameraError = '$error';
    }

    final warnings = <StitchWarning>[
      if (tierProbe.warning != null) tierProbe.warning!,
    ];

    if (!support.isSupported) {
      return SphereCapabilityReport(
        capability: SphereCapability.unsupportedNoGyro,
        tier: tierProbe.tier,
        poseSupport: support,
        supportsBracketing: selected?.supportsBracketing ?? false,
        maxBracketCount: selected?.maxBracketCount ?? 1,
        hasDistortionModel: selected?.hasDistortionModel ?? false,
        hasManualSensor: selected?.hasManualSensor ?? false,
        hardwareLevel: selected?.hardwareLevel ?? 'unknown',
        cameraId: selected?.id ?? '',
        totalPhysicalMemoryMb: tierProbe.totalPhysicalMemoryMb,
        warnings: const [],
        blockingReason: support.unsupportedReason,
      );
    }

    if (selected == null) {
      // No usable rear camera is also a hard refusal, and it is not
      // `unsupportedNoGyro` — but the enum Phase 12 §1 specifies has no value
      // for it, and inventing one here would put a value in the public enum that
      // the doc's four-way gate does not know about. It is reported as the
      // refusal it is, with its own reason, and the capability stays the one the
      // doc defines: the feature is unavailable.
      return SphereCapabilityReport(
        capability: SphereCapability.unsupportedNoGyro,
        tier: tierProbe.tier,
        poseSupport: support,
        supportsBracketing: false,
        maxBracketCount: 1,
        hasDistortionModel: false,
        hasManualSensor: false,
        hardwareLevel: 'unknown',
        cameraId: '',
        totalPhysicalMemoryMb: tierProbe.totalPhysicalMemoryMb,
        warnings: const [],
        blockingReason:
            'This device has no usable rear camera, so a 360 capture cannot be '
            'started on it. ($cameraError)',
      );
    }

    // A bracket needs both the platform's own flag and `MANUAL_SENSOR`. R3 §8:
    // a `LIMITED` device may or may not have the latter, and without it a
    // three-exposure request comes back as one frame.
    final canBracket = selected.supportsBracketing &&
        selected.hasManualSensor &&
        selected.maxBracketCount >= 3;

    if (!canBracket) {
      warnings.add(
        StitchWarning(
          StitchWarningCode.bracketingUnavailable,
          data: {
            'hardware_level': selected.hardwareLevel,
            'max_bracket_count': selected.maxBracketCount,
            'has_manual_sensor': selected.hasManualSensor,
          },
          detail:
              'camera ${selected.id} reports hardware level '
              '${selected.hardwareLevel}, manual sensor '
              '${selected.hasManualSensor}, max bracket '
              '${selected.maxBracketCount}',
        ),
      );
    }
    if (!selected.hasDistortionModel) {
      warnings.add(
        StitchWarning(
          StitchWarningCode.noDistortionModel,
          data: {'intrinsics_source': 'unavailable at probe time'},
          detail:
              'camera ${selected.id} publishes no lens distortion model; '
              'registration will skip undistortion',
        ),
      );
    }

    // Worst-first, and only one: the enum is a single verdict by design, so a
    // device that can neither bracket nor publish a distortion model reports the
    // more consequential of the two — the dynamic range, which is visible in
    // every window in the panorama — while both facts stay readable on the report
    // and both warnings still reach the user.
    final capability = !canBracket
        ? SphereCapability.noBracketing
        : !selected.hasDistortionModel
        ? SphereCapability.noDistortionModel
        : SphereCapability.full;

    return SphereCapabilityReport(
      capability: capability,
      tier: tierProbe.tier,
      poseSupport: support,
      supportsBracketing: canBracket,
      maxBracketCount: selected.maxBracketCount,
      hasDistortionModel: selected.hasDistortionModel,
      hasManualSensor: selected.hasManualSensor,
      hardwareLevel: selected.hardwareLevel,
      cameraId: selected.id,
      totalPhysicalMemoryMb: tierProbe.totalPhysicalMemoryMb,
      warnings: warnings,
    );
  }
}
