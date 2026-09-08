import 'dart:async';

import '../api/models/image_size.dart';
import 'camera_platform.dart';
import 'intrinsics_resolver.dart';
import 'messages.g.dart' as wire;

/// [SphereCameraPlatform] over the Pigeon-generated channel.
///
/// This is the only file that touches the wire types, and it does exactly two
/// things: translate, and run the intrinsics chain. Both belong here rather
/// than on either side of the boundary — the native halves report facts and do
/// no arithmetic (see `intrinsics_resolver.dart` for why), and the rest of the
/// package speaks in model types that `tools/replay` can load without a Flutter
/// engine.
class PigeonCameraPlatform implements SphereCameraPlatform {
  /// Creates a platform over the real channel.
  ///
  /// Set [receiveCallbacks] to `false` for an instance that only makes host
  /// calls and never listens.
  ///
  /// **`SphereCameraFlutterApi.setUp` installs a process-wide handler**, so the
  /// last instance to register wins and every earlier one silently stops
  /// receiving frame timestamps, thermal transitions, errors and interruptions.
  /// That is a real hazard rather than a theoretical one: the stitch queue
  /// wants to ask how hot the device is, and if asking meant constructing a
  /// second platform, a manager who queued a station and carried on capturing
  /// would find the capture session had gone deaf — no shutter timestamps, no
  /// interruption handling — for reasons nothing in the capture code could
  /// explain. A caller that only needs `thermalState()` or
  /// `totalPhysicalMemoryMb()` passes `false` and takes nothing away from
  /// whoever owns the camera.
  ///
  /// It took an injectable `api` until Phase 13's API audit found that nothing
  /// had ever passed one, and that the parameter put a generated wire type into
  /// a public constructor. Tests fake [SphereCameraPlatform] itself, one layer
  /// up, which is the seam that is worth having.
  PigeonCameraPlatform({bool receiveCallbacks = true})
    : _api = wire.SphereCameraHostApi() {
    if (receiveCallbacks) wire.SphereCameraFlutterApi.setUp(_Callbacks(this));
  }

  final wire.SphereCameraHostApi _api;

  final _previewTimestamps = StreamController<int>.broadcast();
  final _thermalStates = StreamController<ThermalState>.broadcast();
  final _errors = StreamController<CameraPlatformError>.broadcast();
  final _interruptions = StreamController<SessionInterruption>.broadcast();

  @override
  Stream<int> get previewTimestamps => _previewTimestamps.stream;

  @override
  Stream<ThermalState> get thermalStates => _thermalStates.stream;

  @override
  Stream<CameraPlatformError> get errors => _errors.stream;

  @override
  Stream<SessionInterruption> get interruptions => _interruptions.stream;

  @override
  Future<List<CameraDescriptor>> listCameras() async {
    final cameras = await _api.listCameras();
    return [for (final c in cameras) _descriptor(c)];
  }

  @override
  Future<CameraOpenResult> open(
    String cameraId,
    CaptureFormatSpec format,
  ) async {
    final result = await _api.open(
      cameraId,
      wire.CaptureFormatRequest(
        captureSize: format.captureSize == null
            ? null
            : wire.PlatformSize(
                width: format.captureSize!.width.round(),
                height: format.captureSize!.height.round(),
              ),
        preferFourThree: format.preferFourThree,
        previewTargetWidth: format.previewTargetWidth,
        format: format.useDeferredJpegEncode
            ? wire.PlatformCaptureFormat.yuvDeferredJpeg
            : wire.PlatformCaptureFormat.jpeg,
        jpegQuality: format.jpegQuality,
        computeFrameStatistics: format.computeFrameStatistics,
      ),
    );

    final captureSize = _size(result.captureSize);

    // The chain runs here, once, over whichever platform's facts arrived. A
    // result with neither is a plugin that opened a camera and forgot to say
    // what it opened — worth failing loudly, because the alternative is a
    // panorama built on a guessed focal.
    final IntrinsicsResolution resolution;
    if (result.androidFacts != null) {
      resolution = IntrinsicsResolver.resolveAndroid(
        result.androidFacts!,
        captureSize,
      );
    } else if (result.iosFacts != null) {
      resolution = IntrinsicsResolver.resolveIos(
        result.iosFacts!,
        captureSize,
      );
    } else {
      throw const IntrinsicsUnavailable('unknown', [
        'the platform returned neither androidFacts nor iosFacts',
      ]);
    }

    return CameraOpenResult(
      intrinsics: resolution.intrinsics,
      intrinsicsBranch: resolution.branch,
      intrinsicsNotes: resolution.notes,
      captureSize: captureSize,
      previewSize: _size(result.previewSize),
      sensorOrientationDegrees: result.sensorOrientationDegrees,
      previewRotationDegrees: result.previewRotationDegrees,
      previewHandlesRotation: result.previewHandlesRotation,
      clock: _clock(result.clock),
      bracketMode: _bracketMode(result.bracketMode),
      maxBracketCount: result.maxBracketCount,
      captureAspectIsFourThree: result.captureAspectIsFourThree,
      warning: result.warning,
    );
  }

