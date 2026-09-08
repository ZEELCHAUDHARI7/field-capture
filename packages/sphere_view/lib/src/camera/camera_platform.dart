/// The camera capabilities the pipeline needs and no off-the-shelf plugin
/// exposes.
///
/// Architecture §5 lists four of them as flatly impossible from Dart —
/// bracketed hardware burst, real intrinsics, OS-level AE/AWB/AF hard lock, and
/// frame timestamps on the sensor clock — which is why this package owns its
/// camera plugin instead of depending on one. This file is the Dart side of
/// that boundary.
///
/// **Why this survived Pigeon.** Phase 06 §1 says to generate the interface
/// with Pigeon, and it is generated: `messages.g.dart` and its Kotlin and Swift
/// counterparts come out of `pigeons/camera_api.dart`. This file is not a
/// second copy of that; it is the *domain* interface sitting one layer above,
/// and [PigeonCameraPlatform] is the only thing that implements it against the
/// generated code. Three things depend on that layer existing:
///
/// * the generated Dart imports `package:flutter/services.dart`, and the whole
///   model layer is built so `tools/replay` — a plain `dart run` CLI with no
///   Flutter engine — can load it (architecture §6.6, `ImageSize`);
/// * the orchestration in Phase 08 can be tested against a fake camera instead
///   of a device, which is the same argument Phase 02 makes for the synthetic
///   rig;
/// * the wire types are flat records of what each platform said, while these
///   carry `CameraIntrinsics`, `Duration` and the rest of the model vocabulary,
///   so the seam between "what the platform reported" and "what the pipeline
///   believes" stays visible.
library;

import '../api/models/camera_intrinsics.dart';
import '../api/models/image_size.dart';

/// Which physical camera a descriptor refers to.
enum CameraFacing {
  /// The main rear camera. The only one this package plans for — iPads and
  /// most Android tablets have nothing else usable.
  back,

  /// Front camera. Listed for completeness; never used for capture.
  front,

  /// Any other reported camera, e.g. an external USB one.
  external,
}

/// How much control the platform actually granted, so the session can degrade
/// loudly instead of silently (architecture §8).
enum ExposureLockQuality {
  /// AE, AWB and AF are all hard-locked for the session. The intended state.
  fullyLocked,

  /// Locked, but the platform reserves the right to re-converge — gain
  /// compensation has more work to do.
  bestEffort,

  /// Could not lock. The panorama will band; this must reach the report.
  unlocked,
}

/// The device's thermal state, polled because a throttled stitch produces worse
/// output and the rule is never to do that silently (architecture §8).
enum ThermalState {
  /// Normal operation.
  nominal,

  /// Warm; capture is fine, a long stitch may slow.
  fair,

  /// Hot; the stitch should pause rather than produce degraded output.
  serious,

  /// Critical; capture must stop.
  critical,
}

/// How a bracket was actually produced.
///
/// Recorded rather than assumed because R3 found the answer is per-device and
/// undocumented: `MANUAL_SENSOR` presence on the Android fleet has no published
/// data at all, and iOS's `maxBracketedCapturePhotoCount` "may vary with
/// sessionPreset and activeFormat" with no per-device table. A session that
/// silently fell back would look like a session that worked.
enum BracketMode {
  /// The intended Android path: `captureBurst` with explicit
  /// `SENSOR_EXPOSURE_TIME` per request and AE off.
  manualExposureBurst,

  /// The intended iOS path: `AVCapturePhotoBracketSettings` built from
  /// manual exposure settings.
  photoBracket,

  /// No `MANUAL_SENSOR`: `CONTROL_AE_EXPOSURE_COMPENSATION` per request. **Not
  /// a true bracket** — AE is still deciding — and it must not be read as one.
  aeCompensationBurst,

  /// The hardware would not take the whole bracket at once, so the shots were
  /// fired one at a time with the exposure changed between them. Slower, and
  /// the frames are further apart in time, which matters for ghosting.
  sequentialManual,

