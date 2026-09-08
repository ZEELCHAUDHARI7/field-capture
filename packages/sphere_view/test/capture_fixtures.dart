/// Fixtures for the Phase 08 tests: a fleet of intrinsics to plan against, and
/// fakes for the two things a capture session cannot be tested without.
///
/// The fakes are the point. Planning and guidance are pure functions and need
/// nothing, but the *orchestration* — write to disk immediately, rewrite the
/// manifest after every position, survive a kill, finish honestly on a partial
/// sphere — is exactly the part that would otherwise only ever be exercised by
/// standing in a building with a tablet. Behind [FakeCameraPlatform] and
/// [FakePoseSource] it runs in milliseconds, deterministically, including the
/// crash.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:sphere_view/sphere_view.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart';

/// Radians per degree. Named `deg` rather than `degrees` because `vector_math`
/// already exports a `degrees()` function, and a test importing both would not
/// compile.
const double deg = math.pi / 180;

/// Portrait intrinsics with the given fields of view, as a real main camera
/// would report them once expressed in the device frame.
///
/// Height is derived from the two angles rather than assumed 4:3, because the
/// worked example in Math §8 (50° × 69°) is not a 4:3 frame and rounding it to
/// one would change the ring count the example is quoted for.
CameraIntrinsics fovIntrinsics(
  double hfovDegrees,
  double vfovDegrees, {
  double width = 3024,
  IntrinsicsSource source = IntrinsicsSource.derivedFromPhysics,
}) {
  final fx = (width / 2) / math.tan(hfovDegrees * deg / 2);
  final height = 2 * fx * math.tan(vfovDegrees * deg / 2);
  return CameraIntrinsics(
    fx: fx,
    fy: fx,
    cx: width / 2,
    cy: height.roundToDouble() / 2,
    imageSize: ImageSize(width, height.roundToDouble()),
    source: source,
  );
}

/// Portrait 4:3 intrinsics at a given horizontal field of view.
CameraIntrinsics fourThree(
  double hfovDegrees, {
  double width = 3024,
  IntrinsicsSource source = IntrinsicsSource.derivedFromPhysics,
}) => CameraIntrinsics.fromHorizontalFov(
  hfovRadians: hfovDegrees * deg,
  imageSize: ImageSize(width, width * 4 / 3),
  source: source,
);

/// One entry in the device fleet the plan has to work for.
class DeviceFixture {
  const DeviceFixture(this.name, this.intrinsics, this.note);

  /// What the device is.
  final String name;

  /// What its main camera reports, in the device's portrait frame.
  final CameraIntrinsics intrinsics;

  /// Where the numbers come from.
  final String note;

  @override
  String toString() => name;
}

/// The intrinsics the default plan must cover the sphere for.
///
/// **These are derived from published optics, not measured.** Spike B — the
/// capability dump across the real fleet — still needs a device run, and when it
/// lands this list should be replaced by what it recorded. Until then the span
/// is what matters: architecture §2 puts real main-camera HFOV in portrait at
/// roughly 46°–56°, so the list brackets that range at both ends and includes a
/// 16:9 stream, where the vertical field is unusually large and the ring
/// structure changes shape.
List<DeviceFixture> get fleet => [
  DeviceFixture(
    'math §8 worked example',
    fovIntrinsics(50, 69),
    'the 50° × 69° example the ring arithmetic is quoted for',
  ),
  DeviceFixture(
    'tablet, narrow main camera',
    fourThree(46),
    'the narrow end of the 46°–56° range in architecture §2',
  ),
  DeviceFixture(
    'tablet, typical main camera',
    fourThree(50),
    'mid-range; also what the synthetic harness plans at',
  ),
  DeviceFixture(
    'iPad-class main camera',
    fourThree(55),
    'videoFieldOfView on a current iPad rear camera, 4:3 photo preset',
  ),
  DeviceFixture(
    'tablet, wide main camera',
    fourThree(56),
    'the wide end of the range',
  ),
  DeviceFixture(
    '16:9 stream, no 4:3 size offered',
    CameraIntrinsics.fromHorizontalFov(
      hfovRadians: 50 * deg,
      imageSize: const ImageSize(2160, 3840),
    ),
    'the case Phase 06 §7 pitfall 5 warns about: a crop, not a scale',
  ),
  DeviceFixture(
    'low-resolution preview-class stream',
    CameraIntrinsics.fromHorizontalFov(
      hfovRadians: 50 * deg,
      imageSize: const ImageSize(480, 640),
    ),
    'what the Phase 02 harness renders, so the two agree on the same plan',
  ),
];

