import 'dart:async';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../api/models/device_pose.dart';
import '../utils/quaternion_utils.dart';
import 'pigeon_pose_platform.dart';
import 'pose_buffer.dart';
import 'pose_frame_conversion.dart';
import 'pose_platform.dart';
import 'pose_source.dart';

/// Counters describing how a pose stream actually behaved, for the bundle and
/// for the device report.
///
/// Every field here is a number that turns "the panorama came out odd" into a
/// specific question. Architecture §8's rule is never to degrade silently; a
/// stream that spent 4 s warming up, dropped 200 samples, or saw its up vector
/// point the wrong way is degraded, and this is where it says so.
class PoseStreamDiagnostics {
  /// Creates a diagnostics snapshot.
  const PoseStreamDiagnostics({
    required this.received,
    required this.emitted,
    required this.droppedWarmingUp,
    required this.droppedUpsideDown,
    required this.droppedOutOfOrder,
    required this.signFlipsCorrected,
    required this.missedSequences,
    required this.worstUpTiltDegrees,
    required this.warmUpTaken,
    this.stream,
  });

  /// Raw samples that arrived from the platform.
  final int received;

  /// Poses handed on to the buffer and to listeners.
  final int emitted;

  /// Samples discarded before the yaw datum was latched (§6 pitfall 2).
  final int droppedWarmingUp;

  /// Samples whose measured up did not rotate to world up, and which were
  /// therefore refused rather than published. Non-zero after start-up means
  /// the frame conversion and the gravity sensor disagree on this device.
  final int droppedUpsideDown;

  /// Samples the buffer rejected for arriving out of order.
  final int droppedOutOfOrder;

  /// How often the platform flipped `q` to `−q` between adjacent samples and
  /// this class flipped it back (§6 pitfall 4).
  final int signFlipsCorrected;

  /// Gaps in the platform's own sequence counter: samples the sensor produced
  /// and the channel did not deliver. Distinct from a sensor that simply ran
  /// slow, which is why the counter is on the wire at all.
  final int missedSequences;

  /// Largest angle between measured up and world `+Y`, in degrees. The AHRS's
  /// own disagreement with its own gravity estimate — normally a few
  /// hundredths of a degree, and ~180° if a sign convention is wrong.
  final double worstUpTiltDegrees;

  /// How long the stream took to produce its first usable pose.
  final Duration warmUpTaken;

  /// How the stream was configured, once started.
  final PoseStreamStart? stream;

  /// Serialised into `device_info`.
  Map<String, Object?> toJson() => {
    'received': received,
    'emitted': emitted,
    'dropped_warming_up': droppedWarmingUp,
    'dropped_upside_down': droppedUpsideDown,
    'dropped_out_of_order': droppedOutOfOrder,
    'sign_flips_corrected': signFlipsCorrected,
    'missed_sequences': missedSequences,
    'worst_up_tilt_degrees': worstUpTiltDegrees,
    'warm_up_ms': warmUpTaken.inMilliseconds,
    'stream': stream?.toJson(),
  };

  @override
  String toString() =>
      'PoseStreamDiagnostics($emitted/$received emitted, '
      'warm-up ${warmUpTaken.inMilliseconds} ms, '
      'worst up tilt ${worstUpTiltDegrees.toStringAsFixed(3)}°)';
}