  /// No usable exposure control. One frame at the metered lock, which is
  /// `ExposureStrategy.locked()` arrived at by hardware rather than by choice.
  singleShot,
}

/// Which clock the platform's frame timestamps came off, before conversion.
enum TimestampBase {
  /// Android `TIMESTAMP_SOURCE_REALTIME` — `elapsedRealtimeNanos()`, the same
  /// base as `SensorEvent.timestamp`. Directly comparable; offset is exactly
  /// zero and there is nothing to estimate.
  androidRealtime,

  /// Android `TIMESTAMP_SOURCE_UNKNOWN` — `System.nanoTime()`, which is *not*
  /// the sensor base. The offset is measured, and it has an uncertainty.
  androidMonotonicUnknown,

  /// iOS `CMClockGetHostTimeClock` (`mach_absolute_time`), against
  /// `CMDeviceMotion`'s `systemUptime`.
  iosHostTime,
}

/// How frame timestamps were mapped onto the one monotonic microsecond base
/// the pose stream also uses (§2.5, §3.5).
///
/// This is the highest-consequence number in the phase. A 10–50 ms mismatch is
/// 0.6–3° of rotation error at a realistic 60°/s pan — larger than everything
/// Phase 03 works to remove — and it presents as a stitcher bug rather than as
/// a clock bug. Recording the conversion is how that gets diagnosed instead of
/// chased.
class ClockSync {
  /// Creates a clock synchronisation record.
  const ClockSync({
    required this.base,
    required this.offsetUs,
    required this.uncertaintyUs,
    required this.note,
  });

  /// The clock the camera's raw timestamps are on.
  final TimestampBase base;

  /// Added to a raw camera timestamp to land on the motion clock. Exactly zero
  /// for [TimestampBase.androidRealtime], where the two *are* one clock.
  final int offsetUs;

  /// Half the spread of the estimator's samples. Zero when no estimation was
  /// needed. Phase 06's exit criterion is ±2 ms of stability over 60 s.
  final int uncertaintyUs;

  /// Plain-language description of what was done, for `bundle.json`.
  final String note;

  /// Whether the two clocks needed no reconciliation at all.
  bool get isExact => base == TimestampBase.androidRealtime;

  /// Serialises into the bundle's `device_info`.
  Map<String, Object?> toJson() => {
    'base': base.name,
    'offset_us': offsetUs,
    'uncertainty_us': uncertaintyUs,
    'note': note,
  };

  @override
  String toString() =>
      'ClockSync(${base.name}, offset $offsetUs µs ±$uncertaintyUs µs)';
}

/// One instantaneous re-measurement of the camera↔motion clock offset.
class ClockOffsetSample {
  /// Creates a sample.
  const ClockOffsetSample({
    required this.cameraClockUs,
    required this.motionClockUs,
    required this.offsetUs,
    required this.uncertaintyUs,
  });

  /// The camera clock's reading at the moment of sampling.
  final int cameraClockUs;

  /// The motion clock's reading at the same moment, as closely as a tight loop
  /// can manage.
  final int motionClockUs;

  /// `motionClockUs - cameraClockUs`, i.e. what must be added to a camera
  /// timestamp.
  final int offsetUs;

  /// The sampling loop's own spread, which bounds how much of any drift is
  /// real rather than measurement noise.
  final int uncertaintyUs;

  @override
  String toString() =>
      'ClockOffsetSample(offset $offsetUs µs ±$uncertaintyUs µs)';
}

/// One physical camera as reported by the platform.
class CameraDescriptor {
  /// Creates a descriptor.
  const CameraDescriptor({
    required this.id,
    required this.facing,
    required this.availableSizes,
    required this.focalLengthsMm,
    required this.supportsBracketing,
    required this.maxBracketCount,
    required this.hasDistortionModel,
    required this.hasManualSensor,
    required this.hardwareLevel,
    required this.isLogicalMultiCamera,
    this.excludedReason,
  });

