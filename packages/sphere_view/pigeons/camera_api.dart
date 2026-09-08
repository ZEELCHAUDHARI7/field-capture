// The camera platform interface, in Pigeon.
//
// Pigeon rather than a hand-written `MethodChannel`: this boundary carries
// ~40 fields across two platforms, and a mistyped string key on one of them is
// a silent failure that shows up three phases later as a stitcher bug. The
// generator makes the two halves fail to *compile* instead.
//
// One design decision is load-bearing and worth stating here, because it is
// what the shape of these classes is for:
//
//   **The native side reports raw platform facts. Dart decides.**
//
// The intrinsics fallback chains (Math §4.1 for Android, §4.2 for iOS) are not
// implemented in Kotlin and Swift. They are implemented once, in
// `lib/src/camera/intrinsics_resolver.dart`, over `AndroidIntrinsicFacts` and
// `IosIntrinsicFacts` below. Three reasons:
//
//   1. Phase 06 §6 requires a *unit* test that "the intrinsics fallback chain
//      picks the right branch for each synthetic capability set". A chain that
//      lives in Kotlin and Swift can only be tested on two devices; a chain in
//      Dart is tested on a laptop, exhaustively, including the branches our
//      fleet will never take.
//   2. `android/README.md` already says it: the R2 coefficient reorder exists
//      in Dart as `BrownConradyDistortion.fromAndroidLensDistortion` — "do not
//      write a second copy in Kotlin". The same argument applies to the whole
//      derivation.
//   3. Two implementations of one formula drift. This one decides the focal
//      length, and a 4% focal error means the panorama does not close.
//
// So Kotlin reads `CameraCharacteristics` and Swift reads `AVCaptureDevice`,
// and neither computes an `fx`.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/camera/messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/src/main/kotlin/com/asite/sphereview/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.asite.sphereview'),
    swiftOut: 'ios/Classes/Messages.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'sphere_view',
  ),
)
// ---------------------------------------------------------------- enums --

/// Which way a physical camera points.
enum PlatformCameraFacing { back, front, external }

/// The device thermal state, normalised across the two platforms'
/// differently-grained scales.
enum PlatformThermalState { nominal, fair, serious, critical }

/// How much of the AE/AWB/AF lock the platform actually granted.
enum PlatformLockQuality { fullyLocked, bestEffort, unlocked }

/// Which clock a frame timestamp is expressed on *before* the plugin converts
/// it (§2.5, §3.5). Recorded rather than assumed, because the conversion is
/// different for each and getting it wrong is a silent 10–50 ms pose error.
enum PlatformTimestampBase {
  /// Android `SENSOR_INFO_TIMESTAMP_SOURCE == REALTIME`:
  /// `SystemClock.elapsedRealtimeNanos()`, the same base as
  /// `SensorEvent.timestamp`. Directly comparable, offset exactly zero.
  androidRealtime,

  /// Android `SENSOR_INFO_TIMESTAMP_SOURCE == UNKNOWN`: `System.nanoTime()`,
  /// which is *not* the sensor base. An offset must be estimated.
  androidMonotonicUnknown,

  /// iOS `CMClockGetHostTimeClock` (`mach_absolute_time`). `CMDeviceMotion`
  /// reports `systemUptime`; the plugin measures the offset rather than
  /// assuming the two are identical.
  iosHostTime,
}

/// What the burst actually asks the sensor for.
enum PlatformCaptureFormat {
  /// Direct JPEG burst. The straightforward path.
  jpeg,

  /// `YUV_420_888` burst with the JPEG encode deferred off the capture
  /// thread. R3 §9 found evidence (Nexus 5: ~243 ms JPEG stall vs ~0 ms YUV)
  /// that encoding, not sensor readout, dominates per-frame latency — so this
  /// is the cheapest way to recover a burst that misses the 600 ms budget,
  /// far cheaper than abandoning HDR. Android only.
  yuvDeferredJpeg,
}

/// How the bracket was actually produced, so a degraded path is recorded
/// rather than mistaken for the real thing (architecture §8).
enum PlatformBracketMode {
  /// The intended path: explicit per-request exposure time with AE off.
  manualExposureBurst,

  /// No `MANUAL_SENSOR`: `CONTROL_AE_EXPOSURE_COMPENSATION` per request. Not a
  /// true bracket — AE is still deciding — and it must not be read as one.
  aeCompensationBurst,

  /// iOS `AVCapturePhotoBracketSettings` with manual exposure settings.
  photoBracket,

  /// `maxBracketedCapturePhotoCount` came back below the requested count:
  /// sequential single shots with the exposure changed between them. Slower,
  /// and the frames are further apart in time.
  sequentialManual,

  /// No usable exposure control at all. One frame at the metered lock.
  singleShot,
}

