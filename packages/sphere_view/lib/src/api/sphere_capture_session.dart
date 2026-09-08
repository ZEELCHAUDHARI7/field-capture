import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../camera/camera_platform.dart';
import '../camera/camera_probe.dart';
import '../camera/exposure_controller.dart';
import '../camera/pigeon_camera_platform.dart';
import '../camera/thermal_policy.dart';
import '../guidance/guidance_engine.dart';
import '../guidance/shutter_gate.dart';
import '../metadata/panorama_metadata.dart';
import '../plan/capture_plan.dart';
import '../plan/coverage_validator.dart';
import '../plan/plan_builder.dart';
import '../quality/frame_gate.dart';
import '../quality/sharpness.dart';
import '../tracking/platform_ahrs_pose_source.dart';
import '../tracking/pose_buffer.dart';
import '../tracking/pose_source.dart';
import 'sphere_capability.dart';
import '../tracking/shutter_pose.dart';
import '../utils/spherical_conventions.dart';
import 'models/camera_intrinsics.dart';
import 'models/capture_bundle.dart';
import 'models/device_pose.dart';
import 'models/image_size.dart';
import 'models/sphere_capture_config.dart';

/// Where a capture session is in its lifecycle.
enum SessionPhase {
  /// Created but not started.
  idle,

  /// Enumerating cameras and reading their intrinsics.
  probing,

  /// Deriving the shot plan and proving it covers the sphere. **The session can
  /// fail here**, and failing here is the cheap place to fail.
  planning,

  /// Running the 2 s metering pre-sweep before locking AE/AWB/AF.
  metering,

  /// Guiding the user through the plan.
  capturing,

  /// Re-shooting a position that was rejected or that the user asked for again.
  retaking,

  /// Temporarily halted — thermal, an interruption, or the user.
  paused,

  /// Finished; a bundle is available.
  completed,

  /// Abandoned; any partial bundle has been discarded.
  aborted,

  /// Unrecoverably failed. [SessionState.message] says why.
  failed,
}

/// A snapshot of the session, emitted on every pose sample.
///
/// A value type so the capture UI can be a pure function of it — which is what
/// lets Phase 09's widget tests drive any state, including the ones that are
/// hard to reach on a real device, without a camera.
class SessionState {
  /// Creates a session state.
  const SessionState({
    required this.phase,
    required this.capturedCount,
    required this.totalCount,
    this.currentTarget,
    this.guidance,
    this.message,
    this.pose,
    this.remainingTargets = const [],
  });

  /// Lifecycle phase.
  final SessionPhase phase;

  /// Positions captured and accepted so far.
  final int capturedCount;

  /// Positions the plan asks for.
  final int totalCount;

  /// The target being aimed at, or `null` once every position is captured.
  final CaptureTarget? currentTarget;

  /// The current aim/steadiness/dwell state, or `null` when not capturing.
  final GuidanceState? guidance;

  /// Plain-language detail for the UI, e.g. why a frame was rejected.
  final String? message;

  /// The pose this state was computed from, or `null` outside the capture loop.
  ///
  /// Carried so the overlay can project **every** mark itself rather than being
  /// handed one pre-projected dot. That is what makes the marks world-locked by
  /// construction: each one is re-derived from its own absolute world direction
  /// on every frame, so none of them can drift relative to the others or
  /// accumulate anything.
  final DevicePose? pose;

  /// Targets still to shoot, [currentTarget] first.
  ///
  /// The overlay draws all of them. One dot at a time gives the user no way to
  /// see where the capture is going, and no way to tell a target that is 40° away
  /// from one that is 4° away until they have already turned.
  final List<CaptureTarget> remainingTargets;

  /// Progress through the plan, `0..1`.
  double get progress => totalCount == 0 ? 0 : capturedCount / totalCount;
}

/// Holds the screen awake for the length of a capture.
///
/// An interface rather than a direct `WakelockPlus` call because a 90 s capture
/// that lets the device sleep loses the session, and that is worth being able
/// to test. The default implementation is the real plugin, degrading to a
/// recorded warning rather than an exception where no plugin is registered —
/// the replay tooling and the unit tests both run without a Flutter engine.
abstract class CaptureWakelock {
  /// The production wakelock.
  const factory CaptureWakelock.plugin() = _PluginWakelock;

  /// Requests that the screen stay on. Returns a warning if it could not.
  Future<String?> acquire();

  /// Releases the request.
  Future<void> release();
}

class _PluginWakelock implements CaptureWakelock {
  const _PluginWakelock();

  @override
  Future<String?> acquire() async {
    try {
      await WakelockPlus.enable();
      return null;
    } on Object catch (e) {
      return 'the screen could not be held awake ($e); if the device sleeps '
          'mid-capture the session will be interrupted';
    }
  }

  @override
  Future<void> release() async {
    try {
      await WakelockPlus.disable();
    } on Object {
      // Nothing useful to do: the session is ending either way, and failing to
      // release a lock we may never have taken must not mask the real outcome.
    }
  }
}