  /// Platform-specific camera identifier.
  final String id;

  /// Which way it points.
  final CameraFacing facing;

  /// Still-capture sizes this camera offers.
  final List<ImageSize> availableSizes;

  /// Available focal lengths in mm. §2.1 selects the main camera as the one
  /// whose focal is **not** the shortest — the shortest is the ultra-wide.
  final List<double> focalLengthsMm;

  /// Whether a hardware exposure bracket is available. R3 found CameraX has no
  /// bracketing at all and `ExtensionMode.HDR` returns one pre-fused frame, so
  /// this is a real per-device question, not a formality.
  final bool supportsBracketing;

  /// How many frames one bracket may contain. Queried at runtime, never
  /// assumed to be 3 (R3 §4).
  final int maxBracketCount;

  /// Whether a lens distortion model can be obtained for this camera.
  final bool hasDistortionModel;

  /// Android `MANUAL_SENSOR` in `REQUEST_AVAILABLE_CAPABILITIES`. **This** is
  /// the gate for a real bracket, not [hardwareLevel] — R3 §8 is explicit that
  /// `LIMITED` devices may or may not have it. Always true on iOS, where the
  /// equivalent is `setExposureModeCustom` support.
  final bool hasManualSensor;

  /// Android `INFO_SUPPORTED_HARDWARE_LEVEL` as a string, or `unknown` on iOS.
  /// Recorded so the findings can show whether it ever disagrees with
  /// [hasManualSensor] on real fleet hardware.
  final String hardwareLevel;

  /// Whether this id is a logical multi-camera (Android) or virtual device
  /// (iOS). On iOS it is also the precondition for calibrated intrinsics.
  final bool isLogicalMultiCamera;

  /// Why camera selection skipped this one, when it did. §2.1 asks for the
  /// ultra-wide to be excluded *and logged*, since a future config may want it.
  final String? excludedReason;

  @override
  String toString() =>
      'CameraDescriptor($id, ${facing.name}, ${availableSizes.length} sizes, '
      'bracket: $supportsBracketing/$maxBracketCount'
      '${excludedReason == null ? '' : ', excluded: $excludedReason'})';
}

/// What Dart asks the platform to configure when opening.
class CaptureFormatSpec {
  /// Creates a format request.
  const CaptureFormatSpec({
    this.captureSize,
    this.preferFourThree = true,
    this.previewTargetWidth = 0,
    this.useDeferredJpegEncode = false,
    this.jpegQuality = 95,
    this.computeFrameStatistics = false,
  });

  /// `null` means "the largest available, subject to [preferFourThree]".
  final ImageSize? captureSize;

  /// Prefer 4:3. It matches the sensor's full active array so no crop factor
  /// enters the intrinsics, and it gives the largest vertical FOV, which
  /// directly reduces the number of rings (§2.1).
  final bool preferFourThree;

  /// Preview width to request, in the **sensor's** frame. `0` — the default —
  /// means "size it for this display", resolved by
  /// [SphereCaptureSession.resolvedPreviewWidth].
  ///
  /// This was a flat 1280, on the reasoning that the preview is only for aiming
  /// and a full-resolution one burns battery and thermal headroom the stitch will
  /// need (§4). The reasoning holds; the number did not. The buffer is landscape
  /// and the screen is portrait, so after the quarter turn the buffer's **width
  /// becomes the screen's height** — and it is cover-fitted, so that edge is what
  /// has to cover the long side of the display. 1280 against a 2622 px iPhone or a
  /// 2340 px Galaxy is a 2x upscale, which is exactly as soft as it sounds: the
  /// stitched panorama came out sharp while the viewfinder looked broken.
  ///
  /// A caller that genuinely wants a small preview can still ask for one; a
  /// non-zero value is passed through untouched.
  final int previewTargetWidth;