  @override
  Future<int> attachPreview() => _api.attachPreview();

  @override
  Future<void> detachPreview() => _api.detachPreview();

  @override
  Future<MeteringResult> meterAndLock(Duration duration) async {
    final r = await _api.meterAndLock(duration.inMicroseconds / 1e6);
    return MeteringResult(
      exposureTimeNs: r.exposureTimeNs,
      iso: r.iso,
      colorTemperatureK: r.colorTemperatureK,
      focusDistanceDiopters: r.focusDistanceDiopters,
      lockQuality: switch (r.lockQuality) {
        wire.PlatformLockQuality.fullyLocked => ExposureLockQuality.fullyLocked,
        wire.PlatformLockQuality.bestEffort => ExposureLockQuality.bestEffort,
        wire.PlatformLockQuality.unlocked => ExposureLockQuality.unlocked,
      },
      sampleCount: r.sampleCount,
      chosenEv: r.chosenEv,
      meanEv: r.meanEv,
      percentile65Ev: r.percentile65Ev,
      aeConverged: r.aeConverged,
      pinnedProcessingModes: r.pinnedProcessingModes,
      note: r.note,
    );
  }

  @override
  Future<void> unlock() => _api.unlock();

  @override
  Future<BracketCapture> captureBracket(
    List<double> evBiases, {
    required String outputDirectory,
    required String namePrefix,
  }) async {
    final r = await _api.captureBracket(evBiases, outputDirectory, namePrefix);
    return BracketCapture(
      frames: [for (final f in r.frames) _frame(f)],
      burstWallClockMs: r.burstWallClockMs,
      shutterToShutterMs: r.shutterToShutterMs,
      mode: _bracketMode(r.mode),
      clampedExposure: r.clampedExposure,
      clampedIso: r.clampedIso,
      deferredEncodeMs: r.deferredEncodeMs,
      note: r.note,
    );
  }

  @override
  Future<ThermalState> thermalState() async =>
      _thermal(await _api.thermalState());

  @override
  Future<ClockOffsetSample> sampleClockOffset() async {
    final s = await _api.sampleClockOffset();
    return ClockOffsetSample(
      cameraClockUs: s.cameraClockUs,
      motionClockUs: s.motionClockUs,
      offsetUs: s.offsetUs,
      uncertaintyUs: s.uncertaintyUs,
    );
  }

  @override
  Future<DeviceIdentity> deviceIdentity() async {
    final id = await _api.deviceIdentity();
    return DeviceIdentity(
      make: id.make,
      model: id.model,
      osVersion: id.osVersion,
    );
  }

  @override
  Future<int> maxTextureSize() => _api.maxTextureSize();

  @override
  Future<int> totalPhysicalMemoryMb() => _api.totalPhysicalMemoryMb();

  @override
  Future<int> availableProcessMemoryMb() => _api.availableProcessMemoryMb();

  @override
  Future<int> batteryPercent() => _api.batteryPercent();

  @override
  Future<void> close() => _api.close();

