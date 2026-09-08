import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'capture_fixtures.dart';

/// Phase 08 §6, tests 13–15: the orchestrator.
///
/// The three claims under test are the ones that decide whether an interrupted
/// site walk is survivable, and none of them can be checked by reading the code:
/// frames reach disk immediately, the manifest is rewritten after every
/// position, and a process killed mid-session resumes where it stopped. Behind
/// the fakes all three run in milliseconds, including the kill.
/// The old default, for the tests that are specifically about the locked 3-shot
/// bracket. The shipping default is now `ExposureStrategy.auto`.
const bracketConfig = SphereCaptureConfig(
  exposure: ExposureStrategy.bracket3(evSpread: 2.0),
);

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sphere_session_test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Waits for any in-flight bracket to finish.
  ///
  /// Firing the shutter is asynchronous — burst, pose interpolation, sharpness,
  /// manifest — so a test that asserted straight after the pose that completed
  /// the dwell would be racing the capture it triggered.
  /// Bounded by a **deadline**, not by a round count, and that is the fix
  /// `phases/README.md` prescribed after the Phase 10 audit.
  ///
  /// A capture writes real files, so on a machine running several suites at once
  /// — or the native stitch tests, which saturate every core for minutes — a
  /// fixed number of `pumpEventQueue()` rounds stops being enough for the I/O to
  /// land. The symptom is a suite that passes alone and fails in CI, which is the
  /// worst kind: it teaches people to re-run rather than to read. A wall-clock
  /// deadline scales with the machine instead.
  Future<void> settle(SphereCaptureSession session) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      await pumpEventQueue();
      if (!session.isCapturingPosition) return;
    }
    fail('a capture never finished within 20 s');
  }

  /// Drives a session the way a user would: aim at the current target, hold
  /// still, wait out the dwell, let the shutter fire.
  ///
  /// Returns the number of positions captured. Timestamps advance on the pose
  /// clock, which is the same monotonic microsecond base the camera stamps
  /// frames with — so the shutter always lands inside the buffered window and
  /// the whole run is deterministic.
  Future<int> shoot(
    SphereCaptureSession session,
    FakePoseSource poses,
    FakeCameraPlatform camera, {
    required int positions,
  }) async {
    var clockUs = 2000000;
    for (var i = 0; i < positions; i++) {
      final target = session.currentTarget;
      if (target == null) break;
      final before = session.positions.length;
      // Three samples: arrive, hold, and hold past the 350 ms dwell.
      for (final offsetMs in [0, 100, 400]) {
        clockUs += offsetMs * 1000;
        camera.nextShutterUs = clockUs;
        poses.emit(poseAtTarget(target, timestampUs: clockUs));
        await pumpEventQueue();
      }
      await settle(session);
      clockUs += 100000;
      if (session.positions.length == before) {
        // Nothing was accepted — the caller is testing a rejection.
        return session.positions.length;
      }
    }
    return session.positions.length;
  }

  Future<
    ({
      SphereCaptureSession session,
      FakeCameraPlatform camera,
      FakePoseSource poses,
      FakeWakelock wakelock,
    })
  >
  start({
    SphereCaptureConfig config = const SphereCaptureConfig(),
    double sharpness = 100,
    Directory? directory,
  }) async {
    final camera = FakeCameraPlatform(intrinsics: fovIntrinsics(50, 69));
    final poses = FakePoseSource();
    final wakelock = FakeWakelock();
    final session = await SphereCaptureSession.create(
      config: config,
      camera: camera,
      poseSource: poses,
      directory: directory ?? root,
      sessionId: 'station-test',
      wakelock: wakelock,
      measureSharpness: (_) async => sharpness,
    );
    await session.beginMetering();
    await session.beginCapture();
    return (
      session: session,
      camera: camera,
      poses: poses,
      wakelock: wakelock,
    );
  }

  group('creation refuses what cannot work, before the camera opens', () {
    test('a device with no gyroscope is refused at the entry point', () async {
      // Phase 12 §1. Without a gyroscope there is no attitude source that
      // tracks a pan, and the failure would only become visible after the
      // manager had walked the whole building.
      final camera = FakeCameraPlatform();
      await expectLater(
        SphereCaptureSession.create(
          camera: camera,
          poseSource: FakePoseSource(supported: false),
          directory: root,
        ),
        throwsA(
          isA<PoseSourceUnsupported>().having(
            (e) => e.message,
            'message',
            contains('no gyroscope'),
          ),
        ),
      );
      // And the camera was never even opened.
      expect(camera.meteringCalls, 0);
    });

    test('a plan that cannot cover the sphere refuses, and gives the camera '
        'back', () async {
      final camera = FakeCameraPlatform(intrinsics: fovIntrinsics(50, 69));
      await expectLater(
        SphereCaptureSession.create(
          config: const SphereCaptureConfig(overlapFraction: 0.05),
          camera: camera,
          poseSource: FakePoseSource(),
          directory: root,
        ),
        throwsA(isA<InsufficientCoverageException>()),
      );
      // Never open the camera on a plan that cannot succeed — and never leave
      // it open either.
      expect(camera.closed, isTrue);
      expect(camera.meteringCalls, 0);
    });

    test('the plan is built in the device frame, not the sensor frame', () async {
      // A camera mounted 90° from the display delivers a landscape frame while
      // the tablet is portrait-locked. Planning from it unrotated would swap
      // the horizontal and vertical fields of view and produce a plan for a
      // camera held the other way round — which still looks like a plan.
      final landscape = FakeCameraPlatform(
        intrinsics: fovIntrinsics(69, 50, width: 4032),
        sensorOrientationDegrees: 90,
      );
      final session = await SphereCaptureSession.create(
        camera: landscape,
        poseSource: FakePoseSource(),
        directory: root,
      );
      expect(session.deviceIntrinsics.hfovDegrees, closeTo(50, 0.1));
      expect(session.deviceIntrinsics.vfovDegrees, closeTo(69, 0.1));
      // 29 rings-and-poles positions plus the nadir pair, which is planned by
      // default: the floor is two shutter presses and real pixels, against a cap
      // the push-pull fill can only turn into flat grey.
      expect(session.plan.length, 31);
      await session.dispose();
    });
  });

  group('the capture loop', () {
    test('the default meters nothing and locks nothing', () async {
      // `ExposureStrategy.auto` is the shipping default: each position is
      // metered by the camera as it is shot. There is no sweep to run and no
      // lock to take, and the 2 s the sweep used to cost is given back.
      final run = await start();
      expect(run.wakelock.acquired, isTrue);
      expect(
        run.camera.meteringCalls,
        0,
        reason: 'a locked value is exactly what auto exposure does not want',
      );
      expect(run.session.phase, SessionPhase.capturing);
      await run.session.finish();
      expect(run.wakelock.released, isTrue);
      expect(run.camera.closed, isTrue);
      await run.poses.dispose();
    });

    test('holds the screen awake and locks exposure once', () async {
      final run = await start(config: bracketConfig);
      expect(run.wakelock.acquired, isTrue);
      expect(run.camera.meteringCalls, 1);
      expect(run.session.phase, SessionPhase.capturing);
      await run.session.finish();
      expect(run.wakelock.released, isTrue);
      expect(run.camera.unlocked, isTrue);
      expect(run.camera.closed, isTrue);
      await run.poses.dispose();
    });

    test('frames are on disk the moment the position is accepted', () async {
      final run = await start(config: bracketConfig);
      await shoot(run.session, run.poses, run.camera, positions: 2);
      expect(run.session.positions, hasLength(2));
      // Six JPEGs for two bracketed positions, all real files — never 87 of
      // them held in memory.
      expect(run.camera.written, hasLength(6));
      for (final path in run.camera.written) {
        expect(File(path).existsSync(), isTrue);
      }
      // And the paths in the manifest are relative, so the bundle survives
      // being copied off the device.
      for (final shot in run.session.positions.first.shots) {
        expect(shot.filePath, isNot(startsWith('/')));
        expect(File('${root.path}/${shot.filePath}').existsSync(), isTrue);
      }
      await run.session.finish();
      await run.poses.dispose();
    });

    test('the manifest is rewritten after every position', () async {
      final run = await start();
      final manifest = File('${root.path}/${CaptureBundle.manifestFileName}');
      expect(manifest.existsSync(), isTrue, reason: 'written before the first '
          'shutter, so even a crash during the first bracket is resumable');

      for (var expected = 1; expected <= 3; expected++) {
        await shoot(run.session, run.poses, run.camera, positions: 1);
        final decoded =
            jsonDecode(manifest.readAsStringSync()) as Map<String, Object?>;
        expect(
          (decoded['positions']! as List).length,
          expected,
          reason: 'the manifest lagged the capture at position $expected',
        );
      }
      await run.session.finish();
      await run.poses.dispose();
    });

    test('positions are shot in plan order, equator first', () async {
      final run = await start();
      await shoot(run.session, run.poses, run.camera, positions: 12);
      final indices = run.session.positions.map((p) => p.targetIndex).toList();
      expect(indices, List.generate(12, (i) => i));
      // The first eleven are the equator ring — the useful part, done first.
      for (final position in run.session.positions.take(11)) {
        expect(run.session.plan.targets[position.targetIndex].pitch, 0);
      }
      await run.session.finish();
      await run.poses.dispose();
    });

    test('a camera that cannot bracket captures one exposure, and says so',
        () async {
      // R3 found bracket support is per-device and undocumented. Asking a
      // single-shot camera for three exposures returns one frame — and a frame
      // gate still expecting three would reject *every* position as an
      // incomplete bracket, turning a device that captures without HDR into one
      // that captures nothing at all.
      final camera = FakeCameraPlatform(
        intrinsics: fovIntrinsics(50, 69),
        bracketMode: BracketMode.singleShot,
        maxBracketCount: 1,
        shotsPerBracket: 1,
      );
      final poses = FakePoseSource();
      final session = await SphereCaptureSession.create(
        // A bracket is what makes this test mean anything: the point is that
        // asking a single-shot camera for three exposures degrades to one with
        // an explanation, rather than failing every position. Under the `auto`
        // default only one exposure is ever requested, so there would be
        // nothing to degrade.
        config: bracketConfig,
        camera: camera,
        poseSource: poses,
        directory: root,
        sessionId: 'station-test',
        wakelock: FakeWakelock(),
        measureSharpness: (_) async => 100.0,
      );
      await session.beginMetering();
      await session.beginCapture();
      await shoot(session, poses, camera, positions: 2);

      expect(session.positions, hasLength(2));
      expect(session.positions.first.shots, hasLength(1));
      expect(camera.requestedBiases.first, [0.0]);
      // Never silently degrade (architecture §8).
      expect(
        session.warnings,
        contains(allOf(contains('singleShot'), contains('dynamic range'))),
      );
      await session.finish();
      await poses.dispose();
    });

    test('the pose written down is the one interpolated to the shutter', () async {
      final run = await start();
      await shoot(run.session, run.poses, run.camera, positions: 1);
      final position = run.session.positions.single;
      expect(position.pose.timestampUs, position.baseShot.timestampUs);
      await run.session.finish();
      await run.poses.dispose();
    });
  });

  group('test 13 — a blurred frame keeps the target pending', () {
    test('the position is not recorded and the target stays current', () async {
      final run = await start(sharpness: 5);
      final target = run.session.currentTarget!;
      await shoot(run.session, run.poses, run.camera, positions: 1);

      expect(run.session.positions, isEmpty);
      expect(run.session.currentTarget, target, reason: 'the target moved on');
      expect(run.session.pendingTargetIndices.first, target.index);

      // The files are cleaned up rather than left to be stitched by accident.
      for (final path in run.camera.written) {
        expect(File(path).existsSync(), isFalse);
      }
      await run.session.finish();
      await run.poses.dispose();
    });

    test('and the user is told which problem it was', () async {
      final run = await start(sharpness: 5);
      final messages = <String?>[];
      final subscription = run.session.states.listen((s) => messages.add(s.message));
      await shoot(run.session, run.poses, run.camera, positions: 1);
      await subscription.cancel();
      expect(
        messages.whereType<String>(),
        contains(FrameRejection.blurred.message),
      );
      await run.session.finish();
      await run.poses.dispose();
    });

    test('a re-shot target is accepted once it is sharp', () async {
      // The gate is not a dead end: this is the three-second re-prompt the
      // whole design trades a 60 s stitch discovery for.
      var sharpness = 5.0;
      final camera = FakeCameraPlatform(intrinsics: fovIntrinsics(50, 69));
      final poses = FakePoseSource();
      final session = await SphereCaptureSession.create(
        camera: camera,
        poseSource: poses,
        directory: root,
        sessionId: 'station-test',
        wakelock: FakeWakelock(),
        measureSharpness: (_) async => sharpness,
      );
      await session.beginMetering();
      await session.beginCapture();

      await shoot(session, poses, camera, positions: 1);
      expect(session.positions, isEmpty);
      sharpness = 200;
      await shoot(session, poses, camera, positions: 1);
      expect(session.positions, hasLength(1));
      await session.finish();
      await poses.dispose();
    });
  });

  group('test 14 — a crash after 12 positions resumes at 13', () {
    test('resume continues from the first uncaptured target', () async {
      final run = await start();
      await shoot(run.session, run.poses, run.camera, positions: 12);
      expect(run.session.positions, hasLength(12));

      // The kill: no finish(), no dispose, nothing flushed on the way out —
      // exactly what a phone call, a battery pull or an OOM leaves behind. All
      // that survives is what was already on disk.
      await run.poses.dispose();

      final camera = FakeCameraPlatform(intrinsics: fovIntrinsics(50, 69));
      final poses = FakePoseSource();
      final resumed = await SphereCaptureSession.resume(
        root,
        camera: camera,
        poseSource: poses,
        wakelock: FakeWakelock(),
        measureSharpness: (_) async => 100.0,
      );

      expect(resumed.positions, hasLength(12));
      // Positions 1–12 are shot; the next target is the thirteenth.
      expect(resumed.currentTarget!.index, 12);
      expect(resumed.pendingTargetIndices.first, 12);
      expect(resumed.pendingTargetIndices, hasLength(resumed.plan.length - 12));
      // The stored plan is authoritative — a rebuilt one would describe a
      // different sphere from the one half-captured.
      expect(resumed.plan.length, 31);

      await resumed.beginMetering();
      await resumed.beginCapture();
      await shoot(resumed, poses, camera, positions: 1);
      expect(resumed.positions, hasLength(13));
      expect(resumed.positions.last.targetIndex, 12);

      final bundle = await resumed.finish();
      expect(bundle.positions, hasLength(13));
      // Every frame from both halves is still on disk and still resolvable.
      for (final position in bundle.positions) {
        for (final shot in position.shots) {
          expect(shot.resolveIn(root).existsSync(), isTrue);
        }
      }
      await poses.dispose();
    });

    test('resuming into a camera with a different field of view is refused',
        () async {
      // §7 pitfall 4: a plan is valid for one intrinsics set. Mixing two
      // geometries into one bundle would be worse than refusing, because the
      // result would stitch and be subtly wrong.
      final run = await start();
      await shoot(run.session, run.poses, run.camera, positions: 3);
      await run.poses.dispose();

      final poses = FakePoseSource();
      await expectLater(
        SphereCaptureSession.resume(
          root,
          camera: FakeCameraPlatform(intrinsics: fovIntrinsics(56, 74)),
          poseSource: poses,
          wakelock: FakeWakelock(),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('cannot be resumed'),
              contains('still be stitched as a partial panorama'),
            ),
          ),
        ),
      );
      // The partial bundle is untouched.
      final bundle = await CaptureBundle.load(root);
      expect(bundle.positions, hasLength(3));
      await poses.dispose();
    });

    test('a manifest written mid-bracket is never truncated', () async {
      // `CaptureBundle.save` writes to a temp file and renames, so a kill at
      // any instant leaves either the previous manifest or the new one.
      final run = await start();
      await shoot(run.session, run.poses, run.camera, positions: 2);
      final manifest = File('${root.path}/${CaptureBundle.manifestFileName}');
      final decoded = jsonDecode(manifest.readAsStringSync());
      expect(decoded, isA<Map<String, Object?>>());
      expect(File('${manifest.path}.tmp').existsSync(), isFalse);
      await run.session.finish();
      await run.poses.dispose();
    });
  });

  group('test 15 — finish() on an incomplete plan', () {
    test('60% of the plan yields a valid bundle with an honest number',
        () async {
      final run = await start();
      final wanted = (0.6 * run.session.plan.length).round();
      await shoot(run.session, run.poses, run.camera, positions: wanted);
      expect(run.session.positions, hasLength(wanted));

      final bundle = await run.session.finish();

      expect(bundle.completionFraction, closeTo(0.6, 0.02));
      expect(bundle.positions, hasLength(wanted));
      expect(bundle.plan.length, 31);

      // The coverage recorded is the one actually achieved, re-rasterised over
      // the positions that exist — not the plan's proof, which describes a
      // sphere that was never shot.
      final achieved = bundle.deviceInfo['achieved_coverage']! as Map;
      final report = CoverageReport.fromJson(achieved.cast<String, Object?>());
      expect(report.fractionCoveredAtLeastOnce, lessThan(1.0));
      expect(report.fractionCoveredAtLeastOnce, greaterThan(0.4));
      expect(
        report.fractionCoveredAtLeastOnce,
        lessThan(bundle.plan.coverage.fractionCoveredAtLeastOnce),
      );

      // And it is said out loud. Architecture §8: never silently degrade.
      final warnings = (bundle.deviceInfo['warnings']! as List).cast<String>();
      expect(
        warnings,
        contains(
          allOf(
            contains('incomplete'),
            contains('$wanted of ${bundle.plan.length}'),
            contains('of the sphere'),
          ),
        ),
      );

      // The bundle is loadable and complete enough to stitch.
      final reloaded = await CaptureBundle.load(root);
      expect(reloaded.positions, hasLength(wanted));
      expect(reloaded.plan.targets, hasLength(31));
      await run.poses.dispose();
    });

    test('a complete session records no shortfall', () async {
      final run = await start();
      final all = run.session.plan.length;
      await shoot(run.session, run.poses, run.camera, positions: all);
      expect(run.session.positions, hasLength(all));
      expect(run.session.phase, SessionPhase.completed);

      final bundle = await run.session.finish();
      expect(bundle.completionFraction, 1.0);
      expect(bundle.deviceInfo['achieved_coverage'], isNull);
      final warnings = (bundle.deviceInfo['warnings']! as List).cast<String>();
      expect(warnings.where((w) => w.contains('incomplete')), isEmpty);
      await run.poses.dispose();
    });

    test('finishing with nothing captured still produces a valid bundle',
        () async {
      // The user opened the feature and changed their mind. That is not an
      // error, and it must not throw.
      final run = await start();
      final bundle = await run.session.finish();
      expect(bundle.positions, isEmpty);
      expect(bundle.completionFraction, 0);
      expect(await CaptureBundle.load(root), isNotNull);
      await run.poses.dispose();
    });

    test('abort throws the partial capture away, deliberately', () async {
      final run = await start();
      await shoot(run.session, run.poses, run.camera, positions: 2);
      await run.session.abort();
      expect(root.existsSync(), isFalse);
      expect(run.session.phase, SessionPhase.aborted);
      await run.poses.dispose();
    });
  });

  group('interruptions are the normal case, not the exception', () {
    test('an interruption pauses, and its end resumes', () async {
      final run = await start();
      await shoot(run.session, run.poses, run.camera, positions: 1);

      run.camera.emitInterruption(true, 'a phone call');
      await pumpEventQueue();
      expect(run.session.phase, SessionPhase.paused);

      // Poses keep arriving while paused, and nothing fires.
      final before = run.session.positions.length;
      await shoot(run.session, run.poses, run.camera, positions: 1);
      expect(run.session.positions, hasLength(before));

      run.camera.emitInterruption(false, 'call ended');
      await pumpEventQueue();
      expect(run.session.phase, SessionPhase.capturing);
      await shoot(run.session, run.poses, run.camera, positions: 1);
      expect(run.session.positions, hasLength(before + 1));

      await run.session.finish();
      await run.poses.dispose();
    });

    test('a critical thermal state stops capture with a plain sentence',
        () async {
      final run = await start();
      run.camera.emitThermal(ThermalState.critical);
      await pumpEventQueue();
      expect(run.session.phase, SessionPhase.paused);
      final bundle = await run.session.finish();
      final warnings = (bundle.deviceInfo['warnings']! as List).cast<String>();
      expect(warnings, contains(contains('too hot to capture')));
      await run.poses.dispose();
    });

    test('a dropped burst is reported and the target stays pending', () async {
      final run = await start();
      final target = run.session.currentTarget!;
      run.camera.failNextCapture = true;
      await shoot(run.session, run.poses, run.camera, positions: 1);
      expect(run.session.positions, isEmpty);
      expect(run.session.currentTarget, target);
      await run.session.finish();
      await run.poses.dispose();
    });
  });

  group('output metadata reaches the bundle (Phase 11 §2)', () {
    test('the plan heading wins over the magnetometer, whatever the order',
        () async {
      // §2's priority order, and the order the two arrive in must not decide
      // it: the plan's north is surveyed and its heading is good to a degree
      // or two, while the magnetometer indoors is good to tens. A fresher
      // reading from a worse instrument is still a worse answer.
      final run = await start();
      run.session.setMagnetometerHeading(310.0);
      run.session.setPlanHeading(127.5);
      run.session.setMagnetometerHeading(42.0);

      final bundle = await run.session.finish();
      expect(bundle.heading.source, HeadingSource.plan);
      expect(bundle.heading.degrees, closeTo(127.5, 1e-9));
      expect(bundle.heading.isTrustworthy, isTrue);
      await run.poses.dispose();
    });

    test('a magnetometer heading is recorded as one, with its warning',
        () async {
      final run = await start();
      run.session.setMagnetometerHeading(310.0);

      final bundle = await run.session.finish();
      expect(bundle.heading.source, HeadingSource.magnetometer);
      expect(bundle.heading.isTrustworthy, isFalse);
      expect(bundle.heading.warning?.code, StitchWarningCode.headingFromMagnetometer);
      expect(bundle.heading.warning?.message, contains('compass'));
      await run.poses.dispose();
    });

    test('no heading at all stays unknown rather than becoming north',
        () async {
      // Nothing was set, so nothing is claimed. Zero here would be due north.
      final run = await start();
      final bundle = await run.session.finish();
      expect(bundle.heading, PanoramaHeading.unknown);
      expect(bundle.heading.degrees, isNull);
      await run.poses.dispose();
    });

    test('the capture time and the device identity reach the bundle', () async {
      // EXIF `DateTimeOriginal` and `Make`/`Model`. The timestamp is taken at
      // session start rather than at save, because a bundle may be written
      // well after the last shutter and the useful fact is when the capture
      // happened.
      final before = DateTime.now().toUtc();
      final run = await start();
      await shoot(run.session, run.poses, run.camera, positions: 2);
      final bundle = await run.session.finish();

      expect(bundle.capturedAt, isNotNull);
      expect(bundle.capturedAt!.isBefore(before.subtract(
        const Duration(seconds: 1),
      )), isFalse);
      expect(bundle.capturedAt!.isUtc, isTrue);

      final identity =
          (bundle.deviceInfo['device_identity']! as Map).cast<String, Object?>();
      expect(identity['make'], 'FakeCorp');
      expect(identity['model'], 'Tablet-1');
      await run.poses.dispose();
    });

    test('a supplied GPS fix reaches the bundle', () async {
      // Supplied rather than measured: this package holds no location
      // permission and deliberately does not ask for one.
      final run = await start();
      run.session.setLocation(
        GeoLocation(latitudeDegrees: 51.5074, longitudeDegrees: -0.1278),
      );
      final bundle = await run.session.finish();
      expect(bundle.location!.latitudeDegrees, closeTo(51.5074, 1e-9));
      expect(bundle.location!.longitudeDegrees, closeTo(-0.1278, 1e-9));
      await run.poses.dispose();
    });

    test('all of it survives a save and reload', () async {
      final run = await start();
      run.session.setPlanHeading(127.5);
      run.session.setLocation(
        GeoLocation(latitudeDegrees: 51.5074, longitudeDegrees: -0.1278),
      );
      final bundle = await run.session.finish();

      final reloaded = await CaptureBundle.load(root);
      expect(reloaded.heading, bundle.heading);
      expect(reloaded.location, bundle.location);
      expect(reloaded.capturedAt, bundle.capturedAt);
      await run.poses.dispose();
    });
  });

  group('retake', () {
    test('drops the captured position and re-queues the target at the end',
        () async {
      final run = await start();
      await shoot(run.session, run.poses, run.camera, positions: 3);
      expect(run.session.positions, hasLength(3));

      run.session.retake(1);
      expect(run.session.positions, hasLength(2));
      expect(run.session.positions.map((p) => p.targetIndex), [0, 2]);
      // Appended, not inserted: the user is standing somewhere specific and
      // aiming at something specific.
      expect(run.session.pendingTargetIndices.last, 1);
      expect(run.session.currentTarget!.index, 3);

      await run.session.finish();
      await run.poses.dispose();
    });

    test('an out-of-range index is a programming error', () async {
      final run = await start();
      expect(() => run.session.retake(999), throwsRangeError);
      await run.session.finish();
      await run.poses.dispose();
    });
  });

  group('manual capture', () {
    test('fires without the gates, but never past the quality checks',
        () async {
      final run = await start(
        config: const SphereCaptureConfig(autoShutter: false),
        sharpness: 100,
      );
      // Aimed nowhere near the target, and the auto shutter is off.
      run.camera.nextShutterUs = 3000000;
      run.poses.emit(poseAimedAt(2.0, 0.5, timestampUs: 3000000));
      await pumpEventQueue();
      expect(run.session.positions, isEmpty);

      await run.session.captureManual();
      await settle(run.session);
      expect(run.session.positions, hasLength(1));

      await run.session.finish();
      await run.poses.dispose();
    });

    test('a manual shot that is blurred is still rejected', () async {
      // Asking to shoot now is a statement about aim, not a claim that a
      // blurred frame is usable. §4 — sharpness is never relaxed, by anyone.
      final run = await start(
        config: const SphereCaptureConfig(autoShutter: false),
        sharpness: 1,
      );
      run.camera.nextShutterUs = 3000000;
      run.poses.emit(poseAimedAt(0, 0, timestampUs: 3000000));
      await pumpEventQueue();
      await run.session.captureManual();
      await settle(run.session);
      expect(run.session.positions, isEmpty);
      await run.session.finish();
      await run.poses.dispose();
    });
  });
}