/// Android `INFO_SUPPORTED_HARDWARE_LEVEL`. Recorded but **not** gated on —
/// R3 §8 is explicit that the gate is `MANUAL_SENSOR` in
/// `REQUEST_AVAILABLE_CAPABILITIES`, because `LIMITED` devices may or may not
/// have it. Both are reported so the findings can show whether the two ever
/// disagree on real fleet hardware.
enum PlatformHardwareLevel { legacy, limited, full, level3, external, unknown }

// -------------------------------------------------------------- classes --

/// Pixel dimensions. Not `dart:ui.Size` — see `ImageSize`, which this maps to.
class PlatformSize {
  PlatformSize({required this.width, required this.height});
  final int width;
  final int height;
}

/// A rectangle in sensor-array coordinates, `[left, top, width, height]`.
class PlatformRect {
  PlatformRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
  final int left;
  final int top;
  final int width;
  final int height;
}

/// One physical camera, with enough capability detail for Dart to choose.
class CameraDescriptor {
  CameraDescriptor({
    required this.id,
    required this.facing,
    required this.availableSizes,
    required this.focalLengthsMm,
    required this.supportsBracketing,
    required this.maxBracketCount,
    required this.hasDistortionModel,
    required this.hardwareLevel,
    required this.hasManualSensor,
    required this.isLogicalMultiCamera,
    this.excludedReason,
  });

  final String id;
  final PlatformCameraFacing facing;

  /// Still-capture sizes offered, largest first.
  final List<PlatformSize> availableSizes;

  /// `LENS_INFO_AVAILABLE_FOCAL_LENGTHS` on Android; the single lens focal on
  /// iOS where derivable. Used to exclude the ultra-wide: §2.1 picks the
  /// camera whose focal is *not* the shortest.
  final List<double> focalLengthsMm;

  /// Whether a real per-frame-controlled bracket is available.
  final bool supportsBracketing;

  /// iOS `maxBracketedCapturePhotoCount`, queried at runtime after the format
  /// is set — R3 §4: it is not a fixed number and has no published per-device
  /// table. On Android this is the burst length the session will accept.
  final int maxBracketCount;

  /// Whether a lens distortion model can be obtained. Frequently false: R2
  /// found `LENS_DISTORTION` null even on Pixel hardware, and iOS only has a
  /// LUT on devices that deliver calibration data at all.
  final bool hasDistortionModel;

  final PlatformHardwareLevel hardwareLevel;

  /// `MANUAL_SENSOR` in `REQUEST_AVAILABLE_CAPABILITIES`. **This** is the
  /// gate, not [hardwareLevel] (R3 §8).
  final bool hasManualSensor;

  final bool isLogicalMultiCamera;

  /// Why selection skipped this camera, when it did. §2.1 asks for the
  /// ultra-wide to be excluded *and logged*, since a future config may want it.
  final String? excludedReason;
}

/// What Dart asks the platform to configure.
class CaptureFormatRequest {
  CaptureFormatRequest({
    required this.preferFourThree,
    required this.previewTargetWidth,
    required this.format,
    required this.jpegQuality,
    required this.computeFrameStatistics,
    this.captureSize,
  });

  /// `null` means "pick the largest, subject to [preferFourThree]".
  final PlatformSize? captureSize;

  /// Prefer a 4:3 output: it matches the sensor's full active array, so no
  /// crop factor enters the intrinsics (§2.1, Math §4.1), and it gives the
  /// largest vertical FOV, which directly reduces the number of rings.
  final bool preferFourThree;

  /// ~1280. Preview is only used for aiming; a full-resolution preview on a
  /// tablet burns battery and thermal headroom the stitch will need (§4).
  final int previewTargetWidth;

  final PlatformCaptureFormat format;
  final int jpegQuality;

  /// Compute a centre-crop mean RGB per delivered frame. Off in production;
  /// on for the grey-card lock test (§6), which needs a *measurement* rather
  /// than an eyeball.
  final bool computeFrameStatistics;
}

/// The raw Android facts Math §4.1 derives intrinsics from. Every field is
/// straight out of `CameraCharacteristics` or the configured stream — no
/// arithmetic happens on the Kotlin side.
class AndroidIntrinsicFacts {
  AndroidIntrinsicFacts({
    required this.distortionCorrectionModeOffRequested,
    required this.distortionCorrectionSupportsNonOff,
    required this.activeArraysDiffer,
    this.focalLengthMm,
    this.sensorPhysicalWidthMm,
    this.sensorPhysicalHeightMm,
    this.pixelArraySize,
    this.preCorrectionActiveArray,
    this.activeArray,
    this.cropRegion,
    this.lensIntrinsicCalibration,
    this.lensDistortion,
    this.focalLengthIn35mmFilm,
  });

  /// `LENS_INFO_AVAILABLE_FOCAL_LENGTHS[i]` actually in force.
  final double? focalLengthMm;

  /// `SENSOR_INFO_PHYSICAL_SIZE`.
  final double? sensorPhysicalWidthMm;
  final double? sensorPhysicalHeightMm;