  /// Returns a copy with [previewTargetWidth] replaced.
  ///
  /// Exists for the one caller that resolves the `0` default against the display;
  /// everything else about a format request is decided before the session starts.
  CaptureFormatSpec copyWith({int? previewTargetWidth}) => CaptureFormatSpec(
    captureSize: captureSize,
    preferFourThree: preferFourThree,
    previewTargetWidth: previewTargetWidth ?? this.previewTargetWidth,
    useDeferredJpegEncode: useDeferredJpegEncode,
    jpegQuality: jpegQuality,
    computeFrameStatistics: computeFrameStatistics,
  );

  /// Android only: capture `YUV_420_888` and encode JPEG off the capture
  /// thread. R3 §9's evidence is that encoding, not readout, dominates
  /// per-frame latency, which makes this the cheapest way to bring a burst
  /// inside the 600 ms budget — much cheaper than dropping to a 2-shot bracket
  /// and far cheaper than abandoning HDR. Behind a flag so Spike C can A/B it.
  final bool useDeferredJpegEncode;

  /// JPEG quality for the written frames.
  final int jpegQuality;

  /// Compute a centre-crop mean RGB per frame. Off in production; on for the
  /// grey-card lock test (§6), which has to be a measurement and not an
  /// eyeball.
  final bool computeFrameStatistics;
}

/// The result of opening a camera: the intrinsics that every later stage is
/// only valid for, plus how they were arrived at.
class CameraOpenResult {
  /// Creates an open result.
  const CameraOpenResult({
    required this.intrinsics,
    required this.intrinsicsBranch,
    required this.intrinsicsNotes,
    required this.captureSize,
    required this.previewSize,
    required this.sensorOrientationDegrees,
    required this.previewRotationDegrees,
    required this.previewHandlesRotation,
    required this.clock,
    required this.bracketMode,
    required this.maxBracketCount,
    required this.captureAspectIsFourThree,
    this.warning,
  });

  /// Measured or derived intrinsics for [captureSize] (Math §4), in the
  /// capture stream's own — i.e. the sensor's — orientation.
  final CameraIntrinsics intrinsics;

  /// Which rung of the fallback chain produced them, e.g.
  /// `ios.videoFieldOfView`. Finer-grained than
  /// [CameraIntrinsics.source] because R2's quality gradient has three rungs
  /// and the enum has one value covering the top two.
  final String intrinsicsBranch;

  /// Everything the resolver noticed on the way down. Goes into the bundle.
  final List<String> intrinsicsNotes;

  /// The still size the session will actually capture at.
  final ImageSize captureSize;

  /// The preview size actually configured (§4).
  final ImageSize previewSize;

  /// Sensor mounting rotation, needed to reconcile the portrait lock with the
  /// sensor's native orientation.
  final int sensorOrientationDegrees;

  /// Clockwise degrees the **preview texture** still needs to stand upright on a
  /// portrait screen.
  ///
  /// Stated by the platform, not derived here, and that distinction is the fix for
  /// a bug it took four attempts to find. Deriving it needs to know whether the
  /// render path already applied the rotation, and on Android that is
  /// `SurfaceProducer.handlesCropAndRotation()` — `true` on the legacy texture
  /// path, `false` on the API 29+ `ImageReader` backend, and invisible from Dart.
  /// A derivation that read the sensor mounting and the frame shape correctly
  /// still turned an already-upright preview sideways.
  final int previewRotationDegrees;

  /// Whether the platform's render path handled the crop and rotation itself.
  ///
  /// The *reason* behind [previewRotationDegrees], carried separately because it is
  /// what makes a report from an unfamiliar device actionable, and recorded in the
  /// bundle so a capture explains its own preview.
  final bool previewHandlesRotation;

  /// Clockwise quarter turns for [previewRotationDegrees], `0..3`.
  int get previewQuarterTurns =>
      ((previewRotationDegrees % 360 + 360) % 360) ~/ 90 % 4;

  /// How camera timestamps were put on the motion clock.
  final ClockSync clock;