/// Owns one capture: the plan, the camera, the pose stream, the gates, and the
/// bundle that comes out.
///
/// It exists as a single orchestrator because the capture path has four
/// independent asynchronous sources — poses at ~100 Hz, preview frames, shutter
/// results, and thermal events — and the correctness conditions are all
/// *cross-source*: the pose must be interpolated to the camera's shutter
/// timestamp, the shutter may only fire when the gates agree, and the session
/// must still produce a valid bundle if the user quits halfway. Spreading that
/// across widgets is how the previous implementation ended up trusting whatever
/// pose happened to be current.
///
/// ### Three things that make an interrupted site walk survivable
///
/// On a live site, interruption is the normal case rather than the exception —
/// a phone call, a colleague, a low battery, another app taking the camera on an
/// iPad in split view. So:
///
/// * **frames go to disk the moment the platform returns them.** 29 positions
///   × 3 exposures at ~4 MB is over 300 MB of JPEG; holding that in memory
///   would be an OOM on the tier this package targets, and it would evaporate
///   on any crash;
/// * **`bundle.json` is rewritten after every accepted position**, atomically
///   (temp file plus rename), so a kill at any instant leaves either the
///   previous manifest or the new one and never a truncated one;
/// * **[resume] picks a partial bundle back up** at the first uncaptured
///   target. Losing 25 captured positions to a phone call is not a degraded
///   experience, it is a lost site visit.
///
/// [finish] is deliberately total: a session the user abandoned at position 12
/// of 29 yields a real bundle with an honest coverage number, not an error
/// (architecture §8).
class SphereCaptureSession {
  SphereCaptureSession._({
    required this.config,
    required SphereCameraPlatform camera,
    required PoseSource poseSource,
    required CapturePlan plan,
    required CameraIntrinsics captureIntrinsics,
    required CameraIntrinsics deviceIntrinsics,
    required int captureQuarterTurns,
    required this.previewQuarterTurns,
    required this.previewSize,
    required BracketMode bracketMode,
    required int maxBracketCount,
    required Directory directory,
    required String sessionId,
    required CaptureWakelock wakelock,
    required GuidanceEngine guidance,
    required Future<double?> Function(File) measureSharpness,
    required Map<String, Object?> deviceInfo,
    required List<String> warnings,
    required DateTime startedAt,
    PanoramaHeading heading = PanoramaHeading.unknown,
    GeoLocation? location,
    List<CapturedPosition> positions = const [],
  }) : _startedAt = startedAt,
       _heading = heading,
       _location = location,
       _camera = camera,
       _poseSource = poseSource,
       _plan = plan,
       _captureIntrinsics = captureIntrinsics,
       _deviceIntrinsics = deviceIntrinsics,
       _captureQuarterTurns = captureQuarterTurns,
       _bracketMode = bracketMode,
       _maxBracketCount = maxBracketCount,
       _directory = directory,
       _sessionId = sessionId,
       _wakelock = wakelock,
       _guidance = guidance,
       _measureSharpness = measureSharpness,
       _deviceInfo = deviceInfo,
       _warnings = warnings,
       _positions = [...positions],
       _exposure = ExposureController(camera),
       _frameGate = FrameGate(config),
       _gate = ShutterGate(config) {
    _pending = [
      for (final target in _plan.targets)
        if (!_positions.any((p) => p.targetIndex == target.index)) target.index,
    ];
  }

  /// Probes the camera, derives the plan from the measured intrinsics, and
  /// validates its coverage — all before returning.
  ///
  /// The order is the point. The pose source is checked first, because a device
  /// with no gyroscope cannot be supported at all and refusing at the entry
  /// point beats producing a bad panorama (Phase 12 §1). The camera is then
  /// opened only to *read* its intrinsics, and if the plan those intrinsics
  /// imply cannot cover the sphere the camera is closed again and
  /// [InsufficientCoverageException] is thrown. Nothing is ever metered,
  /// locked or shot on a plan that cannot succeed: that would spend 90 seconds
  /// of somebody's time on site to produce a panorama they would blame on the
  /// software.
  ///
  /// Throws [PoseSourceUnsupported] on a device without the sensors, and
  /// [InsufficientCoverageException] when the plan fails S5.
  static Future<SphereCaptureSession> create({
    SphereCaptureConfig config = const SphereCaptureConfig(),
    SphereCameraPlatform? camera,
    PoseSource? poseSource,
    SphereCapabilityReport? capability,
    Directory? directory,
    String? sessionId,
    CaptureWakelock wakelock = const CaptureWakelock.plugin(),
    PlanBuilder planBuilder = const PlanBuilder(),
    GuidanceEngine guidance = const GuidanceEngine(),
    CaptureFormatSpec format = const CaptureFormatSpec(),
    Future<double?> Function(File file)? measureSharpness,
  }) async {
    final id = sessionId ?? 'station-${DateTime.now().toUtc().toIso8601String()}';
    final poses = poseSource ?? PlatformAhrsPoseSource();
    final platform = camera ?? PigeonCameraPlatform();

    // Phase 12 §1's gate, at the entry point rather than mid-flow. This is the
    // *programmatic* entry point — `SpherePreCaptureScreen` is the UI one and
    // gates on the same probe — and it runs before anything is opened, metered or
    // locked, because a device that cannot do this at all should cost the operator
    // one screen rather than a walk round the building.
    //
    // The probe is cheap by construction: motion capabilities, camera
    // *descriptors* and total RAM. No camera is opened here; the open a few lines
    // down is the session's own.
    final probedCapability =
        capability ?? await SphereCapabilityProbe.probe(camera: platform, poseSource: poses);
    if (!probedCapability.isSupported) {
      throw PoseSourceUnsupported(probedCapability.poseSupport);
    }
    final support = probedCapability.poseSupport;

    final probe = CameraProbe(platform);
    final probed = await probe.openBestCamera(format: _sizedForDisplay(format));

    final warnings = <String>[
      if (probed.opened.warning != null) probed.opened.warning!,
      // The device's own limits, as sentences, recorded at capture time so they
      // travel in the bundle to whoever reads the panorama months later. Coded
      // upstream; flattened here because `device_info` is where they land and it
      // predates the codes.
      for (final warning in probedCapability.warnings) warning.message,
    ];
    final oriented = _toDeviceFrame(probed.opened, warnings);
    _warnOnPreviewAspect(probed.opened, warnings);

    final CapturePlan plan;
    try {
      plan = planBuilder.buildPlan(
        intrinsics: oriented,
        overlapFraction: config.overlapFraction,
        captureNadir: config.captureNadir,
      );
    } on Object {
      // The camera was opened to read intrinsics and nothing more; give it back
      // before rethrowing so a refused plan does not leave a device holding a
      // camera it is not going to use.
      await platform.close();
      rethrow;
    }

    // Not fatal: a panorama with no Make/Model is worse to diagnose later but
    // is otherwise a complete artefact, and refusing a capture because a
    // string could not be read would be absurd.
    DeviceIdentity identity;
    try {
      identity = await platform.deviceIdentity();
    } on Object {
      identity = DeviceIdentity.unknown;
    }

    return SphereCaptureSession._(
      config: config,
      camera: platform,
      poseSource: poses,
      plan: plan,
      captureIntrinsics: probed.opened.intrinsics,
      bracketMode: probed.opened.bracketMode,
      maxBracketCount: probed.opened.maxBracketCount,
      deviceIntrinsics: oriented,
      captureQuarterTurns: _quarterTurnsToCaptureFrame(probed.opened),
      previewQuarterTurns: _previewQuarterTurns(probed.opened),
      previewSize: probed.opened.previewSize,
      directory: directory ?? await _defaultDirectory(id),
      sessionId: id,
      wakelock: wakelock,
      guidance: guidance,
      measureSharpness: measureSharpness ?? Sharpness.ofFile,
      startedAt: DateTime.now().toUtc(),
      deviceInfo: {
        ...probed.toDeviceInfoJson(),
        'pose_support': support.toJson(),
        'capability': probedCapability.toJson(),
        'device_frame_intrinsics': oriented.toJson(),
        // Read once, here, because it is a fact about the hardware that is
        // about to take the frames. It becomes the output's EXIF Make/Model
        // (Phase 11 §2) and outlives the session in the bundle, which is what
        // lets a replayed capture still say what took it.
        'device_identity': identity.toJson(),
      },
      warnings: warnings,
    );
  }