/// A pose aimed exactly at [yaw]/[pitch], with an optional roll about the
/// optical axis and an optional residual angular speed.
DevicePose poseAimedAt(
  double yaw,
  double pitch, {
  double rollRadians = 0,
  double angularSpeedRadPerSec = 0,
  int timestampUs = 1000000,
}) {
  final aim = SphericalConventions.aimingDeviceToWorld(yaw, pitch);
  // Roll is about the optical axis, which in the device frame is −Z, so it
  // composes on the right: the device turns in its own frame.
  final rolled = aim * Matrix3.rotationZ(-rollRadians);
  final q = Quaternion.fromRotation(rolled)..normalize();
  return DevicePose(
    deviceToWorld: q,
    gravityWorld: Vector3(0, 1, 0),
    timestampUs: timestampUs,
    angularSpeedRadPerSec: angularSpeedRadPerSec,
  );
}

/// A pose aimed at [target].
DevicePose poseAtTarget(
  CaptureTarget target, {
  double angularSpeedRadPerSec = 0,
  int timestampUs = 1000000,
}) => poseAimedAt(
  target.yaw,
  target.pitch,
  // At a pole the target's yaw *is* the roll (Math §8's second polar frame),
  // and `aimingDeviceToWorld` already builds it in — so nothing extra is
  // needed here, and adding a roll would double it.
  angularSpeedRadPerSec: angularSpeedRadPerSec,
  timestampUs: timestampUs,
);

/// A camera that writes real files and answers plausibly, with none of the
/// hardware.
class FakeCameraPlatform implements SphereCameraPlatform {
  FakeCameraPlatform({
    CameraIntrinsics? intrinsics,
    this.sensorOrientationDegrees = 0,
    this.previewSize = const ImageSize(1280, 960),
    this.previewRotationDegrees,
    this.previewHandlesRotation = false,
    this.shotsPerBracket = 3,
    this.failNextCapture = false,
    this.bracketMode = BracketMode.manualExposureBurst,
    this.maxBracketCount = 3,
    this.cameras,
    this.throwOnMemory = false,
    int? totalMemoryMb,
    int? availableMemoryMb,
  }) : intrinsics = intrinsics ?? fourThree(50) {
    if (totalMemoryMb != null) this.totalMemoryMb = totalMemoryMb;
    if (availableMemoryMb != null) this.availableMemoryMb = availableMemoryMb;
  }

  /// The descriptors `listCameras` returns, or `null` for the default one.
  ///
  /// Exists for the Phase 12 §1 capability probe, whose whole job is to answer
  /// differently for different hardware — so the fleet's capability sets have to
  /// be expressible without a device.
  final List<CameraDescriptor>? cameras;

  /// Makes the memory queries throw, which is the branch that puts the tier on
  /// its conservative fallback.
  final bool throwOnMemory;

  /// How many times `open` was called. The capability probe must not open a
  /// camera at all: an entry-point gate that costs a camera open is one that
  /// callers move later in the flow, and a moved gate is no gate.
  int openCalls = 0;

  /// The bracket path `open` claims this device will take.
  final BracketMode bracketMode;

  /// How many frames `open` says one bracket may contain.
  final int maxBracketCount;

  /// What `open` reports, in the capture stream's own frame.
  final CameraIntrinsics intrinsics;