  /// The bracket path this device will actually take, known at open time so
  /// the plan can adapt rather than discover it at the first shutter.
  final BracketMode bracketMode;

  /// How many frames one bracket may contain here.
  final int maxBracketCount;

  /// False means a crop factor entered the intrinsics because no 4:3 output
  /// was available. Worth surfacing: it changes the derivation, and §2.1 is
  /// explicit that the largest JPEG size must not be assumed to be 4:3.
  final bool captureAspectIsFourThree;

  /// Any compromise made while opening. Never silently degrade (arch §8).
  final String? warning;

  /// The provenance block written into `bundle.json`'s `device_info`, so a
  /// replayed bundle can explain its own intrinsics years later.
  Map<String, Object?> toProvenanceJson() => {
    'intrinsics_branch': intrinsicsBranch,
    'intrinsics_source': intrinsics.source.name,
    'intrinsics_notes': intrinsicsNotes,
    'capture_size': captureSize.toJson(),
    'preview_size': previewSize.toJson(),
    'sensor_orientation_degrees': sensorOrientationDegrees,
    // Both, because together they explain the preview a capture was aimed with —
    // and a device whose preview came up sideways is diagnosed from the bundle
    // rather than from a photograph of a phone.
    'preview_rotation_degrees': previewRotationDegrees,
    'preview_handles_rotation': previewHandlesRotation,
    'capture_aspect_is_four_three': captureAspectIsFourThree,
    'bracket_mode': bracketMode.name,
    'max_bracket_count': maxBracketCount,
    'clock': clock.toJson(),
    'warning': warning,
  };

  @override
  String toString() =>
      'CameraOpenResult($captureSize, $intrinsicsBranch, '
      '${intrinsics.hfovDegrees.toStringAsFixed(1)}° HFOV, '
      '${bracketMode.name})';
}

/// Who made this device and what it is called.
///
/// Written into the output's EXIF `Make`/`Model` (Phase 11 §2), and into the
/// bundle's `device_info` so a replayed capture can still say what took it.
/// "Which tablet was this" is the first question when one station in a walk is
/// visibly worse than the rest, and it is not a question anybody can answer
/// from memory three months later.
class DeviceIdentity {
  /// Creates an identity.
  const DeviceIdentity({
    required this.make,
    required this.model,
    required this.osVersion,
  });

  /// What is written when the platform cannot say — a fake in a test, or a
  /// desktop replay where there is no device at all.
  ///
  /// Empty strings rather than a plausible-looking placeholder, because
  /// [isKnown] then has an honest answer and the EXIF writer can leave the
  /// fields out instead of stamping every replayed panorama "unknown/unknown"
  /// as though that were a measurement.
  static const DeviceIdentity unknown =
      DeviceIdentity(make: '', model: '', osVersion: '');

  /// Manufacturer: `Build.MANUFACTURER`, or `Apple`.
  final String make;

  /// Model: `Build.MODEL`, or the iOS hardware identifier (`iPad14,3`).
  final String model;

  /// OS release string.
  final String osVersion;

  /// Whether the platform gave a real answer.
  bool get isKnown => make.isNotEmpty || model.isNotEmpty;

  /// Goes into `bundle.json`'s `device_info`.
  Map<String, Object?> toJson() => {
    'make': make,
    'model': model,
    'os_version': osVersion,
  };

  @override
  bool operator ==(Object other) =>
      other is DeviceIdentity &&
      other.make == make &&
      other.model == model &&
      other.osVersion == osVersion;

  @override
  int get hashCode => Object.hash(make, model, osVersion);

  @override
  String toString() =>
      isKnown ? 'DeviceIdentity($make $model, $osVersion)' : 'DeviceIdentity(unknown)';
}