/// The production pose source: the OS's own sensor fusion, via Android's
/// `TYPE_GAME_ROTATION_VECTOR` and iOS's `CMDeviceMotion`.
///
/// Exists to replace a hand-rolled gyro-integration-plus-complementary-filter
/// that was good to roughly ±2–5° — at a 6144-wide equirect, 35–85 px of
/// misregistration on every seam (architecture §2 defect 1). The OS filters win
/// for two concrete reasons, not out of deference: they estimate and correct
/// gyro bias and scale continuously, and they are calibrated per device model
/// in ways an app cannot replicate.
///
/// **`GAME_ROTATION_VECTOR`, not `ROTATION_VECTOR`**, and `CMDeviceMotion`
/// without a true-north reference frame: both exclude the magnetometer.
/// Indoors, rebar, lift motors and steel studs bend magnetic heading by tens of
/// degrees, and an aim gate that needs ~5° accuracy would simply never fire
/// (Math §1.1). Yaw being relative to session start is a feature here, not a
/// limitation.
///
/// Four things happen between the platform's samples and this class's stream,
/// and each of them is one of Phase 07's stated hazards:
///
/// 1. **Frame conversion** (§2), in [PoseFrameConversion], where the whole
///    question is a determinant.
/// 2. **A gravity cross-check**, which refuses a device whose measured up does
///    not rotate to world up — the detectable half of §2's reflection hazard.
/// 3. **Warm-up** (§6 pitfall 2): `CMDeviceMotion` needs 1–2 s to converge, so
///    early samples are discarded and the yaw datum is latched only once the
///    stream is producing consistent attitudes.
/// 4. **Sign canonicalisation** (§6 pitfall 4): `q` and `−q` are the same
///    rotation, and a platform that flips between them hands every downstream
///    consumer a 360° spin between adjacent samples.
class PlatformAhrsPoseSource implements PoseSource {
  /// Creates the platform-backed pose source.
  ///
  /// [platform] defaults to the real Pigeon channel; tests pass a fake, which
  /// is what makes the conversion, the warm-up and the yaw datum testable
  /// without a device.
  PlatformAhrsPoseSource({
    SpherePosePlatform? platform,
    this.samplingPeriod = defaultSamplingPeriod,
    this.warmUp = defaultWarmUp,
    this.warmUpSamples = 20,
    int bufferCapacity = 400,
  }) : _platform = platform ?? PigeonPosePlatform(),
       buffer = PoseBuffer(capacity: bufferCapacity);

  /// §4's rate: 100 Hz. Enough given SLERP — nearest-sample lookup at this rate
  /// is already only 5 ms out, and interpolation takes the residual to well
  /// under 0.05° at a realistic pan. Higher rates cost battery and thermal
  /// headroom the stitch will need, for no measurable accuracy gain.
  static const Duration defaultSamplingPeriod = Duration(microseconds: 10000);

  /// How long to discard samples for before latching the yaw datum.
  ///
  /// §6 pitfall 2 gives 1–2 s for `CMDeviceMotion` to converge after
  /// `startDeviceMotionUpdates`. 1.5 s sits inside that and is short enough to
  /// hide behind the metering pre-sweep, which runs for 2 s anyway (architecture
  /// §4 step 3) — so in a real session the warm-up costs nothing at all.
  static const Duration defaultWarmUp = Duration(milliseconds: 1500);

  /// Cosine of the angle beyond which measured up is judged to be pointing the
  /// wrong way.
  ///
  /// 0.5, i.e. 60°, is deliberately loose. The failure it exists to catch is a
  /// **sign convention** — an up vector that comes out at ~180° — not a small
  /// tilt error, and a tight threshold here would turn a device with a
  /// momentarily disagreeing filter into a refused capture. The real tilt is
  /// reported as a number ([PoseStreamDiagnostics.worstUpTiltDegrees]) rather
  /// than gated on, because Math §7 consumes it as data and the levelling step
  /// is where it belongs.
  static const double minUpCosine = 0.5;

  final SpherePosePlatform _platform;

  /// The requested sampling period.
  final Duration samplingPeriod;

  /// The convergence window before the first pose is published.
  final Duration warmUp;

  /// Consecutive consistent samples required before the yaw datum is latched,
  /// in addition to [warmUp] elapsing. A timer alone would accept whatever the
  /// filter happened to be reporting at 1.5 s; requiring a run of samples that
  /// pass the gravity check is an actual convergence signal.
  final int warmUpSamples;