  /// Sensor mounting angle, as `CameraOpenResult` carries it.
  final int sensorOrientationDegrees;

  /// The preview stream size the platform reports, in the sensor's own frame.
  final ImageSize previewSize;

  /// What the platform claims the preview still needs. `null` mirrors the sensor
  /// mounting, which is what a platform that does not handle rotation reports.
  final int? previewRotationDegrees;

  /// Whether the platform claims its render path already turned the buffer.
  final bool previewHandlesRotation;

  /// How many frames a bracket returns, regardless of how many were asked for —
  /// so a test can reproduce the device that cannot bracket.
  final int shotsPerBracket;

  /// Makes the next `captureBracket` throw.
  bool failNextCapture;

  /// The shutter timestamp the next bracket reports. Tests set it to the pose
  /// clock so the frame lands inside the buffered window.
  int nextShutterUs = 1000000;

  /// Every bracket requested, in order.
  final List<List<double>> requestedBiases = [];

  /// Files written, in order.
  final List<String> written = [];

  bool closed = false;
  bool unlocked = false;
  int meteringCalls = 0;

  final _thermal = StreamController<ThermalState>.broadcast();
  final _interruptions = StreamController<SessionInterruption>.broadcast();
  final _errors = StreamController<CameraPlatformError>.broadcast();
  final _preview = StreamController<int>.broadcast();

  /// Pushes a thermal transition at the session.
  void emitThermal(ThermalState state) => _thermal.add(state);

  /// Pushes an interruption, or its end, at the session.
  void emitInterruption(bool interrupted, String reason) =>
      _interruptions.add(
        SessionInterruption(interrupted: interrupted, reason: reason),
      );

  @override
  Future<List<CameraDescriptor>> listCameras() async =>
      cameras ??
      [
        CameraDescriptor(
          id: 'back-0',
          facing: CameraFacing.back,
          availableSizes: [intrinsics.imageSize],
          focalLengthsMm: const [4.25],
          supportsBracketing: true,
          maxBracketCount: 3,
          hasDistortionModel: false,
          hasManualSensor: true,
          hardwareLevel: 'FULL',
          isLogicalMultiCamera: false,
        ),
      ];

  @override
  Future<CameraOpenResult> open(String cameraId, CaptureFormatSpec format) async {
    ++openCalls;
    return CameraOpenResult(
        intrinsics: intrinsics,
        intrinsicsBranch: 'test.fake',
        intrinsicsNotes: const [],
        captureSize: intrinsics.imageSize,
        // Landscape, like every real camera preview stream: both platforms hand
        // back the sensor's own buffer, and it is the *view* that turns it
        // upright. A portrait fixture here — which is what this used to be —
        // quietly exercises the one case a device never produces, so the rotation
        // the view has to apply was never under test.
        previewSize: previewSize,
        sensorOrientationDegrees: sensorOrientationDegrees,
        // Defaults model a device that does NOT handle rotation — an Android
        // ImageReader backend, or iOS — so the fixture exercises the branch that
        // actually applies a turn. `previewHandlesRotation: true` with
        // `previewRotationDegrees: 0` is the other branch, and both are tested.
        previewRotationDegrees: previewRotationDegrees ?? sensorOrientationDegrees,
        previewHandlesRotation: previewHandlesRotation,
        clock: const ClockSync(
          base: TimestampBase.androidRealtime,
          offsetUs: 0,
          uncertaintyUs: 0,
          note: 'fake',
        ),
        bracketMode: bracketMode,
        maxBracketCount: maxBracketCount,
        captureAspectIsFourThree: true,
    );
  }

  @override
  Future<int> attachPreview() async => 1;

  @override
  Future<void> detachPreview() async {}