/// What the metering pre-sweep settled on, and how firmly.
class MeteringResult {
  /// Creates a metering result.
  const MeteringResult({
    required this.exposureTimeNs,
    required this.iso,
    required this.colorTemperatureK,
    required this.focusDistanceDiopters,
    required this.lockQuality,
    required this.sampleCount,
    required this.chosenEv,
    required this.meanEv,
    required this.percentile65Ev,
    required this.aeConverged,
    required this.pinnedProcessingModes,
    this.note,
  });

  /// The exposure time locked for the whole session.
  final int exposureTimeNs;

  /// The sensitivity locked for the whole session.
  final int iso;

  /// The white balance locked for the whole session.
  final int colorTemperatureK;

  /// The focus distance locked for the whole session, in diopters.
  final double focusDistanceDiopters;

  /// How much of that the platform actually honoured.
  final ExposureLockQuality lockQuality;

  /// How many frames the sweep observed. A sweep that saw four frames did not
  /// see the sphere, and its percentile means nothing — so this is reported
  /// rather than assumed adequate.
  final int sampleCount;

  /// The EV actually locked, relative to the sweep's median observation.
  final double chosenEv;

  /// Reported next to [percentile65Ev] so §2.3's decision is visible in the
  /// data and not only in the code: interiors are mostly mid-tone with a few
  /// very bright windows, the mean is dragged bright by the windows, and a
  /// mean-metered interior comes out crushed.
  final double meanEv;

  /// The ~65th percentile of the observed EV distribution — what gets locked.
  final double percentile65Ev;

  /// Whether AE actually converged before the lock was taken.
  final bool aeConverged;

  /// Whether `NOISE_REDUCTION` / `EDGE` / `TONEMAP` / `COLOR_CORRECTION` were
  /// pinned to fixed modes (§2.3 step 5). Easy to miss and load-bearing: an
  /// adaptive tonemap or noise reduction varies per frame and reintroduces
  /// precisely the photometric inconsistency the AE lock exists to remove.
  final bool pinnedProcessingModes;

  /// Anything compromised.
  final String? note;

  /// Serialised into the bundle so a replay knows what the frames were shot
  /// under.
  Map<String, Object?> toJson() => {
    'exposure_time_ns': exposureTimeNs,
    'iso': iso,
    'color_temperature_k': colorTemperatureK,
    'focus_distance_diopters': focusDistanceDiopters,
    'lock_quality': lockQuality.name,
    'sample_count': sampleCount,
    'chosen_ev': chosenEv,
    'mean_ev': meanEv,
    'percentile_65_ev': percentile65Ev,
    'ae_converged': aeConverged,
    'pinned_processing_modes': pinnedProcessingModes,
    'note': note,
  };

  @override
  String toString() =>
      'MeteringResult(${exposureTimeNs / 1e6}ms @ ISO $iso, '
      '${lockQuality.name}, p65 ${percentile65Ev.toStringAsFixed(2)} EV vs '
      'mean ${meanEv.toStringAsFixed(2)} EV)';
}

/// One frame returned by a bracketed capture.
class PlatformFrame {
  /// Creates a captured frame record.
  const PlatformFrame({
    required this.filePath,
    required this.evBias,
    required this.timestampUs,
    required this.byteCount,
    this.exposureTimeNs,
    this.iso,
    this.achievedEvBias,
    this.meanR,
    this.meanG,
    this.meanB,
    this.note,
  });

  /// Absolute path the platform wrote the JPEG to.
  final String filePath;

  /// The exposure bias in stops this frame was *requested* at.
  final double evBias;

  /// Shutter instant on the **motion clock** — already converted, at the
  /// plugin boundary, from whatever base the platform reports (§2.5, §3.5).
  final int timestampUs;

  /// Size of the written file.
  final int byteCount;

  /// Actual exposure time the sensor used.
  final int? exposureTimeNs;

  /// Actual sensitivity the sensor used.
  final int? iso;

  /// The bias actually achieved, computed from [exposureTimeNs] and [iso]
  /// rather than from the request. When a bracket comes back with two
  /// identical frames — the failure R3 warns about on devices without real
  /// bracketing — this is the only evidence of it.
  final double? achievedEvBias;