  /// The rolling history every shutter is interpolated against.
  ///
  /// Owned here rather than by the caller so that §6 pitfall 5 — "do not reset
  /// the buffer between targets" — is structural. Nothing in the capture loop
  /// has a buffer of its own to clear.
  final PoseBuffer buffer;

  final _poses = StreamController<DevicePose>.broadcast();
  StreamSubscription<PlatformAttitudeSample>? _samples;
  StreamSubscription<PosePlatformError>? _platformErrors;

  PoseSupport? _support;
  PoseStreamStart? _stream;
  Quaternion? _yawOffset;
  Quaternion? _previousEmitted;
  int? _firstSampleUs;
  Duration _warmUpTaken = Duration.zero;
  int _consecutiveGood = 0;
  int _received = 0;
  int _emitted = 0;
  int _droppedWarmingUp = 0;
  int _droppedUpsideDown = 0;
  int _signFlips = 0;
  int _missedSequences = 0;
  int _lastSequence = -1;
  double _worstUpTiltDegrees = 0;

  @override
  Future<bool> get isSupported async => (await support).isSupported;

  @override
  Future<PoseSupport> get support async =>
      _support ??= await _platform.capabilities();

  @override
  Stream<DevicePose> get poses => _poses.stream;

  /// How the stream was configured, or `null` before [start].
  PoseStreamStart? get stream => _stream;

  /// Whether the warm-up has completed and poses are being published.
  bool get isWarm => _yawOffset != null;

  /// The current counters (see [PoseStreamDiagnostics]).
  PoseStreamDiagnostics get diagnostics => PoseStreamDiagnostics(
    received: _received,
    emitted: _emitted,
    droppedWarmingUp: _droppedWarmingUp,
    droppedUpsideDown: _droppedUpsideDown,
    droppedOutOfOrder: buffer.outOfOrderCount,
    signFlipsCorrected: _signFlips,
    missedSequences: _missedSequences,
    worstUpTiltDegrees: _worstUpTiltDegrees,
    warmUpTaken: _warmUpTaken,
    stream: _stream,
  );

  @override
  Future<void> start() async {
    final found = await support;
    if (!found.isSupported) throw PoseSourceUnsupported(found);

    buffer.clear();
    _yawOffset = null;
    _previousEmitted = null;
    _consecutiveGood = 0;
    _received = 0;
    _emitted = 0;
    _droppedWarmingUp = 0;
    _droppedUpsideDown = 0;
    _signFlips = 0;
    _missedSequences = 0;
    _lastSequence = -1;
    _worstUpTiltDegrees = 0;
    _warmUpTaken = Duration.zero;
    _firstSampleUs = null;

    _samples = _platform.samples.listen(_onSample);
    _platformErrors = _platform.errors.listen(
      (e) => _poses.addError(StateError('pose stream failed: $e')),
    );
    _stream = await _platform.start(samplingPeriod);
  }

  @override
  Future<void> stop() async {
    await _samples?.cancel();
    _samples = null;
    await _platformErrors?.cancel();
    _platformErrors = null;
    await _platform.stop();
  }

  /// Closes the pose stream. Separate from [stop] because a session may stop
  /// and restart sampling while the same source object lives on.
  Future<void> dispose() async {
    await stop();
    await _poses.close();
  }