  /// `SENSOR_INFO_PIXEL_ARRAY_SIZE` — the denominator of the pixel pitch.
  final PlatformSize? pixelArraySize;

  /// `SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE`. Math §4.1 anchors
  /// *every* coordinate to this frame.
  final PlatformRect? preCorrectionActiveArray;

  /// `SENSOR_INFO_ACTIVE_ARRAY_SIZE`, for the [activeArraysDiffer] check.
  final PlatformRect? activeArray;

  /// The `SCALER_CROP_REGION` actually applied. Full array when not zoomed.
  final PlatformRect? cropRegion;

  /// `LENS_INTRINSIC_CALIBRATION` = `[fx, fy, cx, cy, s]` in
  /// pre-correction-array pixels, or null. R2: gated by no capability flag,
  /// documented "may be null", reported null even on Pixel hardware — so this
  /// is an **override**, not the primary path.
  final List<double>? lensIntrinsicCalibration;

  /// `LENS_DISTORTION` = `[κ1, κ2, κ3, κ4, κ5]`, **unreordered**. The reorder
  /// to OpenCV's `(k1, k2, p1, p2, k3)` happens in Dart, in the one place it
  /// already lives.
  final List<double>? lensDistortion;

  /// Whether `DISTORTION_CORRECTION_MODE_OFF` was requested on every capture.
  final bool distortionCorrectionModeOffRequested;

  /// Whether this device lists any mode other than `OFF`. R2 §4: most do not,
  /// and where none does, the pre-correction/active distinction is moot.
  final bool distortionCorrectionSupportsNonOff;

  /// Whether the two array rectangles actually differ on this device.
  final bool activeArraysDiffer;

  /// EXIF last resort: `fx = W · FocalLengthIn35mmFilm / 36`.
  final double? focalLengthIn35mmFilm;
}

/// The raw iOS facts Math §4.2 derives intrinsics from, one field per tier of
/// the chain so the resolver can say which rung it reached.
class IosIntrinsicFacts {
  IosIntrinsicFacts({
    required this.videoFieldOfViewDegrees,
    required this.geometricDistortionCorrectionDisabled,
    required this.contentAwareDistortionCorrectionDisabled,
    required this.connectionIntrinsicDeliverySupported,
    required this.connectionIntrinsicAttachmentArrived,
    required this.calibrationDataDeliverySupported,
    required this.isVirtualDevice,
    this.calibrationIntrinsicMatrix,
    this.calibrationReferenceSize,
    this.connectionIntrinsicMatrix,
    this.connectionIntrinsicReferenceSize,
    this.lensDistortionLookupTable,
    this.lensDistortionCenterX,
    this.lensDistortionCenterY,
    this.focalLengthIn35mmFilm,
  });

  /// Tier 1: `AVCameraCalibrationData.intrinsicMatrix`, row-major 3×3, valid
  /// for [calibrationReferenceSize]. R2: needs a multi-camera virtual device,
  /// which excludes base iPad, Air and mini outright — expect null.
  final List<double>? calibrationIntrinsicMatrix;
  final PlatformSize? calibrationReferenceSize;

  /// Tier 2: `AVCaptureConnection.cameraIntrinsicMatrix`, delivered as a
  /// `CMSampleBuffer` attachment on `AVCaptureVideoDataOutput` — *not* photo
  /// output. The only measured path on a single-lens iPad, and its
  /// availability there is contested (R2 "Still unknown" #1).
  final List<double>? connectionIntrinsicMatrix;
  final PlatformSize? connectionIntrinsicReferenceSize;

  /// The capability flag says "supported"…
  final bool connectionIntrinsicDeliverySupported;

  /// …and this says the attachment *actually arrived on real frames*. The
  /// distinction is the whole point: reporting the flag alone is the mistake
  /// that left this question open since 2017 (Spike B).
  final bool connectionIntrinsicAttachmentArrived;

  /// Tier 3, and the realistic primary: `videoFieldOfView`, confirmed by R2 to
  /// be **horizontal**. `fx = (W/2) / tan(FOV/2)`. This is *not*
  /// `geometricDistortionCorrectedVideoFieldOfView`, which describes the
  /// post-GDC frame and only applies while GDC is on.
  final double videoFieldOfViewDegrees;

  /// `lensDistortionLookupTable` — radial magnification factors from
  /// [lensDistortionCenterX]/[lensDistortionCenterY] to the farthest corner.
  /// Purely radial: the Brown–Conrady fit forces `p1 = p2 = 0`.
  final List<double>? lensDistortionLookupTable;
  final double? lensDistortionCenterX;
  final double? lensDistortionCenterY;

  /// Mandatory on every capture, whichever tier is used (R2 §8). Reported so
  /// a violation is visible rather than assumed away.
  final bool geometricDistortionCorrectionDisabled;
  final bool contentAwareDistortionCorrectionDisabled;

  final bool calibrationDataDeliverySupported;
  final bool isVirtualDevice;