  /// Reopens the partial bundle in [directory] and continues from the first
  /// uncaptured target.
  ///
  /// The stored plan is authoritative and is **not** rebuilt: the frames
  /// already on disk were shot against it, and a plan rebuilt from a camera
  /// that re-opened even slightly differently would describe a different sphere
  /// from the one half-captured. For the same reason the re-opened camera's
  /// intrinsics are compared against the bundle's, and a material difference
  /// refuses the resume with a specific message rather than mixing two
  /// geometries into one bundle — §7 pitfall 4, and `CapturePlan.intrinsics`
  /// exists to make it impossible to forget. The partial bundle is untouched
  /// and remains stitchable on its own.
  static Future<SphereCaptureSession> resume(
    Directory directory, {
    SphereCaptureConfig? config,
    SphereCameraPlatform? camera,
    PoseSource? poseSource,
    CaptureWakelock wakelock = const CaptureWakelock.plugin(),
    GuidanceEngine guidance = const GuidanceEngine(),
    CaptureFormatSpec format = const CaptureFormatSpec(),
    Future<double?> Function(File file)? measureSharpness,
  }) async {
    final bundle = await CaptureBundle.load(directory);
    final poses = poseSource ?? PlatformAhrsPoseSource();
    final support = await poses.support;
    if (!support.isSupported) throw PoseSourceUnsupported(support);

    final platform = camera ?? PigeonCameraPlatform();
    final probed =
        await CameraProbe(platform).openBestCamera(format: _sizedForDisplay(format));
    final warnings = <String>[
      if (probed.opened.warning != null) probed.opened.warning!,
    ];
    final oriented = _toDeviceFrame(probed.opened, warnings);
    _warnOnPreviewAspect(probed.opened, warnings);

    if (!_intrinsicsMatch(oriented, bundle.plan.intrinsics)) {
      await platform.close();
      throw StateError(
        'this session cannot be resumed: the camera re-opened with a different '
        'field of view (${oriented.hfovDegrees.toStringAsFixed(1)}° × '
        '${oriented.vfovDegrees.toStringAsFixed(1)}°) from the one the '
        '${bundle.positions.length} captured positions were shot at '
        '(${bundle.plan.intrinsics.hfovDegrees.toStringAsFixed(1)}° × '
        '${bundle.plan.intrinsics.vfovDegrees.toStringAsFixed(1)}°), and a plan '
        'is only valid for one intrinsics set. The captured positions are '
        'unharmed and can still be stitched as a partial panorama.',
      );
    }

    return SphereCaptureSession._(
      config: config ?? const SphereCaptureConfig(),
      camera: platform,
      poseSource: poses,
      plan: bundle.plan,
      captureIntrinsics: bundle.intrinsics,
      bracketMode: probed.opened.bracketMode,
      maxBracketCount: probed.opened.maxBracketCount,
      deviceIntrinsics: oriented,
      captureQuarterTurns: _quarterTurnsToCaptureFrame(probed.opened),
      previewQuarterTurns: _previewQuarterTurns(probed.opened),
      previewSize: probed.opened.previewSize,
      directory: directory,
      sessionId: bundle.sessionId,
      wakelock: wakelock,
      guidance: guidance,
      measureSharpness: measureSharpness ?? Sharpness.ofFile,
      // The *original* capture time, heading and fix carry over. A resumed
      // session finishes a capture that started earlier, and stamping it with
      // the time somebody reopened the app would misdate every station that
      // was ever interrupted.
      startedAt: bundle.capturedAt ?? DateTime.now().toUtc(),
      heading: bundle.heading,
      location: bundle.location,
      deviceInfo: {...bundle.deviceInfo, 'resumed': true},
      warnings: [
        ...warnings,
        'resumed from a partial capture with ${bundle.positions.length} of '
            '${bundle.plan.length} positions already shot',
      ],
      positions: bundle.positions,
    );
  }

  /// The configuration this session runs under.
  final SphereCaptureConfig config;

  final SphereCameraPlatform _camera;
  final PoseSource _poseSource;
  final CapturePlan _plan;
  final CameraIntrinsics _captureIntrinsics;

  /// See [CaptureBundle.captureQuarterTurns].
  final int _captureQuarterTurns;

  /// Clockwise quarter turns that carry the **preview texture** into the device
  /// frame the guidance dot is projected in.
  ///
  /// Both platforms hand back the preview in the sensor's own orientation —
  /// Android's `SurfaceTexture` buffer is the sensor buffer, and iOS returns the
  /// `CVPixelBuffer` from the video output with no `videoOrientation` set — so a
  /// capture view that draws the texture unrotated shows the scene a quarter turn
  /// from the frame every dot is computed in. Panning right then slides the scene
  /// *down*, which reads as "the dot moves as I move the camera" and is the one
  /// defect that makes an otherwise correct projection look broken.
  ///
  /// It is the same turn the plan's intrinsics were rotated by, from the same
  /// helper, so the scene and the marks cannot end up in different frames.
  final int previewQuarterTurns;

  /// The preview stream size, in the **capture** frame as the platform reported
  /// it. Rotate by [previewQuarterTurns] for the device frame.
  ///
  /// Worth carrying rather than assuming the capture aspect: `CameraFacts`
  /// selects the preview size independently and falls back to a literal
  /// `Size(1280, 960)`, so on a device with no matching output the preview and
  /// the stills genuinely differ in shape.
  final ImageSize previewSize;