  /// Closes the callback streams. Separate from [close] because a session may
  /// close and reopen the camera while the same platform object lives on.
  Future<void> dispose() async {
    wire.SphereCameraFlutterApi.setUp(null);
    await _previewTimestamps.close();
    await _thermalStates.close();
    await _errors.close();
    await _interruptions.close();
  }

  // ----------------------------------------------------------- mapping --

  static ImageSize _size(wire.PlatformSize s) =>
      ImageSize.fromInts(s.width, s.height);

  static CameraDescriptor _descriptor(wire.CameraDescriptor c) =>
      CameraDescriptor(
        id: c.id,
        facing: switch (c.facing) {
          wire.PlatformCameraFacing.back => CameraFacing.back,
          wire.PlatformCameraFacing.front => CameraFacing.front,
          wire.PlatformCameraFacing.external => CameraFacing.external,
        },
        availableSizes: [for (final s in c.availableSizes) _size(s)],
        focalLengthsMm: c.focalLengthsMm,
        supportsBracketing: c.supportsBracketing,
        maxBracketCount: c.maxBracketCount,
        hasDistortionModel: c.hasDistortionModel,
        hasManualSensor: c.hasManualSensor,
        hardwareLevel: c.hardwareLevel.name,
        isLogicalMultiCamera: c.isLogicalMultiCamera,
        excludedReason: c.excludedReason,
      );

  static PlatformFrame _frame(wire.PlatformFrame f) => PlatformFrame(
    filePath: f.filePath,
    evBias: f.evBias,
    timestampUs: f.timestampUs,
    byteCount: f.byteCount,
    exposureTimeNs: f.exposureTimeNs,
    iso: f.iso,
    achievedEvBias: f.achievedEvBias,
    meanR: f.meanR,
    meanG: f.meanG,
    meanB: f.meanB,
    note: f.note,
  );

  static ClockSync _clock(wire.ClockSyncInfo c) => ClockSync(
    base: switch (c.base) {
      wire.PlatformTimestampBase.androidRealtime =>
        TimestampBase.androidRealtime,
      wire.PlatformTimestampBase.androidMonotonicUnknown =>
        TimestampBase.androidMonotonicUnknown,
      wire.PlatformTimestampBase.iosHostTime => TimestampBase.iosHostTime,
    },
    offsetUs: c.offsetUs,
    uncertaintyUs: c.uncertaintyUs,
    note: c.note,
  );

  static BracketMode _bracketMode(wire.PlatformBracketMode m) => switch (m) {
    wire.PlatformBracketMode.manualExposureBurst =>
      BracketMode.manualExposureBurst,
    wire.PlatformBracketMode.aeCompensationBurst =>
      BracketMode.aeCompensationBurst,
    wire.PlatformBracketMode.photoBracket => BracketMode.photoBracket,
    wire.PlatformBracketMode.sequentialManual => BracketMode.sequentialManual,
    wire.PlatformBracketMode.singleShot => BracketMode.singleShot,
  };

  static ThermalState _thermal(wire.PlatformThermalState s) => switch (s) {
    wire.PlatformThermalState.nominal => ThermalState.nominal,
    wire.PlatformThermalState.fair => ThermalState.fair,
    wire.PlatformThermalState.serious => ThermalState.serious,
    wire.PlatformThermalState.critical => ThermalState.critical,
  };
}

/// The `FlutterApi` half: everything the native side pushes without being
/// asked.
class _Callbacks implements wire.SphereCameraFlutterApi {
  _Callbacks(this._owner);

  final PigeonCameraPlatform _owner;

  @override
  void onFrameAvailable(int timestampUs) =>
      _owner._previewTimestamps.add(timestampUs);

  @override
  void onError(String code, String message) =>
      _owner._errors.add(CameraPlatformError(code, message));

  @override
  void onThermalStateChanged(wire.PlatformThermalState state) =>
      _owner._thermalStates.add(PigeonCameraPlatform._thermal(state));

  @override
  void onSessionInterrupted(bool interrupted, String reason) =>
      _owner._interruptions.add(
        SessionInterruption(interrupted: interrupted, reason: reason),
      );
}
