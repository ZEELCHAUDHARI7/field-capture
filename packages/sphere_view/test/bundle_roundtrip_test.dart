import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

import 'fixtures.dart';

/// The most important test in Phase 01.
///
/// Offline replay and resume-after-crash both stand on `CaptureBundle.save()`
/// and `.load()` being an exact round-trip (architecture §6.6). If a single
/// double loses a bit, the desktop pipeline is no longer running on the same
/// data the device captured, which quietly invalidates the entire regression
/// corpus — and it invalidates it *silently*, which is the worst property a
/// test harness can have.
///
/// So this asserts field-by-field equality rather than only `==`: a `==` that
/// forgot a field would let a real regression through, and these tests exist
/// precisely to catch what nobody was watching for.
void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('sphere_view_bundle_');
  });

  tearDown(() async {
    if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
  });

  test('save() then load() reproduces every field exactly', () async {
    final original = sampleBundle(tempRoot);
    await original.save();
    final loaded = await CaptureBundle.load(tempRoot);

    expect(loaded, original, reason: 'value equality');

    // And field by field, so a hole in == cannot hide a real difference.
    expect(loaded.sessionId, original.sessionId);
    expect(loaded.directory.path, original.directory.path);
    expect(loaded.heading, original.heading);
    expect(loaded.location, original.location);
    expect(loaded.capturedAt, original.capturedAt);
    expect(loaded.intrinsics, original.intrinsics);
    expect(loaded.plan, original.plan);
    expect(loaded.positions.length, original.positions.length);
    expect(loaded.deviceInfo, original.deviceInfo);
  });

  test('every double survives to the last bit', () async {
    final original = sampleBundle(tempRoot);
    await original.save();
    final loaded = await CaptureBundle.load(tempRoot);

    final k = loaded.intrinsics;
    final ok = original.intrinsics;
    // Bit-exact, not closeTo: a focal that drifts in the last place would
    // still pass an epsilon comparison but would no longer be the number the
    // device measured.
    expect(k.fx, ok.fx);
    expect(k.fy, ok.fy);
    expect(k.cx, ok.cx);
    expect(k.cy, ok.cy);
    expect(k.imageSize.width, ok.imageSize.width);
    expect(k.imageSize.height, ok.imageSize.height);

    final d = k.distortion! as BrownConradyDistortion;
    final od = ok.distortion! as BrownConradyDistortion;
    expect(d.openCvCoefficients, od.openCvCoefficients);

    expect(loaded.heading, original.heading);
    expect(loaded.location, original.location);
    expect(loaded.capturedAt, original.capturedAt);
    expect(loaded.plan.overlapFraction, original.plan.overlapFraction);
    expect(
      loaded.plan.coverage.fractionCoveredAtLeastOnce,
      original.plan.coverage.fractionCoveredAtLeastOnce,
    );
    expect(
      loaded.plan.coverage.fractionCoveredAtLeastTwice,
      original.plan.coverage.fractionCoveredAtLeastTwice,
    );
    expect(loaded.plan.coverage.gaps, original.plan.coverage.gaps);
  });

  test('poses survive, including the quaternion and gravity components',
      () async {
    final original = sampleBundle(tempRoot);
    await original.save();
    final loaded = await CaptureBundle.load(tempRoot);

    for (var i = 0; i < original.positions.length; i++) {
      final a = original.positions[i].pose;
      final b = loaded.positions[i].pose;
      expect(b.deviceToWorld.x, a.deviceToWorld.x, reason: 'pose $i qx');
      expect(b.deviceToWorld.y, a.deviceToWorld.y, reason: 'pose $i qy');
      expect(b.deviceToWorld.z, a.deviceToWorld.z, reason: 'pose $i qz');
      expect(b.deviceToWorld.w, a.deviceToWorld.w, reason: 'pose $i qw');
      expect(b.gravityWorld.x, a.gravityWorld.x, reason: 'pose $i gx');
      expect(b.gravityWorld.y, a.gravityWorld.y, reason: 'pose $i gy');
      expect(b.gravityWorld.z, a.gravityWorld.z, reason: 'pose $i gz');
      // The microsecond timestamp is 16 digits — well past double precision,
      // so this fails immediately if it were ever widened to a double.
      expect(b.timestampUs, a.timestampUs, reason: 'pose $i timestamp');
      expect(b.angularSpeedRadPerSec, a.angularSpeedRadPerSec);
    }
  });

  test('shots survive, including null optionals', () async {
    final original = sampleBundle(tempRoot);
    await original.save();
    final loaded = await CaptureBundle.load(tempRoot);

    final loadedShots = loaded.positions.first.shots;
    final originalShots = original.positions.first.shots;
    expect(loadedShots.length, originalShots.length);
    for (var i = 0; i < originalShots.length; i++) {
      expect(loadedShots[i], originalShots[i], reason: 'shot $i');
      // A platform that did not report exposure time must round-trip as "not
      // reported", never as zero.
      expect(loadedShots[i].exposureTimeNs, originalShots[i].exposureTimeNs);
      expect(loadedShots[i].iso, originalShots[i].iso);
    }
    expect(loadedShots.last.exposureTimeNs, isNull);
    expect(loadedShots.last.iso, isNull);
  });

  test('the untyped deviceInfo map survives nesting, nulls and types',
      () async {
    final original = sampleBundle(tempRoot);
    await original.save();
    final loaded = await CaptureBundle.load(tempRoot);

    expect(loaded.deviceInfo['total_ram_mb'], 6144);
    expect(loaded.deviceInfo['has_gyroscope'], true);
    expect(loaded.deviceInfo['burst_latency_ms'], 612.4387);
    expect(loaded.deviceInfo['unset_field'], isNull);
    expect(loaded.deviceInfo.containsKey('unset_field'), isTrue);
    expect(loaded.deviceInfo['plugin_versions'], {
      'camera': '0.1.0',
      'ahrs': '0.1.0',
    });
    expect(loaded.deviceInfo['warnings'], isA<List<Object?>>());
  });

  test('an unknown heading stays unknown rather than becoming zero', () async {
    // Zero is a real bearing — due north. A heading that survives the round
    // trip as 0 would be indistinguishable from a surveyed one, and every
    // viewer would open the sphere confidently facing the wrong way
    // (Phase 11 §2).
    expect(sampleBundle(tempRoot).heading.isKnown, isTrue);

    final withoutHeading = CaptureBundle(
      sessionId: 'no-heading',
      directory: tempRoot,
      plan: samplePlan,
      intrinsics: sampleIntrinsics,
      positions: samplePositions,
      deviceInfo: const {},
    );
    await withoutHeading.save();
    final loaded = await CaptureBundle.load(tempRoot);
    expect(loaded.heading, PanoramaHeading.unknown);
    expect(loaded.heading.degrees, isNull);
    expect(loaded, withoutHeading);
  });

  test('a heading carries its source across the round trip', () async {
    // The source is the whole point of recording it: a magnetometer heading
    // indoors can be tens of degrees out, so a panorama that opens facing the
    // wrong way has to be traceable to the instrument that said so.
    final magnetic = CaptureBundle(
      sessionId: 'magnetic',
      directory: tempRoot,
      plan: samplePlan,
      intrinsics: sampleIntrinsics,
      positions: samplePositions,
      heading: PanoramaHeading.fromMagnetometer(310.5),
      deviceInfo: const {},
    );
    await magnetic.save();
    final loaded = await CaptureBundle.load(tempRoot);
    expect(loaded.heading.source, HeadingSource.magnetometer);
    expect(loaded.heading.degrees, closeTo(310.5, 1e-9));
    expect(loaded.heading.isTrustworthy, isFalse);
  });

  test('a pre-Phase-11 manifest loads its bare heading as magnetometer', () {
    // The conservative reading, and the only defensible one: the field existed
    // when the magnetometer was the only source there was. Promoting an old
    // number to a plan heading would manufacture exactly the false confidence
    // §2 exists to prevent.
    final legacy = {
      ...sampleBundle(tempRoot).toJson(),
      'heading': null,
      'heading_degrees': 88.25,
    };
    final loaded = CaptureBundle.fromJson(legacy, tempRoot);
    expect(loaded.heading.source, HeadingSource.magnetometer);
    expect(loaded.heading.degrees, closeTo(88.25, 1e-9));
  });

  test('an empty partial capture is still a valid bundle', () async {
    // A session the user quit before shooting anything must still produce
    // something loadable — architecture §8 says emit an honest partial rather
    // than pretend.
    final empty = CaptureBundle(
      sessionId: 'abandoned',
      directory: tempRoot,
      plan: samplePlan,
      intrinsics: sampleIntrinsics,
      positions: const [],
      deviceInfo: const {},
    );
    await empty.save();
    final loaded = await CaptureBundle.load(tempRoot);
    expect(loaded, empty);
    expect(loaded.positions, isEmpty);
    expect(loaded.completionFraction, 0);
  });

  test('round-tripping repeatedly is a fixed point', () async {
    // Two saves and loads must not drift — if the first round-trip is lossy in
    // any direction, the second exposes it.
    var current = sampleBundle(tempRoot);
    for (var i = 0; i < 3; i++) {
      await current.save();
      final loaded = await CaptureBundle.load(tempRoot);
      expect(loaded, current, reason: 'iteration $i');
      current = loaded;
    }
  });

  test('the manifest is JSON we can read, at the documented filename',
      () async {
    await sampleBundle(tempRoot).save();
    final file = File(
      '${tempRoot.path}${Platform.pathSeparator}'
      '${CaptureBundle.manifestFileName}',
    );
    expect(file.existsSync(), isTrue);

    final decoded = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(decoded['schema_version'], CaptureBundle.schemaVersion);
    expect(decoded['session_id'], isA<String>());
    expect(decoded.containsKey('directory'), isFalse,
        reason: 'the directory is the location, not manifest content');
  });

  test('save() leaves no temporary file behind', () async {
    await sampleBundle(tempRoot).save();
    final leftovers = tempRoot
        .listSync()
        .where((e) => e.path.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('save() overwrites a previous manifest atomically', () async {
    await sampleBundle(tempRoot).save();
    final updated = sampleBundle(tempRoot).copyWith(sessionId: 'station-08');
    await updated.save();
    final loaded = await CaptureBundle.load(tempRoot);
    expect(loaded.sessionId, 'station-08');
  });

  test('load() rejects a directory with no manifest', () async {
    final empty = await Directory.systemTemp.createTemp('sphere_view_none_');
    addTearDown(() => empty.delete(recursive: true));
    expect(
      () => CaptureBundle.load(empty),
      throwsA(isA<SphereJsonFormatException>()),
    );
  });

  test('load() refuses a manifest from an unknown schema version', () async {
    // Loading a future bundle into the wrong field meanings would be worse
    // than failing, so the version gate must be hard.
    final original = sampleBundle(tempRoot);
    await original.save();
    final file = File(
      '${tempRoot.path}${Platform.pathSeparator}'
      '${CaptureBundle.manifestFileName}',
    );
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    json['schema_version'] = CaptureBundle.schemaVersion + 1;
    await file.writeAsString(jsonEncode(json));

    expect(
      () => CaptureBundle.load(tempRoot),
      throwsA(isA<SphereJsonFormatException>()),
    );
  });

  test('load() reports a malformed field rather than throwing a TypeError',
      () async {
    await sampleBundle(tempRoot).save();
    final file = File(
      '${tempRoot.path}${Platform.pathSeparator}'
      '${CaptureBundle.manifestFileName}',
    );
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    (json['intrinsics']! as Map<String, Object?>)['fx'] = 'not a number';
    await file.writeAsString(jsonEncode(json));

    expect(
      () => CaptureBundle.load(tempRoot),
      throwsA(
        isA<SphereJsonFormatException>().having(
          (e) => e.context,
          'context',
          contains('fx'),
        ),
      ),
    );
  });

  test('save() creates the directory if it does not exist yet', () async {
    final nested = Directory(
      '${tempRoot.path}${Platform.pathSeparator}stations'
      '${Platform.pathSeparator}07',
    );
    expect(nested.existsSync(), isFalse);
    await sampleBundle(nested).save();
    expect(nested.existsSync(), isTrue);
    expect(await CaptureBundle.load(nested), sampleBundle(nested));
  });

  test('a bundle moved to a new directory still loads', () async {
    // Shot paths are relative precisely so a bundle copied off a device stays
    // replayable. If they were absolute this would fail on the second load.
    await sampleBundle(tempRoot).save();
    final moved = Directory(
      '${tempRoot.parent.path}${Platform.pathSeparator}'
      '${tempRoot.uri.pathSegments.where((s) => s.isNotEmpty).last}_moved',
    );
    addTearDown(() async {
      if (moved.existsSync()) await moved.delete(recursive: true);
    });
    await tempRoot.rename(moved.path);

    final loaded = await CaptureBundle.load(moved);
    expect(loaded.directory.path, moved.path);
    expect(loaded.positions.first.shots.first.filePath, 'pos_000_ev-2.jpg');
    expect(
      loaded.positions.first.shots.first.resolveIn(moved).path,
      '${moved.path}${Platform.pathSeparator}pos_000_ev-2.jpg',
    );
  });
    test('captureQuarterTurns survives, because nothing can recover it', () {
      // It is a fact about the device that took these frames — not derivable
      // from the pixels, the poses or the intrinsics. Lost in the manifest, it
      // is lost for good, and every seed the stitcher builds is rolled a
      // quarter turn with nothing to say so.
      final original = sampleBundle(tempRoot).copyWith(captureQuarterTurns: 1);
      expect(
        CaptureBundle.fromJson(original.toJson(), tempRoot).captureQuarterTurns,
        1,
      );
    });

    test('a manifest written before captureQuarterTurns loads as 0', () {
      // The replay corpus is permanent (arch §6.6). Every bundle in it was
      // rendered and recorded in one frame, so 0 is not a fallback there — it
      // is the right answer.
      final json = sampleBundle(tempRoot).toJson()
        ..remove('capture_quarter_turns');
      expect(CaptureBundle.fromJson(json, tempRoot).captureQuarterTurns, 0);
    });

}