  /// The preview's aspect ratio (width / height) in the **device** frame, which
  /// is the rectangle the guidance offsets are fractions of.
  double get previewAspectRatio {
    var size = previewSize;
    if (size.width <= 0 || size.height <= 0) {
      // Nothing usable from the preview stream. The stills came off the same
      // sensor, so their shape is the right fallback.
      size = _deviceIntrinsics.imageSize;
      if (size.width <= 0 || size.height <= 0) return 3 / 4;
    }
    // **Always portrait**, because the screen is locked to it and this is the
    // rectangle the guidance dots are placed against.
    //
    // Rotating the reported pair by `previewQuarterTurns` is what this used to do,
    // and it is only right when we are the ones doing the rotating. When the
    // platform has already turned the buffer the turn is 0, so that arithmetic
    // returned the *sensor's* landscape aspect for content that was already
    // upright — and the HUD then placed every dot against a rectangle rotated 90°
    // from the one on screen. Normalising to short-over-long is correct in both
    // cases and cannot disagree with the box the view builds, which applies the
    // same rule.
    final wide = size.width > size.height;
    return (wide ? size.height : size.width) / (wide ? size.width : size.height);
  }

  /// What the device can actually do with a bracket, known at open time so the
  /// session adapts rather than discovering it at the first shutter.
  ///
  /// Load-bearing: on a `singleShot` camera, requesting three exposures returns
  /// one frame, and a frame gate expecting three would reject **every** position
  /// as an incomplete bracket — a device that can capture nothing at all rather
  /// than one that captures without HDR.
  final BracketMode _bracketMode;
  final int _maxBracketCount;
  final CameraIntrinsics _deviceIntrinsics;
  final Directory _directory;
  final String _sessionId;
  final CaptureWakelock _wakelock;
  final GuidanceEngine _guidance;
  final Future<double?> Function(File) _measureSharpness;
  final Map<String, Object?> _deviceInfo;
  final List<String> _warnings;

  /// Wall clock at session start, for the output's `DateTimeOriginal`.
  ///
  /// Taken once, at the start, rather than when the bundle is saved. A site
  /// walk's stations are minutes apart and a bundle may be saved well after the
  /// last shutter; the useful timestamp is when the capture happened.
  final DateTime _startedAt;

  /// Where the output should say it faces, with its provenance (Phase 11 §2).
  PanoramaHeading _heading;

  /// The station's position, when the host app has supplied one.
  GeoLocation? _location;
  final List<CapturedPosition> _positions;
  final ExposureController _exposure;
  final FrameGate _frameGate;
  final ShutterGate _gate;

  /// The pose history. Owned here rather than read off the pose source so that
  /// the session works against any [PoseSource] — including the synthetic one
  /// the replay tooling drives — and **never cleared between targets**
  /// (Phase 07 §6 pitfall 5): continuous history is what both the shutter
  /// interpolation and the steadiness gate run on.
  final PoseBuffer _poses = PoseBuffer();

  final _states = StreamController<SessionState>.broadcast();
  late final ShutterPoseResolver _resolver = ShutterPoseResolver(_poses);

  StreamSubscription<DevicePose>? _poseSubscription;
  StreamSubscription<ThermalState>? _thermalSubscription;
  StreamSubscription<SessionInterruption>? _interruptionSubscription;
  StreamSubscription<CameraPlatformError>? _errorSubscription;

  late List<int> _pending;
  SessionPhase _phase = SessionPhase.idle;
  String? _message;
  bool _busy = false;
  bool _closed = false;
  List<double> _biases = const [0.0];

  /// The plan derived from the probed intrinsics. Valid only for those
  /// intrinsics and for the portrait lock.
  CapturePlan get plan => _plan;

  /// The intrinsics the plan, the guidance and the preview are expressed in —
  /// the device's portrait frame.
  CameraIntrinsics get deviceIntrinsics => _deviceIntrinsics;

  /// Where the JPEGs and `bundle.json` are being written.
  Directory get directory => _directory;

  /// State snapshots, one per pose sample.
  Stream<SessionState> get states => _states.stream;

  /// The current lifecycle phase.
  SessionPhase get phase => _phase;

  /// Positions captured and accepted so far, in shooting order.
  List<CapturedPosition> get positions => List.unmodifiable(_positions);

  /// Plan target indices still to shoot, in the order they will be offered.
  List<int> get pendingTargetIndices => List.unmodifiable(_pending);

  /// The target being aimed at, or `null` when the plan is complete.
  CaptureTarget? get currentTarget =>
      _pending.isEmpty ? null : _plan.targets[_pending.first];

  /// Whether a bracket is being fired, written and graded right now.
  ///
  /// The whole sequence — burst, pose interpolation, sharpness, manifest — is
  /// asynchronous and takes a few hundred milliseconds, during which the pose
  /// stream keeps arriving and must not start a second bracket into the same
  /// position. The UI uses it for the post-shutter flash and to disable the
  /// manual button.
  bool get isCapturingPosition => _busy;

  /// Everything compromised so far. Empty is the normal case; anything here
  /// reaches the bundle and the user (architecture §8).
  List<String> get warnings => List.unmodifiable(_warnings);

  /// The heading the output will claim, with its provenance (Phase 11 §2).
  PanoramaHeading get heading => _heading;

  /// Records the direction the image centre faces, taken from the **plan**.
  ///
  /// This is the top of Phase 11 §2's priority order and the one worth going
  /// out of the way for: the manager drew a path on a drawing whose north is
  /// surveyed, so the facing direction at a station is arithmetic — good to a
  /// degree or two, where the magnetometer indoors is good to tens. It costs
  /// the user nothing, which is the other half of why it wins.
  ///
  /// Displaces a magnetometer heading already recorded, never the reverse.
  void setPlanHeading(double degrees) =>
      _heading = PanoramaHeading.fromPlan(degrees);

  /// Records a magnetometer heading, used only if no plan heading is supplied.
  ///
  /// Ignored when a plan heading is already present, because a fresher reading
  /// from a worse instrument is still a worse answer.
  void setMagnetometerHeading(double degrees) {
    if (_heading.source == HeadingSource.plan) return;
    _heading = PanoramaHeading.fromMagnetometer(degrees);
  }

  /// Records where this station is, for the output's EXIF GPS block.
  ///
  /// Supplied by the host app: this package holds no location permission and
  /// deliberately does not ask for one.
  void setLocation(GeoLocation? location) => _location = location;

  /// Attaches the camera preview and returns the Flutter texture id to render.
  ///
  /// A passthrough, and deliberately nothing more. The preview is the one part
  /// of the capture screen that has to come from the camera the session already
  /// owns — opening a second one would fail on both platforms — but attaching it
  /// is a display concern, so [SphereCaptureView] asks for it rather than the
  /// session deciding when a preview should exist (Phase 09 §5).
  Future<int> attachPreview() => _camera.attachPreview();

  /// Releases the preview texture without closing the camera.
  Future<void> detachPreview() => _camera.detachPreview();

