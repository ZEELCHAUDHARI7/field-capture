import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:sphere_view/src/utils/quaternion_utils.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart';

import 'pose_fixtures.dart';

/// Drives `PlatformAhrsPoseSource` from a synthetic platform.
///
/// Everything between the wire and `DevicePose` is a Phase 07 hazard — the
/// frame conversion (§2), the warm-up (§6 pitfall 2), the gravity cross-check,
/// the sign canonicalisation (§6 pitfall 4), the refusal of a gyro-less device
/// (§6 pitfall 3) — and every one of them is reachable here without hardware.
/// That is the point of the platform seam: the device test is then left holding
/// only the question hardware can answer, which is whether the platform
/// documentation is true.
void main() {
  const degrees = math.pi / 180;
  const periodUs = 10000;

  /// Feeds [count] samples at 100 Hz, with the bearing advancing at
  /// [degreesPerSecond] — i.e. the user turning right at that rate.
  Future<void> pan(
    FakePosePlatform platform, {
    required int count,
    double degreesPerSecond = 0,
    double startBearingDegrees = 0,
    int startUs = 5000000,
    int startSequence = 0,
    Vector3 Function(Vector3 up)? warpUp,
    bool alternateSign = false,
    int sequenceStep = 1,
  }) async {
    for (var i = 0; i < count; i++) {
      final bearing =
          (startBearingDegrees + degreesPerSecond * i * periodUs / 1e6) * degrees;
      final up = platformUpDevice(bearing);
      platform.emit(
        platformSample(
          bearing: bearing,
          timestampUs: startUs + i * periodUs,
          sequence: startSequence + i * sequenceStep,
          angularSpeedRadPerSec: degreesPerSecond.abs() * degrees,
          upDevice: warpUp == null ? up : warpUp(up),
          negateQuaternion: alternateSign && i.isOdd,
        ),
      );
    }
    await pumpEventQueue();
  }

  double yawOf(DevicePose p) => SphericalConventions.yawOf(
    QuaternionUtils.rotate(p.deviceToWorld, Vector3(0, 0, -1)),
  );

  group('§6 pitfall 3 — a device with no gyroscope is refused', () {
    test('start() throws, with a sentence somebody on a site can act on', () async {
      final platform = FakePosePlatform(support: gyrolessPose);
      final source = PlatformAhrsPoseSource(platform: platform);
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });

      expect(await source.isSupported, isFalse);
      await expectLater(
        source.start(),
        throwsA(
          isA<PoseSourceUnsupported>().having(
            (e) => e.message,
            'message',
            contains('no gyroscope'),
          ),
        ),
      );
      expect(
        platform.started,
        isFalse,
        reason:
            'Phase 12 §1 refuses at the feature entry point — the sensors are '
            'never even registered',
      );
    });

    test('a supported device says so, and records what it found', () async {
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(platform: platform);
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });

      expect(await source.isSupported, isTrue);
      final support = await source.support;
      expect(support.usesMagnetometer, isFalse, reason: 'Math §1.1');
      expect(support.toJson()['uses_magnetometer'], isFalse);
    });
  });

  group('§6 pitfall 2 — the warm-up', () {
    test('publishes nothing until the stream has converged', () async {
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(platform: platform);
      final seen = <DevicePose>[];
      source.poses.listen(seen.add);
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });
      await source.start();

      // 1.4 s of samples — inside the 1–2 s `CMDeviceMotion` takes to converge.
      await pan(platform, count: 140);
      expect(seen, isEmpty);
      expect(source.isWarm, isFalse);
      expect(source.diagnostics.droppedWarmingUp, 140);

      // Past 1.5 s, and past the 20-sample run, so the datum latches.
      await pan(platform, count: 20, startUs: 5000000 + 140 * periodUs, startSequence: 140);
      expect(seen, isNotEmpty);
      expect(source.isWarm, isTrue);
      expect(source.diagnostics.warmUpTaken.inMilliseconds, 1500);
    });

    test('the first published pose is yaw 0 — the session-start datum', () async {
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(
        platform: platform,
        warmUp: const Duration(milliseconds: 100),
        warmUpSamples: 3,
      );
      final seen = <DevicePose>[];
      source.poses.listen(seen.add);
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });
      await source.start();

      // Whatever the user happened to be facing when they pressed start.
      await pan(platform, count: 20, startBearingDegrees: 137);
      expect(seen, isNotEmpty);
      expect(
        yawOf(seen.first),
        closeTo(0, 1e-9),
        reason: 'Math §1.1: yaw 0 is wherever the user was pointing at start',
      );
    });

    test('a run of good samples is required, not only elapsed time', () async {
      // A timer alone would accept whatever the filter happened to be
      // reporting at the deadline. The gravity check breaking the run resets
      // it, which is an actual convergence signal.
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(
        platform: platform,
        warmUp: Duration.zero,
        warmUpSamples: 5,
      );
      final seen = <DevicePose>[];
      source.poses.listen(seen.add, onError: (Object _) {});
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });
      await source.start();

      // Three good, then one whose up is inverted, then three good: the run
      // never reaches five and nothing is published.
      await pan(platform, count: 3);
      await pan(
        platform,
        count: 1,
        startUs: 5030000,
        startSequence: 3,
        warpUp: (up) => -up,
      );
      await pan(platform, count: 3, startUs: 5040000, startSequence: 4);
      expect(seen, isEmpty);

      await pan(platform, count: 3, startUs: 5070000, startSequence: 7);
      expect(seen, isNotEmpty);
    });
  });

  group('THE mirroring check, end to end', () {
    test('panning right makes yaw fall, at every rate §5 asks about', () async {
      for (final rate in [20.0, 60.0, 120.0]) {
        final platform = FakePosePlatform();
        final source = PlatformAhrsPoseSource(
          platform: platform,
          warmUp: Duration.zero,
          warmUpSamples: 1,
        );
        final seen = <DevicePose>[];
        source.poses.listen(seen.add);
        await source.start();

        await pan(platform, count: 51, degreesPerSecond: rate);

        expect(yawOf(seen.first), closeTo(0, 1e-9));
        // 50 samples at 100 Hz is half a second of panning.
        expect(
          yawOf(seen.last),
          closeTo(-rate / 2 * degrees, 1e-9),
          reason:
              'turning right at $rate°/s for 0.5 s must *lower* yaw by '
              '${rate / 2}°. A rising yaw is the mirrored panorama of §2',
        );
        for (var i = 1; i < seen.length; i++) {
          expect(
            yawOf(seen[i]),
            lessThan(yawOf(seen[i - 1]) + 1e-12),
            reason: 'yaw must fall monotonically through a rightward pan',
          );
        }
        await source.dispose();
        await platform.dispose();
      }
    });

    test('the angular speed of the pan reaches the steadiness gate', () async {
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(
        platform: platform,
        warmUp: Duration.zero,
        warmUpSamples: 1,
      );
      final seen = <DevicePose>[];
      source.poses.listen(seen.add);
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });
      await source.start();

      await pan(platform, count: 5, degreesPerSecond: 60);
      expect(seen.last.angularSpeedRadPerSec, closeTo(60 * degrees, 1e-12));
    });
  });

  group('the gravity cross-check', () {
    test('an up vector that rotates to world down is refused, loudly', () async {
      // The detectable half of §2's reflection hazard: either the conversion
      // has the vertical upside down or a platform reports gravity with the
      // opposite sign to the one the plugin boundary assumed. Publishing
      // anyway would produce an upside-down panorama.
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(
        platform: platform,
        warmUp: Duration.zero,
        warmUpSamples: 1,
      );
      final seen = <DevicePose>[];
      final errors = <Object>[];
      source.poses.listen(seen.add, onError: errors.add);
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });
      await source.start();

      await pan(platform, count: 10, warpUp: (up) => -up);
      expect(seen, isEmpty);
      expect(errors, hasLength(1), reason: 'reported once, not once per sample');
      expect('${errors.first}', contains('upside-down'));
      expect(source.diagnostics.droppedUpsideDown, 10);
    });

    test('a small honest tilt is reported as a number, not gated on', () async {
      // Math §7 consumes the AHRS's residual tilt as *data* — it is what
      // Kabsch levels against — so the check is deliberately loose enough to
      // let it through and record it.
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(
        platform: platform,
        warmUp: Duration.zero,
        warmUpSamples: 1,
      );
      final seen = <DevicePose>[];
      source.poses.listen(seen.add);
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });
      await source.start();

      await pan(
        platform,
        count: 5,
        warpUp: (up) => (up + Vector3(0.02, 0, 0))..normalize(),
      );
      expect(seen, hasLength(5));
      expect(source.diagnostics.droppedUpsideDown, 0);
      expect(source.diagnostics.worstUpTiltDegrees, greaterThan(0.5));
      expect(source.diagnostics.worstUpTiltDegrees, lessThan(3.0));
      // And the measured tilt travels into the pose, where levelling wants it.
      expect(seen.last.gravityWorld.y, lessThan(1.0));
      expect(seen.last.gravityWorld.length, closeTo(1.0, 1e-12));
    });
  });

  group('§6 pitfall 4 — sign canonicalisation of the published stream', () {
    test('a platform that flips q to −q does not reach consumers that way', () async {
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(
        platform: platform,
        warmUp: Duration.zero,
        warmUpSamples: 1,
      );
      final seen = <DevicePose>[];
      source.poses.listen(seen.add);
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });
      await source.start();

      await pan(platform, count: 20, degreesPerSecond: 30, alternateSign: true);

      expect(source.diagnostics.signFlipsCorrected, greaterThan(0));
      for (var i = 1; i < seen.length; i++) {
        final a = seen[i - 1].deviceToWorld;
        final b = seen[i].deviceToWorld;
        expect(
          a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w,
          greaterThan(0),
          reason:
              'adjacent published poses must sit in one hemisphere, or anything '
              'differencing them sees a 360° spin across 10 ms',
        );
      }
      // And the rotation itself is unchanged — this is a sign fix, not a
      // correction.
      expect(yawOf(seen.last), closeTo(-30 * 19 / 100 * degrees, 1e-9));
    });
  });

  group('the buffer the source owns', () {
    test('is fed every published pose, and answers between them', () async {
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(
        platform: platform,
        warmUp: Duration.zero,
        warmUpSamples: 1,
      );
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });
      await source.start();

      await pan(platform, count: 40, degreesPerSecond: 60);
      expect(source.buffer.length, 40);

      // Halfway between two samples, 5 ms in, at 60°/s: 0.3° of turn.
      final between = source.buffer.at(5000000 + 10 * periodUs + 5000)!;
      expect(yawOf(between), closeTo(-(60 * 0.105) * degrees, 1e-9));
    });

    test('starting again clears the datum and the history', () async {
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(
        platform: platform,
        warmUp: Duration.zero,
        warmUpSamples: 1,
      );
      final seen = <DevicePose>[];
      source.poses.listen(seen.add);
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });

      await source.start();
      await pan(platform, count: 5, startBearingDegrees: 10);
      await source.stop();
      expect(platform.stopped, isTrue);

      await source.start();
      await pan(platform, count: 5, startBearingDegrees: 200, startUs: 9000000);
      expect(
        source.buffer.length,
        5,
        reason: 'the first session\'s history is gone, not appended to',
      );
      expect(
        yawOf(seen[5]),
        closeTo(0, 1e-9),
        reason: 'a new session re-pins yaw 0 to the new starting heading',
      );
    });
  });

  group('diagnostics', () {
    test('count what the channel dropped, separately from what the sensor did', () async {
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(
        platform: platform,
        warmUp: Duration.zero,
        warmUpSamples: 1,
      );
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });
      await source.start();

      // Sequence numbers advancing by 3 while timestamps advance by one period:
      // the sensor produced three times as many samples as arrived.
      await pan(platform, count: 10, sequenceStep: 3);
      expect(source.diagnostics.received, 10);
      expect(source.diagnostics.emitted, 10);
      expect(source.diagnostics.missedSequences, 18);
      expect(source.diagnostics.toJson()['missed_sequences'], 18);
    });

    test('the stream configuration lands in the record for the bundle', () async {
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(platform: platform);
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });
      await source.start();

      expect(platform.requestedPeriod, PlatformAhrsPoseSource.defaultSamplingPeriod);
      expect(source.stream!.samplingPeriod.inMicroseconds, 10000, reason: '§4: 100 Hz');
      final json = source.diagnostics.toJson()['stream']! as Map<String, Object?>;
      expect((json['clock']! as Map<String, Object?>)['is_exact'], isTrue);
    });
  });

  group('platform failures reach the caller', () {
    test('an asynchronous sensor failure becomes a stream error', () async {
      final platform = FakePosePlatform();
      final source = PlatformAhrsPoseSource(
        platform: platform,
        warmUp: Duration.zero,
        warmUpSamples: 1,
      );
      final errors = <Object>[];
      source.poses.listen((_) {}, onError: errors.add);
      addTearDown(() async {
        await source.dispose();
        await platform.dispose();
      });
      await source.start();

      platform.fail(const PosePlatformError('pose_unreliable', 'HAL gave up'));
      await pumpEventQueue();
      expect(errors, hasLength(1));
      expect('${errors.first}', contains('HAL gave up'));
    });
  });
}
