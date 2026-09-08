/// Capture a true 360°×180° spherical panorama from a handheld phone or
/// tablet, and stitch it into one equirectangular image.
///
/// Three entry points, in the order a caller uses them:
///
/// 1. [SphereCaptureSession] — probes the camera, derives a shot plan from the
///    *measured* intrinsics, and proves the plan covers the sphere before the
///    camera opens.
/// 2. [SphereCaptureView] — the guided capture screen. Holds no capture logic;
///    it draws what the session reports.
/// 3. [SphereStitcher] — takes the resulting [CaptureBundle] and returns a
///    panorama together with a [StitchReport] measuring how good it actually
///    is.
///
/// The conventions every part of this package obeys — frames, the OpenCV
/// rotation conversion, the equirectangular mapping, the shot-plan geometry —
/// are normative and live in `phases/01_MATH_AND_CONVENTIONS.md`. Do not
/// restate any of them locally.
library;

// ── Capture ────────────────────────────────────────────────────────────────
export 'src/api/models/sphere_capture_config.dart'
    show ExposureStrategy, QualityTier, SphereCaptureConfig;
export 'src/api/sphere_capability.dart'
    show SphereCapability, SphereCapabilityProbe, SphereCapabilityReport;
export 'src/api/sphere_capture_session.dart'
    show CaptureWakelock, SphereCaptureSession;
export 'src/api/sphere_capture_view.dart'
    show CaptureGlyph, CaptureHudButton, CaptureTextButton, SphereCaptureView;
// Phase 09. The capture screen is six elements and two thin screens either
// side of it; all three are exported because a host app that wants its own
// station list still needs the pre-capture coaching (the "pivot, don't walk"
// sentence is the parallax mitigation from architecture §3) and the review
// screen's plain-language warnings.
export 'src/ui/capture_hud.dart'
    show
        CaptureHud,
        CaptureHudCache,
        CaptureHudColors,
        CaptureHudLayout,
        CaptureHudMetrics,
        CaptureHudModel,
        CaptureHudPainter,
        CaptureHudState;
export 'src/ui/capture_instructions.dart' show CaptureInstructions;
export 'src/ui/capture_warnings.dart' show CaptureWarnings;
export 'src/ui/pre_capture_screen.dart'
    show PivotDiagram, SpherePreCaptureScreen;
export 'src/ui/review_screen.dart' show SphereReviewScreen;
// Phase 08. The plan and its proof are part of the API surface because a
// caller has to be able to catch the refusal: a plan that cannot cover the
// sphere is rejected before the camera opens, and "never open the camera on a
// plan that cannot succeed" is only useful if the host app can say why.
export 'src/plan/coverage_validator.dart' show CoverageValidator;
export 'src/plan/plan_builder.dart' show InsufficientCoverageException, PlanBuilder;
export 'src/guidance/guidance_engine.dart' show GuidanceEngine;
export 'src/guidance/shutter_gate.dart' show ShutterGate;
export 'src/quality/frame_gate.dart'
    show FrameGate, FrameRejection, FrameRejectionMessage;

// ── Stitch ─────────────────────────────────────────────────────────────────
export 'src/api/models/stitch_progress.dart' show StitchProgress, StitchStage;
export 'src/api/models/stitch_result.dart' show StitchReport, StitchResult;
// Phase 12 §2. The warning codes are part of the API surface because the whole
// point of coding them is that a host app can react to one — offer a retake for
// a dropped position, a "close other apps" prompt for a tier downgrade — rather
// than pattern-matching a sentence. The message table is exported with them so
// an app that wants its own copy can see what the default says.
export 'src/api/models/stitch_warning.dart'
    show StitchWarning, StitchWarningCode, StitchWarningMessages;
export 'src/api/sphere_stitcher.dart'
    show SphereStitcher, StitchCancelledException;
// Phase 10. The queue is the *default* place a stitch happens — `finish()`
// returns a bundle and the manager keeps walking — so a host app has to be able
// to see it, drive it and show it. Its failure states are exported for the same
// reason as the camera's: a bundle that could not be stitched after three tries
// is a compromise, and architecture §8 says compromises reach the caller.
export 'src/stitch/stitch_queue.dart'
    show StitchQueue, StitchQueueEntry, StitchQueueEvent, StitchQueueStatus;
// The tier probe and its reasoning. Exported because a caller that wants to
// explain "why is this panorama 4096 wide" needs the same three numbers the
// decision was made from, and because a host app may legitimately want to force
// a tier for a test device.
export 'src/stitch/memory_tier.dart' show MemoryTier, MemoryTierProbe;
export 'src/stitch/native_stitcher.dart'
    show NativeStitchException, SvStatus;