  /// Runs the metering pre-sweep, then hard-locks AE, AWB and AF for the rest
  /// of the session.
  Future<void> beginMetering() async {
    _requirePhase({SessionPhase.idle}, 'beginMetering');
    _setPhase(SessionPhase.metering);
    final wakelockWarning = await _wakelock.acquire();
    if (wakelockWarning != null) _warnings.add(wakelockWarning);

    await _poseSource.start();
    _poseSubscription = _poseSource.poses.listen(
      _onPose,
      onError: (Object error) => _fail('$error'),
    );
    _listenToPlatform();

    // Under `ExposureStrategy.auto` there is nothing to meter and nothing to
    // lock: every position is exposed on its own merits, which is the point.
    // Skipping the sweep also gives the operator back its 2 seconds and drops
    // the whole family of lock-quality warnings, none of which describe a defect
    // any more — "the platform granted only a best-effort lock" is irrelevant
    // when no lock was wanted.
    if (config.exposure is AutoExposure) {
      _biases = const [0.0];
      _deviceInfo['metering'] = <String, Object?>{
        'strategy': 'auto',
        'note':
            'no metering sweep and no exposure lock: each position is metered by '
            'the camera as it is shot, and inter-frame brightness differences are '
            'removed by gain compensation during stitching',
      };
      _emit();
      return;
    }

    final metering = await _exposure.meterAndLock();
    _warnings.addAll(_exposure.warnings);
    _deviceInfo['metering'] = metering.toJson();
    _biases = _exposure.bracketBiases(
      config,
      mode: _bracketMode,
      maxBracketCount: _maxBracketCount,
    );
    if (_biases.length < config.exposure.shotsPerPosition) {
      _warnings.add(
        'this camera reports ${_bracketMode.name} with at most '
        '$_maxBracketCount frames per bracket, so each position is captured at '
        '${_biases.length} exposure(s) instead of '
        '${config.exposure.shotsPerPosition}; dynamic range will be whatever '
        'the sensor gives in one shot',
      );
    }
    _emit();
  }

  /// Starts guiding the user through the plan.
  Future<void> beginCapture() async {
    _requirePhase({
      SessionPhase.metering,
      SessionPhase.paused,
      SessionPhase.idle,
    }, 'beginCapture');
    if (_phase == SessionPhase.idle) await beginMetering();
    await _directory.create(recursive: true);
    // A manifest before the first shutter, so even a crash during the first
    // bracket leaves a resumable — if empty — bundle rather than a bare folder.
    await _save();
    _gate.reset();
    _setPhase(_pending.isEmpty ? SessionPhase.completed : SessionPhase.capturing);
  }

  /// Fires the shutter regardless of the gates — the manual fallback for when
  /// automatic capture will not settle.
  Future<void> captureManual() async {
    if (_pending.isEmpty || _busy) return;
    await _capture(_plan.targets[_pending.first], manual: true);
  }

  /// Re-queues [targetIndex] for another attempt.
  ///
  /// Appended rather than inserted at the front: the user is standing somewhere
  /// specific and aiming at something specific, and yanking them back across
  /// the room mid-ring costs more than finishing the row first. Any frames
  /// already captured for it are dropped, so the retake replaces rather than
  /// duplicates.
  void retake(int targetIndex) {
    if (targetIndex < 0 || targetIndex >= _plan.length) {
      throw RangeError.index(targetIndex, _plan.targets, 'targetIndex');
    }
    _positions.removeWhere((p) => p.targetIndex == targetIndex);
    if (!_pending.contains(targetIndex)) _pending.add(targetIndex);
    _marksStale = true;
    if (_phase == SessionPhase.completed) _setPhase(SessionPhase.retaking);
    unawaited(_save());
    _emit();
  }

  /// Closes the session and writes the bundle. Works even when the plan is
  /// incomplete.
  ///
  /// A partial capture is not an error and is never treated as one: the user
  /// keeps what they have, the manifest records honestly how much of the sphere
  /// it covers, and the stitcher fills what is missing (Phase 04 §6). What is
  /// *not* allowed is pretending — so the achieved coverage is re-rasterised
  /// over the positions actually captured rather than inherited from the plan's
  /// proof, and a shortfall is written into the bundle's warnings.
  Future<CaptureBundle> finish() async {
    final bundle = await _save(finalise: true);
    await _shutdown();
    _setPhase(SessionPhase.completed);
    return bundle;
  }

  /// Abandons the session and deletes anything partially written.
  Future<void> abort() async {
    await _shutdown();
    if (await _directory.exists()) {
      await _directory.delete(recursive: true);
    }
    _setPhase(SessionPhase.aborted);
  }

  // ── the capture loop ──────────────────────────────────────────────────────

  void _onPose(DevicePose pose) {
    _poses.add(pose);
    if (_phase != SessionPhase.capturing && _phase != SessionPhase.retaking) {
      return;
    }
    final target = currentTarget;
    if (target == null) {
      _setPhase(SessionPhase.completed);
      return;
    }
    final tolerance = _gate.aimToleranceRadiansAt(pose.timestampUs);
    var state = _guidance.evaluate(
      pose: pose,
      target: target,
      config: config,
      intrinsics: _deviceIntrinsics,
      aimToleranceRadians: tolerance,
    );

    // A bracket in flight stops the *gate*, never the *guidance*.
    //
    // This used to return before evaluating anything, so for the whole of
    // `captureBracket` plus the sharpness measurement — comfortably over a second
    // with three exposures — no guidance reached the stream at all, and the last
    // thing on it was a `guidance: null` emit. The HUD draws nothing for null, so
    // every capture blinked the dot and the dwell ring out and back. The dot has
    // to stay where the world says it is even while the shutter is busy; what must
    // not happen is a second `_gate.update`, which is what would fire twice for
    // one target.
    if (_busy) {
      _emit(
        guidance: state.copyWith(dwellProgress: _gate.dwellProgress),
        target: target,
        pose: pose,
      );
      return;
    }

    final fire = _gate.update(state, pose.timestampUs);
    state = state.copyWith(dwellProgress: _gate.dwellProgress);
    _emit(guidance: state, target: target, pose: pose);

    if (fire && config.autoShutter) {
      unawaited(_capture(target, relaxed: _gate.firedUnderRelaxedAim));
    }
  }