  @override
  Future<MeteringResult> meterAndLock(Duration duration) async {
    meteringCalls++;
    return const MeteringResult(
      exposureTimeNs: 16666667,
      iso: 400,
      colorTemperatureK: 4200,
      focusDistanceDiopters: 0,
      lockQuality: ExposureLockQuality.fullyLocked,
      sampleCount: 60,
      chosenEv: 0,
      meanEv: 0.4,
      percentile65Ev: 0,
      aeConverged: true,
      pinnedProcessingModes: true,
    );
  }

  @override
  Future<void> unlock() async => unlocked = true;

  @override
  Future<BracketCapture> captureBracket(
    List<double> evBiases, {
    required String outputDirectory,
    required String namePrefix,
  }) async {
    if (failNextCapture) {
      failNextCapture = false;
      throw StateError('the burst was dropped');
    }
    requestedBiases.add(List.of(evBiases));
    final biases = evBiases.take(shotsPerBracket).toList();
    final frames = <PlatformFrame>[];
    for (final bias in biases) {
      final name = '${namePrefix}_ev${bias.toStringAsFixed(0)}.jpg';
      final file = File('$outputDirectory${Platform.pathSeparator}$name');
      await file.parent.create(recursive: true);
      // Real bytes, because "frames are written to disk immediately" is one of
      // the claims under test — a fake that only returned a path would let a
      // session that held everything in memory pass.
      await file.writeAsBytes(List<int>.filled(64, 0xAB));
      written.add(file.path);
      frames.add(
        PlatformFrame(
          filePath: file.path,
          evBias: bias,
          timestampUs: nextShutterUs,
          byteCount: 64,
          exposureTimeNs: 16666667,
          iso: 400,
        ),
      );
    }
    return BracketCapture(
      frames: frames,
      burstWallClockMs: 420,
      shutterToShutterMs: const [120, 120],
      mode: BracketMode.manualExposureBurst,
      clampedExposure: false,
      clampedIso: false,
      deferredEncodeMs: 0,
    );
  }

  @override
  Future<ThermalState> thermalState() async => currentThermalState;

  /// What [thermalState] answers. Settable so the stitch queue's "skip when
  /// hot" rule can be driven without a hot device.
  ThermalState currentThermalState = ThermalState.nominal;

  @override
  Future<ClockOffsetSample> sampleClockOffset() async => const ClockOffsetSample(
    cameraClockUs: 0,
    motionClockUs: 0,
    offsetUs: 0,
    uncertaintyUs: 0,
  );

  /// A fake device that names itself, so the EXIF Make/Model path is exercised
  /// by the session tests rather than only by the metadata unit tests.
  @override
  Future<DeviceIdentity> deviceIdentity() async => identity;

  /// What [deviceIdentity] answers.
  DeviceIdentity identity = const DeviceIdentity(
    make: 'FakeCorp',
    model: 'Tablet-1',
    osVersion: 'FakeOS 1.0',
  );

  /// A GPU that caps at 4096 — the mid-range tablet Phase 11 §3.1 is about,
  /// not the generous one, so the default fixture exercises the downscale path
  /// rather than the one where nothing has to happen.
  @override
  Future<int> maxTextureSize() async => maxTextureSizePx;

  /// What [maxTextureSize] answers.
  int maxTextureSizePx = 4096;

  @override
  Future<int> totalPhysicalMemoryMb() async {
    if (throwOnMemory) throw StateError('the platform declined to answer');
    return totalMemoryMb;
  }

  @override
  Future<int> availableProcessMemoryMb() async {
    if (throwOnMemory) throw StateError('the platform declined to answer');
    return availableMemoryMb;
  }

  @override
  Future<int> batteryPercent() async => batteryPercentValue;

  /// What the battery reads. Decremented by a test that wants to watch a drain.
  int batteryPercentValue = 87;

  /// What the tier probe sees as total RAM. 6144 puts the fake on `high`.
  int totalMemoryMb = 6144;

  /// What the pre-flight check sees. `-1` is Android's "I cannot say", which
  /// is the default because it is the branch that must not downgrade anything.
  int availableMemoryMb = -1;

