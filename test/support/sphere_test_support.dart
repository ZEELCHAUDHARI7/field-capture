import 'dart:io';

import 'package:field_capture/features/plan/data/sphere_capture_store.dart';
import 'package:field_capture/shared/storage/sphere_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

/// The two providers `main()` resolves before `runApp`.
///
/// Any container that reaches `planRepositoryProvider`, the stitch queue or the
/// capture flow needs them, because they are deliberately unimplemented by
/// default — a provider that silently invented a directory would write real
/// files into whatever the test's working directory happened to be.
///
/// The temporary directory is deleted on tear-down.
List<Override> sphereStorageOverrides({String prefix = 'field_capture_test'}) {
  final Directory temp = Directory.systemTemp.createTempSync(prefix);

  // Registered before the caller's `addTearDown(container.dispose)`, and
  // `addTearDown` runs LIFO — so the container is disposed, which stops the
  // stitch queue, and only then is the directory removed. The other order
  // deletes the directory out from under a queue that is still writing its
  // state file, which fails as a PathNotFoundException in an unrelated test.
  addTearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  final SphereStorage storage = SphereStorage(temp);
  Directory('${temp.path}/bundles').createSync(recursive: true);
  Directory('${temp.path}/panoramas').createSync(recursive: true);

  return <Override>[
    sphereStorageProvider.overrideWithValue(storage),
    sphereCaptureStoreProvider
        .overrideWithValue(SphereCaptureStore(storage.captureStoreFile)),
  ];
}

/// The smallest [CaptureBundle] the app's own code paths accept.
///
/// Deliberately not a captured one: nothing under test here reads a frame. What
/// the app does with a bundle is take its `sessionId`, write a pin, and hand it
/// to the queue — so the parts that matter are the id and the directory, and
/// filling the rest with plausible geometry keeps the fixture honest without
/// pretending to be a capture.
CaptureBundle fakeBundle({
  required String sessionId,
  required Directory directory,
}) {
  const CameraIntrinsics intrinsics = CameraIntrinsics(
    fx: 1400,
    fy: 1400,
    cx: 1000,
    cy: 750,
    imageSize: ImageSize(2000, 1500),
    source: IntrinsicsSource.derivedFromPhysics,
  );

  return CaptureBundle(
    sessionId: sessionId,
    directory: directory,
    plan: const CapturePlan(
      targets: <CaptureTarget>[
        CaptureTarget(
          index: 0,
          ringIndex: 0,
          indexInRing: 0,
          yaw: 0,
          pitch: 0,
          ringLabel: 'horizon',
        ),
      ],
      intrinsics: intrinsics,
      overlapFraction: 0.33,
      coverage: CoverageReport(
        fractionCoveredAtLeastOnce: 1,
        fractionCoveredAtLeastTwice: 1,
        gaps: <({double yaw, double pitch})>[],
      ),
    ),
    intrinsics: intrinsics,
    positions: const <CapturedPosition>[],
    deviceInfo: const <String, Object?>{'model': 'test double'},
  );
}