  Future<void> _capture(
    CaptureTarget target, {
    bool manual = false,
    bool relaxed = false,
  }) async {
    if (_busy || _closed) return;
    _busy = true;
    try {
      if (relaxed) {
        _message = 'Close enough — capturing';
        _emit(target: target);
      }
      final capture = await _camera.captureBracket(
        _biases,
        outputDirectory: _directory.path,
        namePrefix: 'pos_${target.index.toString().padLeft(3, '0')}',
      );

      final resolution = _resolver.resolve(capture);
      final pose = resolution.pose;
      if (pose == null) {
        _reject(target, FrameRejection.noPoseAtShutter, resolution.reason);
        return;
      }

      final shots = [
        for (final frame in capture.frames)
          ExposureShot(
            // Relative to the bundle directory: a bundle is meant to be copied
            // off the device and replayed on a desktop, and an absolute device
            // path would make it unreplayable the moment it moved.
            filePath: p.relative(frame.filePath, from: _directory.path),
            evBias: frame.evBias,
            timestampUs: frame.timestampUs,
            exposureTimeNs: frame.exposureTimeNs,
            iso: frame.iso,
          ),
      ];
      final base = shots.firstWhere(
        (s) => s.evBias == 0.0,
        orElse: () => shots.first,
      );
      // A null measurement means the bytes on disk would not decode, which is a
      // reason to reject the frame rather than a reason to assume it is perfect.
      final measured =
          await _measureSharpness(File(p.join(_directory.path, base.filePath)));
      if (measured == null) {
        await _deleteFiles(shots);
        _reject(target, FrameRejection.unreadableFrame, null);
        return;
      }
      final sharpness = measured;

      final position = CapturedPosition(
        targetIndex: target.index,
        pose: pose,
        shots: shots,
        sharpness: sharpness,
        steadinessRadPerSec: pose.angularSpeedRadPerSec,
      );

      final rejection = _frameGate.evaluate(
        position,
        expectedShotCount: _biases.length,
      );
      if (rejection != null) {
        // Manual capture overrides the *gates*, never the *quality* checks: the
        // user asking to shoot now is a statement about aim, not a claim that a
        // blurred frame is usable. §4 — sharpness and steadiness are never
        // relaxed, by anyone.
        await _deleteFiles(shots);
        _reject(target, rejection, null);
        return;
      }

      _positions.add(position);
      _pending.remove(target.index);
      _marksStale = true;
      _message = null;
      _gate.reset();
      // Incremental manifest, after every position: this is the line that turns
      // a phone call from a lost site visit into a resumed one.
      await _save();
      if (_pending.isEmpty) {
        _setPhase(SessionPhase.completed);
      } else {
        _emit(target: currentTarget);
      }
    } on Object catch (e) {
      _message = 'That capture failed ($e) — try again';
      _gate.reset();
      _emit(target: target);
    } finally {
      _busy = false;
    }
  }

  void _reject(CaptureTarget target, FrameRejection reason, String? detail) {
    // The target stays at the head of the queue: a rejected position is not a
    // captured one, and the whole value of rejecting here is that the user is
    // still standing in the right place.
    _message = detail == null ? reason.message : '${reason.message} ($detail)';
    _gate.reset();
    _emit(target: target);
  }

  Future<void> _deleteFiles(List<ExposureShot> shots) async {
    for (final shot in shots) {
      final file = File(p.join(_directory.path, shot.filePath));
      if (await file.exists()) await file.delete();
    }
  }

  // ── bundle ────────────────────────────────────────────────────────────────

  /// Serialises manifest writes.
  ///
  /// `CaptureBundle.save` writes `bundle.json.tmp` and renames it, which is what
  /// makes a kill mid-write safe — but only if there is one writer. Two
  /// overlapping saves (a retake landing while a position is being recorded)
  /// would both write the same temp path and the second rename would find it
  /// already gone. Chaining costs nothing at this rate and removes the race
  /// rather than narrowing it.
  ///
  /// Nullable, and seeded on first use rather than at construction.
  ///
  /// A `Future.value()` field initialiser is created in whatever zone the
  /// constructor ran in, and `flutter_test` runs a `testWidgets` body under a
  /// **fake** async zone whose microtasks only advance when the test pumps. A
  /// session constructed in a test body and then driven inside
  /// `WidgetTester.runAsync` — the only way to await real file I/O, so it is
  /// what a consuming app's widget test will do — would chain every manifest
  /// write onto a future that is never completed, and the symptom is a hang
  /// rather than an error. Phase 13 found it in `StitchQueue`, which had the
  /// same shape; this is the same fix applied before it is found here.
  Future<void>? _saveChain;