  /// EXIF last resort.
  final double? focalLengthIn35mmFilm;
}

/// How frame timestamps were converted to the one monotonic microsecond base
/// the pose stream also uses (§2.5, §3.5).
///
/// This travels into the bundle. A 10–50 ms mismatch is 0.6–3° of rotation
/// error at a realistic 60°/s pan — larger than everything Phase 03 works to
/// remove, and it presents as a stitcher bug. If it ever goes wrong, this
/// record is how it gets found.
class ClockSyncInfo {
  ClockSyncInfo({
    required this.base,
    required this.offsetUs,
    required this.uncertaintyUs,
    required this.note,
  });

  final PlatformTimestampBase base;

  /// Added to the camera's raw timestamp to land on the sensor/motion clock.
  /// Exactly `0` for [PlatformTimestampBase.androidRealtime].
  final int offsetUs;

  /// Half the spread of the offset estimator's samples. Zero when the two
  /// clocks are the same clock and no estimation was needed.
  final int uncertaintyUs;

  final String note;
}

/// One instantaneous re-measurement of the two clocks, for the §6 stability
/// test ("offset stable within ±2 ms over 60 s").
class ClockOffsetSample {
  ClockOffsetSample({
    required this.cameraClockUs,
    required this.motionClockUs,
    required this.offsetUs,
    required this.uncertaintyUs,
  });
  final int cameraClockUs;
  final int motionClockUs;
  final int offsetUs;
  final int uncertaintyUs;
}

/// The result of opening a camera: everything later stages are only valid for.
class CameraOpenResult {
  CameraOpenResult({
    required this.captureSize,
    required this.previewSize,
    required this.sensorOrientationDegrees,
    required this.previewRotationDegrees,
    required this.previewHandlesRotation,
    required this.clock,
    required this.bracketMode,
    required this.maxBracketCount,
    required this.captureAspectIsFourThree,
    this.androidFacts,
    this.iosFacts,
    this.warning,
  });

  final PlatformSize captureSize;
  final PlatformSize previewSize;

  /// Sensor mounting rotation, needed to reconcile the portrait lock with the
  /// sensor's native orientation.
  final int sensorOrientationDegrees;

  /// Clockwise degrees the **preview texture still needs** to stand upright on a
  /// portrait screen: `0`, `90`, `180` or `270`.
  ///
  /// The platform states this rather than Dart inferring it, and the difference is
  /// not academic — it is the bug that took four attempts to find. Every input to
  /// the inference is something the device says about itself: the sensor mounting,
  /// the reported preview size, and — the one that actually decided it — whether
  /// the render path already applied the rotation. On Android that last answer
  /// comes from `SurfaceProducer.handlesCropAndRotation()`, is `true` on the legacy
  /// texture path and `false` on the API 29+ `ImageReader` backend, and cannot be
  /// derived from anything visible to Dart. A derivation that got the first two
  /// right still turned a correct preview sideways.
  ///
  /// So: `0` when the buffer arrives upright, and the mounting angle when it does
  /// not. Dart applies exactly this and nothing else.
  final int previewRotationDegrees;

  /// Whether the render path handled the crop and rotation metadata itself.
  ///
  /// Reported alongside [previewRotationDegrees] rather than folded into it because
  /// the two answer different questions — "how far do I turn it" and "why" — and the
  /// second is what makes a bug report from an unfamiliar device actionable. It
  /// lands in `bundle.json`, so a capture carries the reason with it.
  final bool previewHandlesRotation;

  final ClockSyncInfo clock;

  /// The bracket path this device will actually take, decided at open time so
  /// the caller can adjust the plan rather than discover it at frame 1.
  final PlatformBracketMode bracketMode;
  final int maxBracketCount;

  /// False means a crop factor entered the intrinsics and §2.1's preference
  /// could not be honoured. Worth surfacing: it changes the derivation.
  final bool captureAspectIsFourThree;

  final AndroidIntrinsicFacts? androidFacts;
  final IosIntrinsicFacts? iosFacts;

  /// Any compromise made while opening. Never silently degrade (arch §8).
  final String? warning;
}

/// Who made this device and what it is called.
///
/// Phase 11 §2 writes these into the output's EXIF `Make`/`Model`. That is not
/// bookkeeping: a construction record is looked at months later by somebody
/// deciding whether to trust it, and "which tablet took this" is the first
/// question when one station's panoramas are visibly worse than the rest of the
/// walk. It is also the only way a field failure can be tied to a device model
/// without asking the person who captured it to remember.
class DeviceIdentity {
  DeviceIdentity({
    required this.make,
    required this.model,
    required this.osVersion,
  });

  /// `Build.MANUFACTURER` on Android; `Apple` on iOS.
  final String make;

  /// `Build.MODEL` on Android; the hardware identifier (`iPad14,3`) on iOS.
  ///
  /// The identifier rather than the marketing name, because the marketing name
  /// needs a lookup table that goes stale with every release, and the
  /// identifier is what a capability question is actually answered against.
  final String model;