  /// Centre-crop channel means, present only when
  /// [CaptureFormatSpec.computeFrameStatistics] is set. These are the
  /// grey-card AE/AWB lock measurement of §6.
  final double? meanR;

  /// See [meanR].
  final double? meanG;

  /// See [meanR].
  final double? meanB;

  /// Anything unusual about this frame.
  final String? note;

  /// Rec. 601 luma of the centre crop, or `null` when statistics were not
  /// computed. The number the "< 1% luminance variation over 29 grey-card
  /// captures" criterion is measured on.
  double? get meanLuma => (meanR == null || meanG == null || meanB == null)
      ? null
      : 0.299 * meanR! + 0.587 * meanG! + 0.114 * meanB!;

  @override
  String toString() =>
      'PlatformFrame(${evBias >= 0 ? '+' : ''}$evBias EV, $timestampUs µs, '
      '$byteCount B)';
}

/// One bracket's frames, plus the timing the 600 ms budget is judged against.
class BracketCapture {
  /// Creates a bracket result.
  const BracketCapture({
    required this.frames,
    required this.burstWallClockMs,
    required this.shutterToShutterMs,
    required this.mode,
    required this.clampedExposure,
    required this.clampedIso,
    required this.deferredEncodeMs,
    this.note,
  });

  /// The frames, in request order.
  final List<PlatformFrame> frames;

  /// Trigger → last frame's **pixels in hand**, not `onCaptureCompleted`.
  /// Metadata routinely completes well before pixels are delivered, and pixels
  /// are what Phase 05 needs; timing the metadata gives a flattering, useless
  /// number (Spike C).
  final double burstWallClockMs;

  /// Shutter-to-shutter gaps from the sensor's own timestamps. Separates what
  /// the sensor sustains from what processing then costs — the distinction the
  /// JPEG-versus-YUV decision turns on (R3 §9).
  final List<double> shutterToShutterMs;

  /// How the bracket was actually produced.
  final BracketMode mode;

  /// Whether the requested exposure fell outside the sensor's range.
  final bool clampedExposure;

  /// Whether ISO clamped too, in which case the requested EV separation was
  /// **not achieved** and the bracket has less dynamic range than assumed.
  final bool clampedIso;

  /// What the deferred-encode path moved *off* the hot path. Not what it
  /// removed — the encode still happens, just while the user is walking to the
  /// next target.
  final double deferredEncodeMs;

  /// Anything compromised.
  final String? note;

  /// Whether every frame reached within 0.3 EV of its request — Spike C's
  /// acceptance criterion, checked against actuals rather than intent.
  bool get achievedRequestedSeparation => frames.every(
    (f) => f.achievedEvBias == null || (f.achievedEvBias! - f.evBias).abs() <= 0.3,
  );

  @override
  String toString() =>
      'BracketCapture(${frames.length} frames, '
      '${burstWallClockMs.toStringAsFixed(0)} ms, ${mode.name})';
}

/// The host-side camera interface.
///
/// Implemented for real by [PigeonCameraPlatform] over the generated channel,
/// and by fakes in tests.
abstract class SphereCameraPlatform {
  /// Enumerates the physical cameras and their capabilities.
  Future<List<CameraDescriptor>> listCameras();

  /// Opens [cameraId] with [format] and returns its intrinsics.
  Future<CameraOpenResult> open(String cameraId, CaptureFormatSpec format);

  /// Attaches a preview and returns the Flutter texture id to render.
  Future<int> attachPreview();

  /// Releases the preview texture without closing the camera.
  Future<void> detachPreview();

  /// Runs the metering pre-sweep for [duration], then hard-locks AE, AWB and
  /// AF for the rest of the session.
  Future<MeteringResult> meterAndLock(Duration duration);

  /// Releases the AE/AWB/AF lock.
  Future<void> unlock();