  Future<CaptureBundle> _save({bool finalise = false}) {
    final previous = _saveChain;
    final next = previous == null
        ? _writeBundle(finalise: finalise)
        : previous.then((_) => _writeBundle(finalise: finalise));
    // The chain must survive a failed write, or one IO error would wedge every
    // later manifest — including the one `finish()` depends on.
    _saveChain = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// Writes `bundle.json`.
  ///
  /// [finalise] additionally re-measures coverage over what was actually
  /// captured, which is the difference between a manifest written every few
  /// seconds during capture and the one the stitcher reads.
  Future<CaptureBundle> _writeBundle({bool finalise = false}) async {
    final captured = {for (final p in _positions) p.targetIndex};
    final achieved = finalise && captured.length < _plan.length
        ? const CoverageValidator().validate(
            CapturePlan(
              targets: [
                for (final t in _plan.targets)
                  if (captured.contains(t.index)) t,
              ],
              intrinsics: _plan.intrinsics,
              overlapFraction: _plan.overlapFraction,
              coverage: _plan.coverage,
            ),
            _plan.intrinsics,
          )
        : null;

    final warnings = [
      ..._warnings,
      if (achieved != null)
        'this capture is incomplete: ${_positions.length} of ${_plan.length} '
            'positions were shot, covering '
            '${(achieved.fractionCoveredAtLeastOnce * 100).toStringAsFixed(1)}% '
            'of the sphere at least once. The panorama will be stitched from '
            'what is here and the rest filled, not invented',
    ];

    final bundle = CaptureBundle(
      sessionId: _sessionId,
      directory: _directory,
      plan: _plan,
      // The *capture stream's* intrinsics, because they describe the JPEGs on
      // disk. `plan.intrinsics` is the device-frame form the plan and the
      // guidance were computed in; on a camera mounted square to the display
      // the two are the same object, and where they differ the stitcher needs
      // this one.
      intrinsics: _captureIntrinsics,
      captureQuarterTurns: _captureQuarterTurns,
      heading: _heading,
      location: _location,
      capturedAt: _startedAt,
      positions: List.unmodifiable(_positions),
      deviceInfo: {
        ..._deviceInfo,
        'config': config.toJson(),
        'warnings': warnings,
        'completion_fraction': _plan.length == 0
            ? 0.0
            : _positions.length / _plan.length,
        if (achieved != null) 'achieved_coverage': achieved.toJson(),
      },
    );
    await bundle.save();
    return bundle;
  }

  // ── platform plumbing ─────────────────────────────────────────────────────

  void _listenToPlatform() {
    _thermalSubscription = _camera.thermalStates.listen((state) {
      final decision = ThermalPolicy.forCapture(state);
      if (!decision.allowed) {
        _message = decision.message;
        _warnings.add(decision.message);
        _setPhase(SessionPhase.paused);
      } else if (decision.action == ThermalAction.warn) {
        _message = decision.message;
        _warnings.add(decision.message);
        _emit();
      }
    });
    _interruptionSubscription = _camera.interruptions.listen((event) {
      if (event.interrupted) {
        _message = 'Capture paused: ${event.reason}';
        _setPhase(SessionPhase.paused);
      } else {
        _message = null;
        _gate.reset();
        if (_phase == SessionPhase.paused) {
          _setPhase(
            _pending.isEmpty ? SessionPhase.completed : SessionPhase.capturing,
          );
        }
      }
    });
    _errorSubscription = _camera.errors.listen((error) {
      _message = error.message;
      _warnings.add('camera error ${error.code}: ${error.message}');
      _emit();
    });
  }

  Future<void> _shutdown() async {
    if (_closed) return;
    _closed = true;
    await _poseSubscription?.cancel();
    await _thermalSubscription?.cancel();
    await _interruptionSubscription?.cancel();
    await _errorSubscription?.cancel();
    await _poseSource.stop();
    try {
      await _exposure.release();
    } on Object {
      // The lock dies with the camera; a failure to release it must not stop
      // the bundle being handed back.
    }
    await _camera.close();
    await _wakelock.release();
  }

  void _fail(String reason) {
    _message = reason;
    _warnings.add(reason);
    _setPhase(SessionPhase.failed);
  }

  void _requirePhase(Set<SessionPhase> allowed, String call) {
    if (!allowed.contains(_phase)) {
      throw StateError(
        '$call is not valid from ${_phase.name}; expected one of '
        '${allowed.map((p) => p.name).join(', ')}',
      );
    }
  }

  void _setPhase(SessionPhase phase) {
    _phase = phase;
    _emit(target: currentTarget);
  }

  /// The last guidance computed, so a state published for some other reason does
  /// not erase the dot.
  ///
  /// Every non-pose caller of [_emit] — a phase change, a thermal warning, a
  /// camera error, the relaxed-capture message — used to publish `guidance: null`,
  /// and the HUD draws no dot and no dwell ring for null. So the marks the user
  /// is aiming with vanished on events that had nothing to do with aiming. The
  /// last guidance is at most one pose sample old at 100 Hz, which is a truer
  /// thing to draw than nothing.
  GuidanceState? _lastGuidance;

  /// The last pose seen, for the same reason as [_lastGuidance]: a state
  /// published between pose samples still has to be able to place the marks.
  DevicePose? _lastPose;

  /// Rebuilt only when a position is accepted or a target is retaken, not per
  /// pose sample — the overlay reads it 100 times a second and allocating a list
  /// of 29 targets that often is exactly the per-frame garbage Phase 09 §5
  /// forbids.
  List<CaptureTarget> _remaining = const [];
  bool _marksStale = true;

  void _rebuildMarks() {
    _remaining = [for (final index in _pending) _plan.targets[index]];
    _marksStale = false;
  }

  void _emit({GuidanceState? guidance, CaptureTarget? target, DevicePose? pose}) {
    if (_states.isClosed) return;
    if (guidance != null) _lastGuidance = guidance;
    if (pose != null) _lastPose = pose;
    // Terminal phases have nothing to aim at, and a dot left over from the last
    // target would be a mark pointing at a capture that is already finished.
    if (_phase == SessionPhase.completed || _phase == SessionPhase.aborted) {
      _lastGuidance = null;
    }
    if (_marksStale) _rebuildMarks();
    _states.add(
      SessionState(
        phase: _phase,
        capturedCount: _positions.length,
        totalCount: _plan.length,
        currentTarget: target ?? currentTarget,
        guidance: guidance ?? _lastGuidance,
        message: _message,
        pose: pose ?? _lastPose,
        remainingTargets: _remaining,
      ),
    );
  }

  /// Releases the state stream. The session is unusable afterwards.
  Future<void> dispose() async {
    await _shutdown();
    await _states.close();
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  /// **Clockwise** quarter turns that carry the *capture* frame onto the
  /// *device* frame — the rotation [CameraIntrinsics.rotatedQuarterTurn] applies
  /// and the one the preview texture needs.
  ///
  /// Three things have to agree about this turn or the scene, the dot and the
  /// panorama end up in three different frames, each hiding the others' error:
  /// the intrinsics the plan is built from ([_toDeviceFrame]), the preview the
  /// user aims with ([previewQuarterTurns]), and the seed roll the stitcher
  /// applies ([_quarterTurnsToCaptureFrame]). All three come from here, and the
  /// arithmetic itself lives in [SphericalConventions] with the rest of the frame
  /// math.
  /// Clockwise quarter turns that stand the **preview buffer** up on a portrait
  /// screen — as the platform reports it.
  ///
  /// This used to be derived here, from the sensor mounting and the reported frame
  /// shape, and it was wrong on a Galaxy S24 while looking right in every test. The
  /// missing input is not observable from Dart at all: whether the render path
  /// already applied the rotation. Android's legacy texture path does, its API 29+
  /// `ImageReader` backend does not, and only `SurfaceProducer.handlesCropAndRotation()`
  /// knows which one is in use. So the platform states the answer and this obeys it.
  ///
  /// The old derivation survives as the fallback for a platform that reports
  /// nothing usable — which, after the pigeon field became required, is only a
  /// hand-built fake in a test.
  static int _previewQuarterTurns(CameraOpenResult opened) {
    final reported = opened.previewQuarterTurns;
    if (reported != 0 || opened.previewHandlesRotation) return reported;
    // A platform that says "no rotation needed and I did not handle it" is either
    // telling the truth about a portrait-native buffer or has not been taught to
    // report. Fall back to the shape, which is right for the first case and no
    // worse than before for the second.
    final preview = opened.previewSize;
    if (preview.width > 0 && preview.height > 0) {
      return preview.width > preview.height ? 1 : 0;
    }
    final capture = opened.intrinsics.imageSize;
    return capture.width > capture.height ? 1 : 0;
  }

  static int _captureToDeviceQuarterTurns(CameraOpenResult opened) =>
      SphericalConventions.captureToDeviceQuarterTurns(
        landscapeCapture:
            opened.intrinsics.imageSize.width > opened.intrinsics.imageSize.height,
        sensorOrientationDegrees: opened.sensorOrientationDegrees,
      );

  /// Quarter turns from the device frame to the capture frame, for
  /// [CaptureBundle.captureQuarterTurns].
  ///
  /// The **inverse** of [_captureToDeviceQuarterTurns], and the inverse is the
  /// whole content of this function. It used to return the forward turn, which
  /// is the same for 0 and differs by exactly 180° for 1 and 3 — a roll BA's
  /// gauge freedom cannot absorb, because `sv_geometry.cpp` applies it on the
  /// *right*. On the overwhelming majority of Android phones, which report
  /// `SENSOR_ORIENTATION = 90`, that shipped an upside-down panorama.
  ///
  /// The sign is derived rather than read off a comment — see
  /// [SphericalConventions.deviceToCaptureQuarterTurns], which owns both
  /// directions so they cannot drift apart.
  static int _quarterTurnsToCaptureFrame(CameraOpenResult opened) =>
      SphericalConventions.deviceToCaptureQuarterTurns(
        landscapeCapture:
            opened.intrinsics.imageSize.width > opened.intrinsics.imageSize.height,
        sensorOrientationDegrees: opened.sensorOrientationDegrees,
      );

  /// Records it when the preview and the stills are not the same shape.
  ///
  /// The dot is placed against the *preview* rectangle, so a preview at a
  /// different aspect from the capture is not fatal — the guidance stays
  /// truthful about what the user is looking at. It does mean the frame they aim
  /// with is not quite the frame they get, which is worth having in the bundle
  /// when somebody asks months later why a seam landed where it did.
  static void _warnOnPreviewAspect(
    CameraOpenResult opened,
    List<String> warnings,
  ) {
    final preview = opened.previewSize;
    final capture = opened.captureSize;
    if (preview.width <= 0 ||
        preview.height <= 0 ||
        capture.width <= 0 ||
        capture.height <= 0) {
      warnings.add(
        'the camera reported a preview size of ${preview.width}×'
        '${preview.height} and a capture size of ${capture.width}×'
        '${capture.height}; the aiming rectangle fell back to the capture aspect',
      );
      return;
    }
    final previewAspect = preview.width / preview.height;
    final captureAspect = capture.width / capture.height;
    // 2% is well inside the difference between 4:3 and 16:9 and well outside
    // the rounding a hardware size list introduces.
    if ((previewAspect - captureAspect).abs() > 0.02 * captureAspect) {
      warnings.add(
        'the preview stream is ${previewAspect.toStringAsFixed(3)}:1 while the '
        'stills are ${captureAspect.toStringAsFixed(3)}:1, so the frame you aim '
        'with is a slightly different shape from the frame that is recorded',
      );
    }
  }

  static CameraIntrinsics _toDeviceFrame(
    CameraOpenResult opened,
    List<String> warnings,
  ) {
    final k = opened.intrinsics;
    final turns = _captureToDeviceQuarterTurns(opened);
    final mountedSideways = opened.sensorOrientationDegrees % 180 == 90;
    if (turns == 0) {
      if (mountedSideways) {
        warnings.add(
          'the camera reports a ${opened.sensorOrientationDegrees}° sensor '
          'mounting but delivers a portrait frame, so the capture and device '
          'frames disagree about which way the sensor is turned; the plan was '
          'built for the frame as delivered',
        );
      }
      return k;
    }
    return k.rotatedQuarterTurn(clockwise: turns == 1);
  }

  /// A preview wide enough for this display, when the caller did not name one.
  ///
  /// The buffer is landscape and the screen is portrait-locked, so after the
  /// quarter turn the buffer's **width lands on the screen's height** — and the
  /// preview is cover-fitted, so that is the edge that has to cover the long side
  /// of the display. Sizing it for the *short* side, or to a flat 1280, upscales
  /// by two on any modern phone and the viewfinder looks broken next to a sharp
  /// panorama.
  ///
  /// Capped, because §4's concern was real: the preview is only for aiming, and a
  /// full-resolution one on a tablet spends battery and thermal headroom the
  /// 60-second stitch is going to need. [maxPreviewWidth] covers every phone
  /// display shipping today within a few percent, and both platforms clamp further
  /// to what the chosen camera format can actually deliver.
  static CaptureFormatSpec _sizedForDisplay(CaptureFormatSpec format) {
    if (format.previewTargetWidth > 0) return format;
    final view = ui.PlatformDispatcher.instance.implicitView;
    final size = view?.physicalSize;
    final longEdge = size == null
        ? 0.0
        : (size.width > size.height ? size.width : size.height);
    final target = longEdge.isFinite && longEdge > 0
        ? longEdge.round().clamp(minPreviewWidth, maxPreviewWidth)
        : defaultPreviewWidth;
    return format.copyWith(previewTargetWidth: target);
  }

  /// Floor for an auto-sized preview: below this, aiming suffers on any display.
  static const int minPreviewWidth = 1280;

  /// Ceiling for an auto-sized preview (§4's battery and thermal argument).
  static const int maxPreviewWidth = 2560;

  /// Used when the display cannot be measured — a headless test, or a platform
  /// with no implicit view.
  static const int defaultPreviewWidth = 1280;

  /// Whether two intrinsics describe the same camera closely enough that a
  /// half-captured plan is still valid. 0.5% of focal is far tighter than the
  /// 4% that stops a panorama closing, and far looser than float noise.
  static bool _intrinsicsMatch(CameraIntrinsics a, CameraIntrinsics b) =>
      (a.fx - b.fx).abs() <= 0.005 * b.fx &&
      (a.fy - b.fy).abs() <= 0.005 * b.fy &&
      a.imageSize == b.imageSize;

  static Future<Directory> _defaultDirectory(String sessionId) async {
    final root = await getApplicationDocumentsDirectory();
    return Directory(p.join(root.path, 'sphere_view', sessionId));
  }
}