  @override
  Future<void> close() async {
    closed = true;
    await _thermal.close();
    await _interruptions.close();
    await _errors.close();
    await _preview.close();
  }

  @override
  Stream<int> get previewTimestamps => _preview.stream;

  @override
  Stream<ThermalState> get thermalStates => _thermal.stream;

  @override
  Stream<CameraPlatformError> get errors => _errors.stream;

  @override
  Stream<SessionInterruption> get interruptions => _interruptions.stream;
}

/// A pose source the test drives by hand.
class FakePoseSource implements PoseSource {
  FakePoseSource({
    this.supported = true,
    this.supportOverride,
    this.throwOnSupport = false,
  });

  /// Whether this stands in for a device with the sensors.
  final bool supported;

  /// A whole capability record, for a case [supported] cannot express — a device
  /// with a gyroscope but no gravity vector, say.
  final PoseSupport? supportOverride;

  /// Makes `support` throw, which is a different case from a device that answers
  /// "no gyroscope": the capability probe must refuse either way rather than let
  /// the exception reach a caller that is only asking whether to show a button.
  final bool throwOnSupport;

  final _poses = StreamController<DevicePose>.broadcast();
  bool started = false;
  bool stopped = false;

  /// Publishes one pose.
  void emit(DevicePose pose) => _poses.add(pose);

  @override
  Future<bool> get isSupported async => supported;

  @override
  Future<PoseSupport> get support async {
    if (throwOnSupport) {
      throw StateError('the motion service is unavailable');
    }
    return supportOverride ?? _describe();
  }

  PoseSupport _describe() => PoseSupport(
    hasGyroscope: supported,
    hasAccelerometer: true,
    hasFusedRotation: supported,
    hasGravity: true,
    usesMagnetometer: false,
    frame: PoseReferenceFrame.androidGameRotationVector,
    minDelayUs: 5000,
    detail: supported ? 'fake pose source' : 'fake gyro-less device',
    unsupportedReason: supported
        ? null
        : 'this tablet has no gyroscope, so a 360 cannot be captured on it',
  );

  @override
  Stream<DevicePose> get poses => _poses.stream;

  @override
  Future<void> start() async {
    final found = await support;
    if (!found.isSupported) throw PoseSourceUnsupported(found);
    started = true;
  }

  @override
  Future<void> stop() async => stopped = true;

  /// Closes the stream.
  Future<void> dispose() => _poses.close();
}

/// A wakelock that records rather than calls a plugin.
class FakeWakelock implements CaptureWakelock {
  bool acquired = false;
  bool released = false;

  @override
  Future<String?> acquire() async {
    acquired = true;
    return null;
  }

  @override
  Future<void> release() async => released = true;
}

/// One camera descriptor, with every capability a test might want to move.
///
/// Named for what it defaults to — a full-stack device — so a call site reads as
/// only the ways the device it stands for falls short, which is the same
/// argument `SynthProfile` makes for its own defaults. The Phase 12 §1
/// capability probe answers differently for different hardware, so the fleet's
/// capability sets have to be expressible without the fleet.
CameraDescriptor fullCapabilityCamera({
  String id = 'back-0',
  bool supportsBracketing = true,
  int maxBracketCount = 3,
  bool hasDistortionModel = true,
  bool hasManualSensor = true,
  String hardwareLevel = 'FULL',
  bool isLogicalMultiCamera = true,
  CameraFacing facing = CameraFacing.back,
}) => CameraDescriptor(
  id: id,
  facing: facing,
  availableSizes: const [ImageSize(3024, 4032)],
  focalLengthsMm: const [4.25],
  supportsBracketing: supportsBracketing,
  maxBracketCount: maxBracketCount,
  hasDistortionModel: hasDistortionModel,
  hasManualSensor: hasManualSensor,
  hardwareLevel: hardwareLevel,
  isLogicalMultiCamera: isLogicalMultiCamera,
);