  void _onSample(PlatformAttitudeSample sample) {
    _received++;
    if (_lastSequence >= 0 && sample.sequence > _lastSequence + 1) {
      _missedSequences += sample.sequence - _lastSequence - 1;
    }
    _lastSequence = sample.sequence;

    final frame = _stream?.frame ?? _support?.frame;
    if (frame == null) return;

    // §2's conversion, before the yaw datum. The datum is a rotation about
    // world up, so it commutes with nothing here and must be applied after.
    final unoffset = PoseFrameConversion.deviceToWorldUnoffset(
      frame,
      sample.deviceToReference,
    );

    // The detectable half of the reflection hazard. `upDevice` came from the
    // gravity sensor and `unoffset` from the attitude sensor; if the conversion
    // has the vertical the wrong way up, or if a platform reports gravity with
    // the opposite sign to the one assumed at the plugin boundary, these two
    // disagree by ~180° and the panorama would come out upside down.
    //
    // It cannot catch a *mirrored* panorama: a reflection through a vertical
    // plane maps up to up exactly as a rotation does. That is what the §5
    // device test is for, and why this check is not a substitute for it.
    final upWorld = QuaternionUtils.rotate(unoffset, sample.upDevice);
    final tilt = math.acos(upWorld.y.clamp(-1.0, 1.0)) * 180 / math.pi;
    if (upWorld.y < minUpCosine) {
      _droppedUpsideDown++;
      _consecutiveGood = 0;
      if (_droppedUpsideDown == 1) {
        _poses.addError(
          StateError(
            'measured up rotates to ${upWorld.y.toStringAsFixed(3)} on the '
            'world Y axis (${tilt.toStringAsFixed(1)}° from up), so the '
            'attitude and gravity sensors disagree about which way is up. '
            'Phase 07 §2: the reference-frame conversion or the platform '
            'gravity sign is wrong on this device, and continuing would '
            'produce an upside-down panorama',
          ),
        );
      }
      return;
    }
    if (tilt > _worstUpTiltDegrees) _worstUpTiltDegrees = tilt;

    if (_yawOffset == null) {
      _consecutiveGood++;
      // Measured on the *sensor's* clock, not the wall clock. That is the clock
      // the samples are stamped on, it is monotonic, and it makes the warm-up
      // deterministic under test instead of something that has to be waited
      // out in real time.
      _firstSampleUs ??= sample.timestampUs;
      final elapsed = Duration(
        microseconds: sample.timestampUs - _firstSampleUs!,
      );
      if (elapsed < warmUp || _consecutiveGood < warmUpSamples) {
        _droppedWarmingUp++;
        return;
      }
      // Math §1.1: yaw 0 is the heading the session began at. Latched exactly
      // once, from the first sample the stream is trusted on.
      _yawOffset = PoseFrameConversion.yawOffsetFor(unoffset);
      _warmUpTaken = elapsed;
    }

    var deviceToWorld = PoseFrameConversion.applyYawOffset(
      _yawOffset!,
      unoffset,
    );

    // §6 pitfall 4. SLERP already takes the shorter path, so this is not what
    // makes interpolation correct — it makes the *published* stream continuous,
    // so that anything differencing adjacent poses (the steadiness gate, the
    // replay harness, a future consumer) does not see a 360° spin across
    // 10 ms. Two guards for one hazard is deliberate: the interpolator cannot
    // rely on its inputs having been canonicalised by someone else.
    final previous = _previousEmitted;
    if (previous != null && _dot(previous, deviceToWorld) < 0) {
      _signFlips++;
      deviceToWorld = Quaternion(
        -deviceToWorld.x,
        -deviceToWorld.y,
        -deviceToWorld.z,
        -deviceToWorld.w,
      );
    }
    _previousEmitted = deviceToWorld;

    final pose = DevicePose(
      deviceToWorld: deviceToWorld,
      // Recomputed from the offset attitude rather than reusing `upWorld`: the
      // yaw datum is a rotation about `+Y_w`, so it leaves the up vector's `y`
      // alone but rotates its horizontal residual — and that residual is
      // precisely the tilt Math §7 levels against.
      gravityWorld: QuaternionUtils.rotate(deviceToWorld, sample.upDevice)
        ..normalize(),
      timestampUs: sample.timestampUs,
      angularSpeedRadPerSec: sample.angularSpeedRadPerSec,
    );
    buffer.add(pose);
    _emitted++;
    _poses.add(pose);
  }

  static double _dot(Quaternion a, Quaternion b) =>
      a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
}
