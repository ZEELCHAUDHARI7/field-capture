// The Phase 07 §5 tests, on real hardware.
//
// One of these matters far more than the others, and the phase document says
// so: the **timestamp-alignment test**. Everything else in Phase 07 is
// mechanical and provable on a laptop — `test/pose_conversion_test.dart`,
// `test/pose_buffer_test.dart` and `test/pose_source_test.dart` between them
// cover the frame conversion, the SLERP, the buffer boundary, the warm-up, the
// sign ambiguity and the gyro-less refusal. What they cannot cover is whether
// the *platform documentation* is true, and whether the camera's shutter clock
// and the sensor's clock really are the same clock.
//
// So this file measures two things that do not exist off a device:
//
//   1. The residual timestamp offset between pose and shutter, recovered as
//      the **slope** of pose error against angular rate. §5's insight is that
//      a timing error and a geometry error look identical at any single pan
//      rate and completely different across a range of them: timing scales
//      with ω, geometry does not.
//   2. The **sign** of the conversion, by checking the pose against the optics
//      rather than against itself — as the device turns right, the pose yaw
//      must fall *and* a fixed edge must travel left across the sensor. A
//      mirrored conversion breaks the agreement between those two while
//      leaving each of them internally consistent, which is exactly why §2
//      says reasoning alone will not settle it.
//
// Run it, then send back `sphere_view_phase07_report.json`. `RUNNING.md` in
// this directory says exactly how, including the two-minute physical setup.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sphere_view/sphere_view.dart';

/// Set with `--dart-define=EDGE=true` when the camera is pointed at a
/// high-contrast vertical edge and someone is available to pan the tablet.
///
/// Without it the drift and capability tests still run and still produce
/// numbers; the timestamp-alignment test says what is missing rather than
/// inventing a reference.
const bool _edgeRig = bool.fromEnvironment('EDGE');

/// Seconds to hold still for the drift test. The exit criterion is stated over
/// three minutes; shortening it is for iterating, not for reporting.
const int _driftSeconds = int.fromEnvironment('DRIFT_SECONDS', defaultValue: 180);

/// How many frames the pan sweep captures.
const int _sweepFrames = int.fromEnvironment('SWEEP_FRAMES', defaultValue: 90);

// The exit criteria, as numbers rather than prose.
const double _timestampOffsetLimitMs = 3.0;
const double _yawDriftLimitDegrees = 1.5;
const double _tiltDriftLimitDegrees = 0.3;
const double _minPanRateDegPerSec = 20.0;
const double _maxPanRateDegPerSec = 120.0;

/// Minimum normalised gradient response for a column to count as *the* edge.
/// Below this the frame saw no edge — a blank wall, or the pan carried it out
/// of frame — and the frame is skipped and counted rather than fitted to noise.
const double _minEdgeStrength = 0.04;