  /// OS release string, for the bundle's diagnostic record.
  final String osVersion;
}

/// What the metering pre-sweep settled on, and how firmly.
class MeteringResult {
  MeteringResult({
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

  /// The exposure locked for the whole session.
  final int exposureTimeNs;
  final int iso;
  final int colorTemperatureK;

  /// Locked focus, in diopters. §2.3: near the hyperfocal distance — locking
  /// to infinity softens near objects, locking to macro ruins everything else.
  final double focusDistanceDiopters;

  final PlatformLockQuality lockQuality;

  /// How many frames the sweep observed. A sweep that saw three frames did not
  /// see the sphere, and its percentile means nothing.
  final int sampleCount;

  /// The EV actually locked, relative to the sweep's own median frame.
  final double chosenEv;

  /// Reported alongside [percentile65Ev] so the §2.3 decision is *visible* in
  /// the data rather than only in the code: interiors are mid-tone with a few
  /// bright windows, and the mean is dragged bright by the windows and crushes
  /// the interior.
  final double meanEv;
  final double percentile65Ev;

  final bool aeConverged;

  /// Whether `NOISE_REDUCTION` / `EDGE` / `TONEMAP` / `COLOR_CORRECTION` were
  /// pinned to fixed modes (§2.3 step 5). Easy to miss, and leaving any of
  /// them adaptive reintroduces exactly the per-frame photometric
  /// inconsistency the AE lock exists to remove.
  final bool pinnedProcessingModes;

  final String? note;
}

/// One frame returned by a bracketed capture.
class PlatformFrame {
  PlatformFrame({
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

  final String filePath;

  /// The bias in stops this frame was *requested* at.
  final double evBias;

  /// Shutter instant, already converted to the single monotonic microsecond
  /// base the pose stream shares (§2.5, §3.5).
  final int timestampUs;

  final int byteCount;

  /// What the sensor actually did, as opposed to what was asked for. When a
  /// bracket comes back with two identical frames — the failure R3 warns about
  /// on devices without real bracketing — this is the only evidence of it.
  final int? exposureTimeNs;
  final int? iso;

  /// Computed from the *actual* exposure and ISO, so the "EV separation within
  /// 0.3 EV of requested" check is against reality rather than intent.
  final double? achievedEvBias;

  /// Centre-crop channel means, present only when
  /// [CaptureFormatRequest.computeFrameStatistics] is set. The grey-card
  /// AE/AWB lock measurement (§6).
  final double? meanR;
  final double? meanG;
  final double? meanB;

  final String? note;
}

/// One bracket's worth of frames plus the timing the 600 ms budget is judged
/// against.
class CaptureResponse {
  CaptureResponse({
    required this.frames,
    required this.burstWallClockMs,
    required this.shutterToShutterMs,
    required this.mode,
    required this.clampedExposure,
    required this.clampedIso,
    required this.deferredEncodeMs,
    this.note,
  });

  final List<PlatformFrame> frames;

  /// Trigger → last frame's **pixels in hand**, not `onCaptureCompleted`.
  /// Metadata routinely completes well before pixels are delivered, and pixels
  /// are what Phase 05 needs; timing the metadata would give a flattering,
  /// useless number (Spike C).
  final double burstWallClockMs;

  /// From sensor timestamps: what the sensor sustains, separated from what
  /// processing then costs. That distinction is what the JPEG-vs-YUV decision
  /// turns on (R3 §9).
  final List<double> shutterToShutterMs;

  final PlatformBracketMode mode;

  /// Clamping is reported, never silent: a silently clamped bracket looks like
  /// a passing capture while delivering less dynamic range than assumed.
  final bool clampedExposure;
  final bool clampedIso;

  /// What the YUV path moved *off* the hot path — not what it removed.
  final double deferredEncodeMs;

  final String? note;
}

// ---------------------------------------------------------------- pose --

/// Which reference frame a platform attitude quaternion is expressed against.
///
/// Carried on every sample rather than inferred from `Platform.isAndroid`,
/// because it is the input to the one conversion Phase 07 §2 explicitly says
/// **must not be trusted to derivation** — the doc's own Android derivation
/// produces a determinant −1 matrix, which would mirror the panorama. Naming
/// the source frame in the data is what lets `pose_frame_conversion.dart` hold
/// one tested conversion per frame instead of one per platform guess.
enum PlatformPoseFrame {
  /// Android `TYPE_GAME_ROTATION_VECTOR`: device→world, where the world frame
  /// is `X` ≈ east, `Y` ≈ north, **`Z` up**. Gyro + accelerometer, bias- and
  /// scale-corrected by the OS filter, and — the reason it is used instead of
  /// `TYPE_ROTATION_VECTOR` — **no magnetometer**, so rebar, lift motors and
  /// steel studs cannot bend the heading (Phase 07 §1, Math §1.1).
  androidGameRotationVector,

  /// iOS `CMDeviceMotion.attitude.quaternion` under
  /// `.xArbitraryCorrectedZVertical`: device→reference, reference `Z`
  /// vertical, `X` an arbitrary horizontal direction, yaw drift-corrected.
  /// Chosen over `.xTrueNorthZVertical` for the same magnetometer reason.
  iosXArbitraryCorrectedZVertical,
}

/// Which clock a pose sample's timestamp is on, before any conversion.
///
/// Separate from [PlatformTimestampBase], which describes the *camera*. Phase
/// 07 §6 pitfall 1 is that `SensorEvent.timestamp`'s base "varies by device" —
/// usually `elapsedRealtimeNanos`, but not universally — and Phase 06's
/// `TimestampMapper` already assumed the usual case when it put camera frames
/// on `elapsedRealtimeNanos` and called the offset exactly zero. That
/// assumption is now *measured* on the pose side rather than inherited, because
/// if it is wrong the two clocks silently disagree by however long the device
/// has been asleep.
enum PlatformPoseClockBase {
  /// `SensorEvent.timestamp` is `SystemClock.elapsedRealtimeNanos()`. The
  /// documented and near-universal case, and the one Phase 06's camera-side
  /// `REALTIME` mapping pairs with exactly.
  androidElapsedRealtime,

  /// `SensorEvent.timestamp` is `System.nanoTime()` — the device that pitfall 1
  /// warns about. The offset is real, device-specific, and measured.
  androidMonotonicNanoTime,

  /// `CMDeviceMotion.timestamp`, seconds since boot on `systemUptime` — the
  /// same base Phase 06's iOS `TimestampMapper` converts sample buffers onto.
  iosSystemUptime,
}

/// What this device can actually do, and — when it cannot — why.
///
/// Exists so a gyro-less tablet is refused at the feature entry point with a
/// sentence a site manager can act on, rather than producing a panorama built
/// on accelerometer tilt alone (Phase 07 §6 pitfall 3, Phase 12 §1).
class PoseCapabilities {
  PoseCapabilities({
    required this.hasGyroscope,
    required this.hasAccelerometer,
    required this.hasFusedRotation,
    required this.hasGravity,
    required this.usesMagnetometer,
    required this.frame,
    required this.minDelayUs,
    required this.detail,
    this.unsupportedReason,
  });

  /// The one hard requirement. Without it there is no attitude source that
  /// tracks a pan, and the pipeline cannot work at all.
  final bool hasGyroscope;

  /// Needed for the gravity lock that makes pitch and roll drift-free.
  final bool hasAccelerometer;

  /// Whether the fused, magnetometer-free attitude sensor is present —
  /// `TYPE_GAME_ROTATION_VECTOR` on Android, `isDeviceMotionAvailable` on iOS.
  final bool hasFusedRotation;

  /// Whether a fused gravity vector is available (`TYPE_GRAVITY` /
  /// `CMDeviceMotion.gravity`). Its absence is recoverable — raw accelerometer
  /// would do — but it is reported because [PlatformPoseSample.upX] is what the
  /// levelling step of Math §7 ultimately rests on.
  final bool hasGravity;

  /// **Must be false.** Reported rather than assumed so that a build which
  /// accidentally selected `TYPE_ROTATION_VECTOR` or `.xTrueNorthZVertical`
  /// shows up as a recorded fact in the bundle instead of as an unexplained
  /// heading error on a site with steel in the walls.
  final bool usesMagnetometer;

  /// The frame [PlatformPoseSample]'s quaternion is expressed against.
  final PlatformPoseFrame frame;

  /// The fastest the attitude source will run, in µs between samples.
  /// `Sensor.getMinDelay()` on Android; 0 where the platform does not say.
  final int minDelayUs;

  /// Plain-language description of what was found, for the bundle and the
  /// report.
  final String detail;

  /// Non-null exactly when this device cannot be supported, phrased as
  /// something the user can act on.
  final String? unsupportedReason;
}

/// How pose timestamps were reconciled with the clock Phase 06 puts shutter
/// timestamps on.
class PoseClockInfo {
  PoseClockInfo({
    required this.base,
    required this.offsetUs,
    required this.uncertaintyUs,
    required this.note,
  });

  final PlatformPoseClockBase base;

  /// Added to a raw sample timestamp to land on the shared motion clock.
  /// Exactly `0` for [PlatformPoseClockBase.androidElapsedRealtime] and
  /// [PlatformPoseClockBase.iosSystemUptime], where the two *are* one clock.
  final int offsetUs;

  /// Bound on the offset estimate. Zero when nothing needed estimating.
  final int uncertaintyUs;

  final String note;
}

/// What starting the stream settled.
class PoseStreamInfo {
  PoseStreamInfo({
    required this.frame,
    required this.clock,
    required this.samplingPeriodUs,
    required this.minDelayUs,
    required this.note,
  });

  final PlatformPoseFrame frame;
  final PoseClockInfo clock;

  /// The period actually requested of the platform (§4 asks for 10 000 µs).
  final int samplingPeriodUs;

  /// The floor the platform imposes on it; 0 when unreported.
  final int minDelayUs;

  final String note;
}

/// One attitude sample, exactly as the platform reported it.
///
/// **No frame conversion happens on the native side.** This is the same
/// decision the intrinsics chain makes for the same reason, one step further:
/// Phase 07 §2 says the world→world conversion "must be proven by the §5 test,
/// not by derivation", and a conversion that lives in Kotlin and Swift can only
/// ever be tested on the two devices in the room. In Dart it is one function,
/// pinned by unit tests over every branch, and the device test then confirms
/// the platform docs rather than the arithmetic.
class PlatformPoseSample {
  PlatformPoseSample({
    required this.qx,
    required this.qy,
    required this.qz,
    required this.qw,
    required this.upX,
    required this.upY,
    required this.upZ,
    required this.angularSpeedRadPerSec,
    required this.timestampUs,
    required this.sequence,
    required this.accuracy,
  });

  /// Device→reference rotation, in the frame named by [PoseStreamInfo.frame].
  final double qx;
  final double qy;
  final double qz;
  final double qw;

  /// A **unit** vector in the *device* frame pointing **away from the earth**.
  ///
  /// Normalised natively rather than passed raw because the two platforms
  /// disagree on both magnitude and sign: Android `TYPE_GRAVITY` reads
  /// `(0, 0, +9.81)` with the device flat on its back, iOS
  /// `CMDeviceMotion.gravity` reads `(0, 0, −1)` in the same pose. Reconciling
  /// that is a one-line, per-platform fact about what a sensor reads in a known
  /// physical pose — which is precisely the kind of thing the native side is
  /// here to report — and it leaves Dart with one convention instead of two.
  ///
  /// Dart does **not** take it on trust: `PlatformAhrsPoseSource` checks that
  /// this vector, rotated into the world frame, actually comes out pointing up,
  /// and refuses to start if it does not (Phase 07 §2's reflection hazard, in
  /// its detectable half).
  final double upX;
  final double upY;
  final double upZ;

  /// `|ω|` from the gyroscope, rad/s. A magnitude rather than a vector because
  /// it is frame-invariant, which keeps one more sign convention out of the
  /// wire format — and the steadiness gate only ever wants the magnitude.
  final double angularSpeedRadPerSec;

  /// Sample instant on the shared motion clock, already converted by
  /// [PoseClockInfo.offsetUs].
  final int timestampUs;

  /// Monotonic counter from the start of the stream, so a gap in delivery is
  /// distinguishable from a gap in sampling.
  final int sequence;

  /// Android `SensorEvent.accuracy` (`SENSOR_STATUS_*`); `-1` on iOS, which
  /// publishes no equivalent.
  final int accuracy;
}

// ------------------------------------------------------------------ APIs --

@HostApi()
abstract class SphereCameraHostApi {
  /// Enumerates the physical cameras and their capabilities.
  @async
  List<CameraDescriptor> listCameras();

  /// Opens [cameraId] and configures the capture and preview streams.
  @async
  CameraOpenResult open(String cameraId, CaptureFormatRequest format);

  /// Attaches the preview and returns the Flutter texture id. Preview is
  /// delivered through the platform texture APIs; bytes are never streamed
  /// over the channel (§4).
  @async
  int attachPreview();

  /// Releases the preview texture without closing the camera.
  @async
  void detachPreview();

  /// Runs the metering pre-sweep for [durationSeconds], then hard-locks AE,
  /// AWB and AF for the rest of the session.
  @async
  MeteringResult meterAndLock(double durationSeconds);

  /// Releases the lock.
  @async
  void unlock();

  /// Fires one bracket at [evBiases], writing frames into [outputDirectory]
  /// with names beginning [namePrefix].
  @async
  CaptureResponse captureBracket(
    List<double> evBiases,
    String outputDirectory,
    String namePrefix,
  );

  /// Current thermal state (§5).
  @async
  PlatformThermalState thermalState();

  /// Re-measures the camera↔motion clock offset. Called repeatedly by the §6
  /// stability test; cheap enough to call in a loop.
  @async
  ClockOffsetSample sampleClockOffset();

  /// Make, model and OS version, for the output's EXIF (Phase 11 §2).
  ///
  /// On the camera API rather than the pose one because it is asked once, at
  /// open time, alongside every other fact about the hardware that took the
  /// frames.
  @async
  DeviceIdentity deviceIdentity();

  /// The largest texture edge this GPU will accept, in pixels (Phase 11 §3.1).
  ///
  /// The viewer needs this before it uploads a panorama, and it is the one
  /// number that decides whether the sphere renders or comes up **black**.
  /// Many mid-range tablet GPUs cap at 4096, and an 8192-wide upload against
  /// such a cap does not raise an error — it silently produces nothing, which
  /// looks exactly like a stitcher that emitted an empty image.
  ///
  /// Returns 0 when the platform cannot say, which the caller must read as
  /// "assume the conservative floor" rather than "no limit".
  @async
  int maxTextureSize();

  /// Total physical RAM in MB, for the memory-tier probe (arch §6.5).
  @async
  int totalPhysicalMemoryMb();

  /// How much more memory *this process* may allocate, in MB, or `-1` where
  /// the platform will not say.
  ///
  /// Not the tier decision — that is [totalPhysicalMemoryMb], and it is total
  /// rather than available on purpose (Phase 10 §4): available fluctuates, and
  /// a tier that moves with it would make output resolution differ between two
  /// runs on the same device, which makes a bug report useless.
  ///
  /// This is the pre-flight check instead. iOS answers it with
  /// `os_proc_available_memory()`, and it matters there specifically because
  /// iOS kills a process on memory pressure with no recoverable signal — no
  /// `bad_alloc` to catch, no chance to drop a tier. So the only defence is to
  /// ask before starting, and to start one tier lower if the answer is smaller
  /// than the tier needs. Android returns `-1`: it has no per-process
  /// equivalent, and a real `OutOfMemoryError` there *is* catchable, so the
  /// retry path covers it.
  @async
  int availableProcessMemoryMb();

  /// Battery charge as a whole percentage, or `-1` where the platform will not
  /// say.
  ///
  /// Phase 12 §3 asks for the drain **per station** to be measured and
  /// published, because a site walk is up to thirty of them and a tablet that
  /// cannot finish one is a feature nobody can use. It is a percentage rather
  /// than a mAh figure on purpose: percentage is what both platforms report
  /// without a vendor API, and the number that matters is "how many stations
  /// does this tablet have left", which is a percentage divided by a
  /// percentage.
  ///
  /// It is coarse — most devices report in steps of 1% and some in steps of 5%
  /// — so one station's drain is at or below the quantisation. The device matrix
  /// therefore measures across a *run* of stations and divides, which is also
  /// the number a site lead actually wants.
  @async
  int batteryPercent();

  /// Closes the camera and releases every resource.
  @async
  void close();
}

@FlutterApi()
abstract class SphereCameraFlutterApi {
  /// A preview frame is ready, stamped on the shared monotonic base. Phase 07
  /// pairs this with the pose stream.
  void onFrameAvailable(int timestampUs);

  /// Something went wrong outside a pending call — a disconnect, a HAL error,
  /// a dropped burst.
  void onError(String code, String message);

  /// Thermal state changed (§5). At `serious` the UI warns and suggests
  /// stitching later; at `critical` a stitch is refused and told why.
  void onThermalStateChanged(PlatformThermalState state);

  /// The session was interrupted or resumed — a phone call, another app, or
  /// split view on iPad, where a second app taking the camera is common
  /// (§7 pitfall 3).
  void onSessionInterrupted(bool interrupted, String reason);
}

/// The AHRS half (Phase 07).
///
/// Deliberately a second API rather than more methods on
/// [SphereCameraHostApi]: the pose stream outlives any one camera session — §6
/// pitfall 5 says never reset the buffer between targets — and it must keep
/// running while the camera is closed and reopened. Two APIs make that
/// independence structural instead of a convention someone has to remember.
@HostApi()
abstract class SpherePoseHostApi {
  /// What this device's motion hardware can do. Cheap, and callable before
  /// anything is started, because Phase 12 §1 refuses an unsupported device at
  /// the *feature entry point* — before the camera opens, before the user has
  /// walked to the first station.
  @async
  PoseCapabilities poseCapabilities();

  /// Starts the attitude stream at [samplingPeriodUs] (§4 asks for 10 000 µs,
  /// i.e. 100 Hz).
  ///
  /// Throws when the device is unsupported, so the refusal cannot be missed by
  /// a caller that forgot to check [poseCapabilities] first.
  @async
  PoseStreamInfo startPose(int samplingPeriodUs);

  /// Stops the stream and releases the sensors.
  @async
  void stopPose();
}

@FlutterApi()
abstract class SpherePoseFlutterApi {
  /// One attitude sample, at the requested rate.
  ///
  /// One message per sample rather than a batch: the guidance reticle of Phase
  /// 09 is driven from the newest pose, and batching 100 Hz into 10 Hz packets
  /// would add up to 100 ms of visible lag to the aim gate for no benefit the
  /// interpolator needs — `PoseBuffer.at()` always looks *backwards* to a
  /// shutter that has already happened, so delivery latency costs it nothing
  /// and staleness costs the UI directly.
  void onPoseSample(PlatformPoseSample sample);

  /// The stream failed after starting — the sensor was unregistered by the OS,
  /// or motion updates stopped. Never silent (architecture §8).
  void onPoseError(String code, String message);
}