// ── Metadata ───────────────────────────────────────────────────────────────
// Phase 11. Criterion S10 is most of what makes the output useful, and the
// heading is the field that decides whether it opens facing the right way — so
// the host app has to be able to supply the plan heading (§2's best source),
// attach a GPS fix it already holds, and read back what was written.
//
// The writer is exported as well as the reader, because an app that re-encodes
// or re-exports a panorama has to write the *same* block rather than a second
// dialect of it — and because a caller that only ever reads would still need it
// to re-tag a file after editing. (`tools/replay` does not use it: the harness
// calls `sv_stitch` through its own binding and measures pixels against ground
// truth, where metadata would be noise.)
export 'src/metadata/gpano_writer.dart' show GPanoReader, GPanoWriter;
export 'src/metadata/panorama_metadata.dart'
    show GeoLocation, HeadingSource, PanoramaHeading, PanoramaMetadata;

// ── Data ───────────────────────────────────────────────────────────────────
export 'src/api/models/camera_intrinsics.dart' show CameraIntrinsics;
export 'src/api/models/capture_bundle.dart'
    show CaptureBundle, CapturedPosition, ExposureShot;
export 'src/api/models/device_pose.dart' show DevicePose;
export 'src/plan/capture_plan.dart'
    show CapturePlan, CaptureTarget, CoverageReport;

// ── Pose ───────────────────────────────────────────────────────────────────
// Phase 07. Exported for the same reason the camera boundary is: a caller has
// to be able to see that this device was refused for want of a gyroscope, how
// long the AHRS took to converge, and whether the shutter fell outside the
// buffered window — all of which are things architecture §8 forbids doing
// quietly.
export 'src/tracking/platform_ahrs_pose_source.dart'
    show PlatformAhrsPoseSource, PoseStreamDiagnostics;
export 'src/tracking/pigeon_pose_platform.dart' show PigeonPosePlatform;
export 'src/tracking/pose_buffer.dart' show PoseBuffer;
export 'src/tracking/pose_frame_conversion.dart'
    show PoseFrameConversion, PoseReferenceFrame;
export 'src/tracking/pose_platform.dart'
    show
        PlatformAttitudeSample,
        PoseClock,
        PoseClockBase,
        PosePlatformError,
        PoseStreamStart,
        SpherePosePlatform;
export 'src/tracking/pose_source.dart'
    show PoseSource, PoseSourceUnsupported, PoseSupport;
export 'src/tracking/shutter_pose.dart'
    show ShutterPoseResolution, ShutterPoseResolver;

// ── View ───────────────────────────────────────────────────────────────────
export 'src/viewer/sphere_viewer_widget.dart' show SphereViewer;
export 'src/viewer/viewer_controller.dart' show SphereViewerController;
// Phase 13's API audit found this reachable from `SphereViewer.textureLimit`
// without being nameable. It stays a knob rather than being taken away: a host
// app that already knows the GPU cap — because it uploaded a texture five
// minutes ago — can hand it over instead of paying for the probe, and a test
// device with a driver that lies about `GL_MAX_TEXTURE_SIZE` needs somewhere to
// say so.
export 'src/viewer/panorama_texture.dart' show TextureLimit;

// ── Supporting types ───────────────────────────────────────────────────────
// Everything above is the API surface named in PHASE_01 §4. These are the
// types reachable *from* it — a caller cannot construct a CameraIntrinsics
// without ImageSize, pattern-match an ExposureStrategy without its variants,
// or read a SessionState without SessionPhase. Exported for that reason and no
// other; nothing new is introduced here.
export 'src/api/models/camera_intrinsics.dart' show IntrinsicsSource;
// Phase 06. The camera boundary is part of the API surface because a caller
// embedding this package has to be able to see what the device could and could
// not do — which intrinsics rung was reached, whether the AE lock held, how the
// bracket was actually produced, how hot the tablet is. Architecture §8's
// "never silently degrade" only works if the degradations are reachable.
export 'src/camera/camera_platform.dart'
    show
        BracketCapture,
        BracketMode,
        CameraDescriptor,
        CameraFacing,
        CameraOpenResult,
        CameraPlatformError,
        CaptureFormatSpec,
        ClockOffsetSample,
        ClockSync,
        DeviceIdentity,
        ExposureLockQuality,
        MeteringResult,
        PlatformFrame,
        SessionInterruption,
        SphereCameraPlatform,
        ThermalState,
        TimestampBase;
export 'src/camera/camera_probe.dart'
    show CameraProbe, CameraSelection, ProbedCamera;
export 'src/camera/exposure_controller.dart' show ExposureController;
export 'src/camera/intrinsics_resolver.dart'
    show IntrinsicsResolution, IntrinsicsResolver, IntrinsicsUnavailable;
export 'src/camera/pigeon_camera_platform.dart' show PigeonCameraPlatform;
export 'src/camera/thermal_policy.dart'
    show ThermalAction, ThermalDecision, ThermalPolicy;
export 'src/api/models/distortion_model.dart'
    show BrownConradyDistortion, DistortionModel, LookupTableDistortion;
export 'src/api/models/image_size.dart' show ImageSize;
export 'src/api/models/json_codec.dart' show SphereJsonFormatException;
export 'src/api/models/sphere_capture_config.dart'
    show AutoExposure, Bracket3Exposure, LockedExposure;
export 'src/api/sphere_capture_session.dart' show SessionPhase, SessionState;
export 'src/guidance/guidance_engine.dart' show GuidanceHint, GuidanceState;