  /// Fires one bracket at [evBiases] into [outputDirectory], naming files with
  /// [namePrefix], and returns the frames in request order.
  Future<BracketCapture> captureBracket(
    List<double> evBiases, {
    required String outputDirectory,
    required String namePrefix,
  });

  /// Current thermal state.
  Future<ThermalState> thermalState();

  /// Re-measures the camera↔motion clock offset.
  Future<ClockOffsetSample> sampleClockOffset();

  /// Make, model and OS version, for the output's EXIF (Phase 11 §2).
  ///
  /// Concrete rather than abstract, unlike everything else here, and the
  /// default is [DeviceIdentity.unknown]: a desktop replay has no device to
  /// ask, and the honest answer there is to say so rather than to invent a
  /// plausible hardware name that then appears in a construction record.
  /// (An implementation using `implements` still has to supply it — Dart
  /// requires the full surface either way.)
  Future<DeviceIdentity> deviceIdentity() async => DeviceIdentity.unknown;

  /// The largest texture edge this GPU accepts, or 0 when the platform will
  /// not say (Phase 11 §3.1).
  ///
  /// Concrete, defaulting to 0, for the same reason as [deviceIdentity]. Zero
  /// is what makes the viewer fall back to its conservative 4096 floor
  /// (`TextureLimit.conservativeFloor`), which is the safe direction: assuming
  /// *less* than the GPU can do costs some sharpness, while assuming more costs
  /// the entire image.
  Future<int> maxTextureSize() async => 0;

  /// Total physical RAM in MB, for the memory-tier probe (architecture §6.5).
  Future<int> totalPhysicalMemoryMb();

  /// How much more memory this process may allocate, in MB, or `-1` where the
  /// platform will not say.
  ///
  /// The stitch's pre-flight check, not the tier decision — see
  /// [MemoryTier.probe] for why those are different questions and why the tier
  /// must come from *total* memory. Answered by `os_proc_available_memory()`
  /// on iOS, where a memory-pressure kill has no recoverable signal, and `-1`
  /// on Android, which has no honest per-process figure for native
  /// allocations.
  Future<int> availableProcessMemoryMb();

  /// Battery charge as a whole percentage, or `-1` where the platform will not
  /// say.
  ///
  /// Phase 12 §3: a site walk is up to thirty stations, each costing a 90 s
  /// capture and a 60 s stitch, so "how many stations does this tablet have in
  /// it" is a shipping question rather than a curiosity. Read twice around a run
  /// and divided, because the platforms quantise this to 1-5% and one station's
  /// drain is smaller than that.
  Future<int> batteryPercent();

  /// Closes the camera and releases the preview texture.
  Future<void> close();

  /// Frame-available notifications, stamped on the motion clock. Phase 07
  /// pairs these with the pose stream.
  Stream<int> get previewTimestamps;

  /// Thermal transitions as they happen (§5).
  Stream<ThermalState> get thermalStates;

  /// Asynchronous failures — a disconnect, a HAL error, a dropped burst.
  Stream<CameraPlatformError> get errors;

  /// Session interruptions: a phone call, another app, or split view on iPad,
  /// where a second app taking the camera is common (§7 pitfall 3).
  Stream<SessionInterruption> get interruptions;
}

/// An asynchronous camera failure, delivered outside any pending call.
class CameraPlatformError {
  /// Creates an error record.
  const CameraPlatformError(this.code, this.message);

  /// Stable machine-readable code.
  final String code;

  /// Human-readable detail.
  final String message;

  @override
  String toString() => 'CameraPlatformError($code): $message';
}

/// A session interruption or its end.
class SessionInterruption {
  /// Creates an interruption record.
  const SessionInterruption({required this.interrupted, required this.reason});

  /// `true` on interruption, `false` when the session resumes.
  final bool interrupted;

  /// Why, as the platform described it.
  final String reason;

  @override
  String toString() =>
      'SessionInterruption(${interrupted ? 'interrupted' : 'resumed'}: '
      '$reason)';
}