const double _degrees = math.pi / 180;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late PigeonPosePlatform posePlatform;
  late PlatformAhrsPoseSource source;
  late PigeonCameraPlatform camera;
  late Directory workDirectory;

  final report = <String, Object?>{
    'phase': '07',
    'generated_at': DateTime.now().toIso8601String(),
    'platform': Platform.operatingSystem,
    'os_version': Platform.operatingSystemVersion,
    'inputs': {
      'edge_rig': _edgeRig,
      'drift_seconds': _driftSeconds,
      'sweep_frames': _sweepFrames,
    },
  };

  /// The per-frame observations the alignment and mirroring tests share, so the
  /// sweep is captured once.
  final observations = <_Observation>[];

  setUpAll(() async {
    posePlatform = PigeonPosePlatform();
    source = PlatformAhrsPoseSource(platform: posePlatform);
    camera = PigeonCameraPlatform();
    final documents = await getApplicationDocumentsDirectory();
    workDirectory = Directory('${documents.path}/phase07')
      ..createSync(recursive: true);
  });

  tearDownAll(() async {
    await source.dispose().catchError((_) {});
    await camera.close().catchError((_) {});
    final file = File('${workDirectory.path}/sphere_view_phase07_report.json');
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    // ignore: avoid_print
    print(
      '\n===== PHASE 07 REPORT (${file.path}) =====\n'
      '${const JsonEncoder.withIndent('  ').convert(report)}\n'
      '===== END PHASE 07 REPORT =====\n',
    );
  });

  testWidgets('1. the device is supported, and says exactly what it has', (_) async {
    final support = await source.support;
    report['support'] = support.toJson();

    expect(
      support.usesMagnetometer,
      isFalse,
      reason:
          'Phase 07 §1: the compass must not be in the loop. Indoors, rebar and '
          'steel studs bend magnetic heading by tens of degrees. A true here '
          'means the build reached for TYPE_ROTATION_VECTOR or '
          '.xTrueNorthZVertical',
    );

    if (!support.isSupported) {
      // Not a failure of the code — it is the code working. §6 pitfall 3 and
      // Phase 12 §1 both say a gyro-less device is refused at the feature entry
      // point, so a device that lands here should produce a readable refusal
      // and nothing else.
      expect(support.hasGyroscope, isFalse);
      expect(support.unsupportedReason, isNotEmpty);
      await expectLater(source.start(), throwsA(isA<PoseSourceUnsupported>()));
      // ignore: avoid_print
      print(
        'This device is correctly REFUSED: ${support.unsupportedReason}\n'
        'Every later test is skipped, because there is nothing to measure.',
      );
      report['refused'] = true;
      return;
    }

    expect(support.hasGyroscope, isTrue);
    expect(support.hasAccelerometer, isTrue);
    expect(support.hasFusedRotation, isTrue);

    await source.start();
    report['stream'] = source.stream!.toJson();

    // §4 asks for 100 Hz. Whether the platform honours it is a fact about the
    // device, so it is measured rather than assumed: the buffer is 4 s long,
    // and a device running at 20 Hz would still work but would interpolate
    // across 50 ms instead of 10 ms.
    final start = DateTime.now();
    final counted = <DevicePose>[];
    final sub = source.poses.listen(counted.add);
    await Future<void>.delayed(const Duration(seconds: 5));
    await sub.cancel();
    final seconds = DateTime.now().difference(start).inMilliseconds / 1000.0;

    report['sample_rate'] = {
      'requested_hz': 1e6 / source.stream!.samplingPeriod.inMicroseconds,
      'measured_hz': counted.length / seconds,
      'min_delay_us': source.stream!.minDelayUs,
      'warm_up_ms': source.diagnostics.warmUpTaken.inMilliseconds,
      'diagnostics': source.diagnostics.toJson(),
    };

    expect(
      counted,
      isNotEmpty,
      reason:
          'the stream started but published nothing in 5 s. Either the sensor '
          'is silent or the warm-up never converged — check '
          'diagnostics.dropped_upside_down, which would mean the frame '
          'conversion and the gravity sensor disagree about which way is up',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('2. held still: yaw drift < 1.5°, pitch and roll flat', (_) async {
    if (report['refused'] == true) return;

    // ignore: avoid_print
    print(
      'PUT THE TABLET DOWN NOW and do not touch it for $_driftSeconds seconds. '
      'Any movement is measured as drift.',
    );

    final samples = <DevicePose>[];
    final sub = source.poses.listen(samples.add);
    await Future<void>.delayed(Duration(seconds: _driftSeconds));
    await sub.cancel();

    expect(samples.length, greaterThan(100), reason: 'the stream stalled');

    final reference = samples.first;
    final refAngles = _angles(reference);
    var maxYaw = 0.0;
    var maxPitch = 0.0;
    var maxRoll = 0.0;
    var maxSpeed = 0.0;
    for (final s in samples) {
      final a = _angles(s);
      maxYaw = math.max(maxYaw, _wrapDegrees(a.yaw - refAngles.yaw).abs());
      maxPitch = math.max(maxPitch, (a.pitch - refAngles.pitch).abs());
      maxRoll = math.max(maxRoll, _wrapDegrees(a.roll - refAngles.roll).abs());
      maxSpeed = math.max(maxSpeed, s.angularSpeedRadPerSec);
    }

    final endYaw = _wrapDegrees(_angles(samples.last).yaw - refAngles.yaw);
    report['drift'] = {
      'seconds': _driftSeconds,
      'samples': samples.length,
      'max_yaw_excursion_degrees': maxYaw,
      'end_yaw_degrees': endYaw,
      // Split from yaw on purpose. Yaw has no absolute reference and is only
      // bias-corrected, so it drifts slowly. Pitch and roll are locked to
      // gravity, so they should be *flat*, not merely small — a pitch that
      // wanders is a different fault from a yaw that creeps, and it would mean
      // the accelerometer correction is not running.
      'max_pitch_excursion_degrees': maxPitch,
      'max_roll_excursion_degrees': maxRoll,
      'peak_angular_speed_deg_per_sec': maxSpeed / _degrees,
      'yaw_limit_degrees': _yawDriftLimitDegrees,
      'tilt_limit_degrees': _tiltDriftLimitDegrees,
      // The AHRS's own disagreement between its attitude and its gravity
      // estimate, which Math §7 levels against.
      'worst_up_tilt_degrees': source.diagnostics.worstUpTiltDegrees,
    };

    expect(
      maxSpeed / _degrees,
      lessThan(2.0),
      reason:
          'the tablet moved during the drift window (peak '
          '${(maxSpeed / _degrees).toStringAsFixed(1)}°/s), so this measured the '
          'room rather than the sensor. Re-run without touching it',
    );
    expect(
      maxYaw,
      lessThan(_yawDriftLimitDegrees),
      reason:
          'yaw drifted ${maxYaw.toStringAsFixed(2)}° over $_driftSeconds s '
          'against a $_yawDriftLimitDegrees° budget. At a 6144-wide equirect '
          'that is ${(maxYaw * 6144 / 360).toStringAsFixed(0)} px of seed error',
    );
    expect(
      maxPitch,
      lessThan(_tiltDriftLimitDegrees),
      reason:
          'pitch is gravity-locked and must be flat, not merely small. '
          '${maxPitch.toStringAsFixed(2)}° of wander means the accelerometer '
          'correction is not doing its job, and Math §7 levels the panorama '
          'against exactly this',
    );
    expect(maxRoll, lessThan(_tiltDriftLimitDegrees));
  }, timeout: Timeout(Duration(seconds: _driftSeconds + 120)));

  testWidgets('3. THE timestamp-alignment test: residual offset < 3 ms', (_) async {
    if (report['refused'] == true) return;
    if (!_edgeRig) {
      // ignore: avoid_print
      print(
        'SKIPPED: no --dart-define=EDGE=true. This is the test Phase 07 exists '
        'for — everything else here is provable on a laptop. Set up the edge '
        'per RUNNING.md §2 (a doorframe or a strip of black tape on a light '
        'wall, 2–3 m away, tablet in landscape) and re-run. It takes two '
        'minutes to set up.',
      );
      report['timestamp_alignment'] = {
        'status': 'skipped',
        'reason': 'no vertical-edge rig',
      };
      return;
    }

    final probe = CameraProbe(camera);
    final selection = await probe.selectCaptureCamera();
    // Deliberately a modest capture size. The intrinsics come back for whatever
    // size is configured, so the geometry stays exact, while a ~2 MP frame
    // decodes in a fraction of the time a 12 MP one does — and this test
    // decodes every frame it takes. Edge localisation is sub-pixel either way.
    final size = _sweepSize(selection.camera);
    final opened = await camera.open(
      selection.camera.id,
      CaptureFormatSpec(captureSize: size),
    );
    report['camera'] = {
      ...opened.toProvenanceJson(),
      'fx': opened.intrinsics.fx,
      'cx': opened.intrinsics.cx,
      'hfov_degrees': opened.intrinsics.hfovDegrees,
    };
    await ExposureController(camera).meterAndLock();

    // ignore: avoid_print
    print(
      'PAN NOW. Sweep the tablet left and right past the edge, smoothly, '
      'covering slow (~20°/s) through fast (~120°/s) passes. Keep the edge '
      'crossing the frame. $_sweepFrames frames, about a minute.',
    );

    var missedEdge = 0;
    var missedPose = 0;
    for (var i = 0; i < _sweepFrames; i++) {
      final capture = await camera.captureBracket(
        const [0.0],
        outputDirectory: workDirectory.path,
        namePrefix: 'sweep$i',
      );
      if (capture.frames.isEmpty) continue;
      final frame = capture.frames.first;

      final resolved = ShutterPoseResolver(source.buffer).resolve(capture);
      if (!resolved.isResolved) {
        missedPose++;
        continue;
      }

      final edge = _findVerticalEdge(File(frame.filePath));
      if (edge == null) {
        missedEdge++;
        File(frame.filePath).deleteSync();
        continue;
      }

      // The signed rate at the shutter, from the pose stream itself rather
      // than from the human's steadiness. `angularSpeedRadPerSec` is a
      // magnitude, and the regressor has to carry the direction of the pan —
      // otherwise a left sweep and a right sweep would both land on the
      // positive axis and their opposite errors would cancel.
      final rate = _signedYawRate(source.buffer, frame.timestampUs);
      if (rate == null) {
        missedPose++;
        File(frame.filePath).deleteSync();
        continue;
      }

      observations.add(
        _Observation(
          poseYaw: resolved.pose!.yaw,
          edgeColumn: edge.column,
          edgeStrength: edge.strength,
          yawRateDegPerSec: rate / _degrees,
          timestampUs: frame.timestampUs,
          exposureTimeNs: frame.exposureTimeNs,
        ),
      );
      // The JPEGs are only ever read once; a 90-frame sweep would otherwise
      // leave ~200 MB on a tablet that has a stitch to do later.
      File(frame.filePath).deleteSync();
    }
    await camera.close();

    report['sweep'] = {
      'requested': _sweepFrames,
      'usable': observations.length,
      'no_edge_found': missedEdge,
      'no_pose_for_shutter': missedPose,
    };

    expect(
      observations.length,
      greaterThanOrEqualTo(20),
      reason:
          'only ${observations.length} of $_sweepFrames frames were usable '
          '($missedEdge found no edge, $missedPose had no pose). A fit needs '
          'more than that. If no_edge_found dominates, the edge left the frame '
          'or the contrast is too low; if no_pose_for_shutter dominates, the '
          'camera and motion clocks may not be the same clock at all, which is '
          'itself the finding',
    );

    // The world yaw of the edge, computed independently per frame.
    //
    //   Ψ = ψ − atan((x − cx) / fx)
    //
    // ψ is what the pose says the optical axis was doing; the arctangent is
    // where the optics say the edge sat relative to that axis. The edge is
    // nailed to a wall, so Ψ is a constant, and every departure from that
    // constant is error. Deriving it: the device-frame ray for column `x` is
    // `((x−cx)/fx, ·, −1)` (Math §4), and rotating that into the world for a
    // level camera at heading ψ gives yaw `ψ − atan((x−cx)/fx)`. The minus sign
    // is the same fact as "turning right moves content right" (Math §3), seen
    // from the sensor: as ψ falls, a fixed edge slides left down the frame.
    final fx = (report['camera']! as Map<String, Object?>)['fx']! as double;
    final cx = (report['camera']! as Map<String, Object?>)['cx']! as double;

    final rates = <double>[];
    final residuals = <double>[];
    final raw = <double>[];
    for (final o in observations) {
      raw.add(o.poseYaw - math.atan((o.edgeColumn - cx) / fx));
    }
    final unwrapped = _unwrap(raw);
    final mean = unwrapped.reduce((a, b) => a + b) / unwrapped.length;
    for (var i = 0; i < observations.length; i++) {
      rates.add(observations[i].yawRateDegPerSec * _degrees);
      residuals.add(unwrapped[i] - mean);
    }

    // residual ≈ intercept + slope·ω. §5's whole point: the slope has units of
    // *seconds* and is the residual timestamp offset; the intercept is a
    // constant geometric error and does not scale with the pan.
    final fit = _fitLine(rates, residuals);
    final offsetMs = fit.slope * 1000;

    // The same fit against exposure-midpoint timestamps. Both platforms stamp
    // a frame at the *start* of exposure, so the instant the image actually
    // represents is half an exposure later. At 1/250 s that is 2 ms — most of
    // the 3 ms budget — so reporting only the raw number would leave a real,
    // correctable bias looking like an unexplained failure.
    final midRates = <double>[];
    final midResiduals = <double>[];
    for (var i = 0; i < observations.length; i++) {
      final exposure = observations[i].exposureTimeNs;
      if (exposure == null) continue;
      final shifted = source.buffer.at(
        observations[i].timestampUs + exposure ~/ 2000,
      );
      if (shifted == null) continue;
      midRates.add(rates[i]);
      midResiduals.add(
        shifted.yaw -
            math.atan((observations[i].edgeColumn - cx) / fx) -
            mean,
      );
    }
    final midFit = midRates.length >= 10
        ? _fitLine(midRates, _unwrap(midResiduals))
        : null;

    final observedRates = [for (final o in observations) o.yawRateDegPerSec];
    final absRates = [for (final r in observedRates) r.abs()]..sort();

    report['timestamp_alignment'] = {
      'status': 'measured',
      'samples': observations.length,
      // The headline. §5's acceptance criterion, in milliseconds.
      'HEADLINE_residual_offset_ms': offsetMs,
      'limit_ms': _timestampOffsetLimitMs,
      'within_limit': offsetMs.abs() <= _timestampOffsetLimitMs,
      // A constant offset is a frame-conversion or intrinsics error, not a
      // timing one. Reported so the two are never confused; §5 is explicit that
      // this is the whole reason for plotting against rate.
      'constant_offset_degrees': fit.intercept / _degrees,
      'fit_r_squared': fit.rSquared,
      'residual_rms_degrees': _rms(residuals) / _degrees,
      'exposure_midpoint_offset_ms': midFit == null ? null : midFit.slope * 1000,
      'exposure_midpoint_samples': midRates.length,
      'rate_range_deg_per_sec': {
        'min_signed': observedRates.reduce(math.min),
        'max_signed': observedRates.reduce(math.max),
        'min_abs': absRates.first,
        'max_abs': absRates.last,
        'covers_20_to_120': absRates.first <= _minPanRateDegPerSec &&
            absRates.last >= _maxPanRateDegPerSec,
      },
      'edge_world_yaw_degrees': mean / _degrees,
      'points': [
        for (var i = 0; i < observations.length; i++)
          {
            'rate_deg_per_sec': observations[i].yawRateDegPerSec,
            'residual_degrees': residuals[i] / _degrees,
            'edge_column': observations[i].edgeColumn,
            'edge_strength': observations[i].edgeStrength,
          },
      ],
    };

    expect(
      absRates.last,
      greaterThanOrEqualTo(_maxPanRateDegPerSec * 0.8),
      reason:
          'the fastest pass was only ${absRates.last.toStringAsFixed(0)}°/s. '
          'The slope is what this test measures, and a narrow range of rates '
          'gives it a long lever arm on noise — §5 asks for 20 to 120°/s',
    );
    expect(
      offsetMs.abs(),
      lessThanOrEqualTo(_timestampOffsetLimitMs),
      reason:
          'the pose lags or leads the shutter by '
          '${offsetMs.toStringAsFixed(2)} ms, against a '
          '${_timestampOffsetLimitMs.toStringAsFixed(0)} ms budget. At 60°/s '
          'that is ${(offsetMs.abs() * 60 / 1000).toStringAsFixed(2)}° of pose '
          'error on every frame — and unlike a constant error it is *unbiased '
          'noise* across the plan, so bundle adjustment cannot absorb it. '
          'Check exposure_midpoint_offset_ms first: if that number is inside '
          'the budget and this one is not, the fix is to stamp the middle of '
          'the exposure rather than its start',
    );
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('4. the mirroring check: pose and optics agree on which way', (_) async {
    if (report['refused'] == true) return;
    if (observations.length < 20) {
      // ignore: avoid_print
      print(
        'SKIPPED: needs the sweep from test 3, which needs '
        '--dart-define=EDGE=true.',
      );
      report['mirroring'] = {'status': 'skipped', 'reason': 'no sweep data'};
      return;
    }

    // The sign question §2 says derivation cannot settle, asked in the one way
    // that cannot be self-consistent-but-wrong: against the optics.
    //
    // Turning right lowers the pose yaw (Math §3) *and* carries a fixed edge
    // left across the sensor. A mirrored conversion flips the first and leaves
    // the second alone, so the correlation between them inverts — while every
    // other check in this phase, including gravity, still passes, because a
    // reflection through a vertical plane maps up to up.
    final sorted = [...observations]..sort(
      (a, b) => a.timestampUs.compareTo(b.timestampUs),
    );
    var agreeing = 0;
    var disagreeing = 0;
    var yawFellEdgeWentLeft = 0;
    for (var i = 1; i < sorted.length; i++) {
      final dYaw = _wrapRadians(sorted[i].poseYaw - sorted[i - 1].poseYaw);
      final dColumn = sorted[i].edgeColumn - sorted[i - 1].edgeColumn;
      // Below a degree of motion the edge measurement is dominated by its own
      // noise, and a coin flip would score 50%.
      if (dYaw.abs() < 1 * _degrees || dColumn.abs() < 5) continue;
      if (dYaw.sign == dColumn.sign) {
        agreeing++;
        if (dYaw < 0) yawFellEdgeWentLeft++;
      } else {
        disagreeing++;
      }
    }

    final total = agreeing + disagreeing;
    final fraction = total == 0 ? 0.0 : agreeing / total;
    report['mirroring'] = {
      'status': 'measured',
      'compared_pairs': total,
      'agreeing': agreeing,
      'disagreeing': disagreeing,
      'agreement_fraction': fraction,
      'turned_right_and_edge_moved_left': yawFellEdgeWentLeft,
      'conversion_determinant': _determinant(
        PoseFrameConversion.referenceToWorldRowMajor,
      ),
    };

    expect(total, greaterThanOrEqualTo(10), reason: 'not enough motion to judge');
    expect(
      fraction,
      greaterThan(0.9),
      reason:
          'the pose and the image disagree about which way the tablet turned on '
          '${(100 * (1 - fraction)).toStringAsFixed(0)}% of consecutive frames. '
          'A fraction near 0 means the frame conversion is MIRRORED — Phase 07 '
          '§2 predicts exactly this, and the fix is the determinant of '
          'PoseFrameConversion.referenceToWorldRowMajor. A fraction near 0.5 '
          'means the poses and the frames are not paired at all, which is test '
          "3's problem, not this one",
    );
    expect(
      yawFellEdgeWentLeft,
      greaterThan(0),
      reason:
          'no rightward pan was observed at all, so the direction was never '
          'actually tested. Sweep both ways',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// One frame's worth of the sweep.
class _Observation {
  const _Observation({
    required this.poseYaw,
    required this.edgeColumn,
    required this.edgeStrength,
    required this.yawRateDegPerSec,
    required this.timestampUs,
    required this.exposureTimeNs,
  });

  final double poseYaw;
  final double edgeColumn;
  final double edgeStrength;
  final double yawRateDegPerSec;
  final int timestampUs;
  final int? exposureTimeNs;
}

/// Yaw, pitch and roll in degrees, for the drift test.
///
/// Roll is defined as the tilt of the screen about the optical axis: world up,
/// expressed in device coordinates, makes this angle with the screen's own up.
/// That is the quantity a user would call "the tablet is tilted", and — the
/// reason it is worth measuring separately from pitch — it is the second of the
/// two degrees of freedom the accelerometer pins. If roll wanders while yaw
/// holds, the gravity correction is running on one axis only.
({double yaw, double pitch, double roll}) _angles(DevicePose pose) {
  final q = pose.deviceToWorld;
  final x = q.x, y = q.y, z = q.z, w = q.w;
  // World up, expressed in device coordinates: `R_wdᵀ · (0,1,0)`, which is the
  // second *row* of `R_wd` and can be read straight off the quaternion.
  // Written out rather than routed through `Quaternion.rotated`, which in
  // `vector_math` applies the inverse of `asRotationMatrix` — the trap
  // `test/conventions_test.dart` pins — and would silently mirror the roll.
  final upX = 2 * (x * y + w * z);
  final upY = 1 - 2 * (x * x + z * z);
  return (
    yaw: pose.yaw / _degrees,
    pitch: pose.pitch / _degrees,
    roll: math.atan2(upX, upY) / _degrees,
  );
}

/// The signed yaw rate at [timestampUs], from the buffer's own history.
///
/// A central difference over ±20 ms rather than the gyro's magnitude, because
/// the regressor in §5's fit has to carry the *direction* of the pan: a left
/// sweep and a right sweep produce opposite errors, and folding them onto one
/// positive axis would cancel exactly the signal being measured.
double? _signedYawRate(PoseBuffer buffer, int timestampUs, {int halfSpanUs = 20000}) {
  final before = buffer.at(timestampUs - halfSpanUs);
  final after = buffer.at(timestampUs + halfSpanUs);
  if (before == null || after == null) return null;
  return _wrapRadians(after.yaw - before.yaw) / (2 * halfSpanUs / 1e6);
}

/// The column of the strongest vertical edge, refined to sub-pixel, plus how
/// strong it was.
///
/// Only a band of rows around the vertical centre is examined. That is not an
/// optimisation: on a rolling shutter every row is exposed at a different
/// instant, so measuring across the whole frame would average a spread of times
/// into one number — which is the very quantity this test is trying to resolve
/// to 3 ms. A narrow central band keeps the row-time consistent from frame to
/// frame.
({double column, double strength})? _findVerticalEdge(File file) {
  final bytes = file.readAsBytesSync();
  final image = img.decodeJpg(bytes);
  if (image == null) return null;

  final midRow = image.height ~/ 2;
  final band = math.max(8, image.height ~/ 10);
  final fromRow = math.max(1, midRow - band ~/ 2);
  final toRow = math.min(image.height - 1, midRow + band ~/ 2);
  final rows = toRow - fromRow;
  if (rows <= 0 || image.width < 5) return null;

  final response = List<double>.filled(image.width, 0);
  for (var y = fromRow; y < toRow; y++) {
    for (var x = 1; x < image.width - 1; x++) {
      final left = image.getPixel(x - 1, y).luminanceNormalized;
      final right = image.getPixel(x + 1, y).luminanceNormalized;
      response[x] += (right - left).abs();
    }
  }

  var peak = 1;
  for (var x = 1; x < image.width - 1; x++) {
    if (response[x] > response[peak]) peak = x;
  }
  final strength = response[peak] / rows;
  if (strength < _minEdgeStrength) return null;
  if (peak <= 1 || peak >= image.width - 2) return null;

  // Parabolic refinement over the three columns around the peak. The edge sits
  // between pixels far more often than on one, and a whole-pixel answer would
  // put a floor under the fit of about `atan(1/fx)` ≈ 0.03° — which at 60°/s is
  // half a millisecond of the 3 ms budget, spent on nothing.
  final a = response[peak - 1];
  final b = response[peak];
  final c = response[peak + 1];
  final denominator = a - 2 * b + c;
  final shift = denominator.abs() < 1e-12 ? 0.0 : 0.5 * (a - c) / denominator;
  return (column: peak + shift.clamp(-1.0, 1.0), strength: strength);
}

/// Least squares `y = intercept + slope·x`, with the coefficient of
/// determination so a meaningless fit is visible as one.
({double slope, double intercept, double rSquared}) _fitLine(
  List<double> xs,
  List<double> ys,
) {
  final n = xs.length;
  final meanX = xs.reduce((a, b) => a + b) / n;
  final meanY = ys.reduce((a, b) => a + b) / n;
  var sxy = 0.0;
  var sxx = 0.0;
  var syy = 0.0;
  for (var i = 0; i < n; i++) {
    final dx = xs[i] - meanX;
    final dy = ys[i] - meanY;
    sxy += dx * dy;
    sxx += dx * dx;
    syy += dy * dy;
  }
  final slope = sxx == 0 ? 0.0 : sxy / sxx;
  return (
    slope: slope,
    intercept: meanY - slope * meanX,
    rSquared: (sxx == 0 || syy == 0) ? 0.0 : (sxy * sxy) / (sxx * syy),
  );
}

/// Removes ±2π jumps, so an edge that happens to sit near the ±180° meridian
/// does not turn one continuous series into two.
List<double> _unwrap(List<double> values) {
  if (values.isEmpty) return values;
  final out = <double>[values.first];
  for (var i = 1; i < values.length; i++) {
    out.add(out.last + _wrapRadians(values[i] - out.last));
  }
  return out;
}

double _wrapRadians(double radians) {
  var r = (radians + math.pi) % (2 * math.pi);
  if (r < 0) r += 2 * math.pi;
  return r - math.pi;
}

double _wrapDegrees(double degrees) => _wrapRadians(degrees * _degrees) / _degrees;

double _rms(List<double> values) {
  if (values.isEmpty) return 0;
  var sum = 0.0;
  for (final v in values) {
    sum += v * v;
  }
  return math.sqrt(sum / values.length);
}

double _determinant(List<double> m) =>
    m[0] * (m[4] * m[8] - m[5] * m[7]) -
    m[1] * (m[3] * m[8] - m[5] * m[6]) +
    m[2] * (m[3] * m[7] - m[4] * m[6]);

/// The smallest 4:3 capture at least 1600 px wide, or the smallest available.
///
/// Small on purpose: this test decodes every frame it captures, and a 12 MP
/// JPEG costs the best part of a second to decode on a tablet. The intrinsics
/// are resolved for whatever size is configured, so the geometry stays exact.
ImageSize _sweepSize(CameraDescriptor camera) {
  ImageSize? best;
  for (final s in camera.availableSizes) {
    final wide = s.width >= s.height ? s.width : s.height;
    final tall = s.width >= s.height ? s.height : s.width;
    if ((wide / tall - 4 / 3).abs() > 0.02) continue;
    if (wide < 1600) continue;
    if (best == null || s.area < best.area) best = s;
  }
  return best ?? camera.availableSizes.last;
}
