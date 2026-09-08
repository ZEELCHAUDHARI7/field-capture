/// Model instances shared by the round-trip and schema tests.
///
/// Every value here is deliberately *awkward*: irrational doubles rather than
/// round numbers, negative and positive exposure biases, a null beside a
/// non-null optional, a nested untyped map. Round-tripping tidy values proves
/// almost nothing — `1.0` survives any encoder — whereas these catch precision
/// loss, `int`/`double` confusion, and dropped optionals, which are the three
/// ways a manifest silently changes meaning between write and read.
library;

import 'dart:io';

import 'package:sphere_view/sphere_view.dart';
import 'package:vector_math/vector_math_64.dart';

/// Distortion with all five coefficients distinct and non-zero.
const BrownConradyDistortion sampleDistortion = BrownConradyDistortion(
  k1: -0.2134567890123,
  k2: 0.0712345678901,
  p1: 0.0012345678901,
  p2: -0.0023456789012,
  k3: -0.0098765432109,
);

/// An iOS-style radial magnification table.
const LookupTableDistortion sampleLookupTable = LookupTableDistortion(
  magnifications: [1.0, 1.0034567, 1.0141234, 1.0329876, 1.0612345],
  centerX: 1511.7345,
  centerY: 2015.2891,
);

/// Intrinsics with a non-centred principal point, so a swapped cx/cy is
/// visible.
final CameraIntrinsics sampleIntrinsics = CameraIntrinsics(
  fx: 3242.5966123456,
  fy: 3244.1187654321,
  cx: 1509.3344556677,
  cy: 2019.8877665544,
  imageSize: const ImageSize(3024, 4032),
  source: IntrinsicsSource.derivedFromPhysics,
  distortion: sampleDistortion,
);

/// A pose that is not the identity on any axis.
DevicePose samplePose({int timestampUs = 1738245901234567}) => DevicePose(
  deviceToWorld: Quaternion(
    0.1234567890123,
    -0.4567890123456,
    0.7890123456789,
    0.3987654321098,
  ),
  gravityWorld: Vector3(0.0123456789, 0.9987654321, -0.0456789012),
  timestampUs: timestampUs,
  angularSpeedRadPerSec: 0.0837465912345,
);

/// A coverage report that is *not* acceptable, so a test asserting
/// `isAcceptable` cannot pass by accident.
const CoverageReport sampleCoverage = CoverageReport(
  fractionCoveredAtLeastOnce: 0.99873456,
  fractionCoveredAtLeastTwice: 0.94219876,
  gaps: [
    (yaw: -3.0419876543, pitch: -1.5533211234),
    (yaw: 1.7712345678, pitch: 1.4998877665),
  ],
);

/// Three targets across two rings, mirroring the stagger of Math §8.
const List<CaptureTarget> sampleTargets = [
  CaptureTarget(
    index: 0,
    ringIndex: 0,
    indexInRing: 0,
    yaw: 0.0,
    pitch: 0.0,
    ringLabel: 'middle row',
  ),
  CaptureTarget(
    index: 1,
    ringIndex: 0,
    indexInRing: 1,
    yaw: -0.5711986643,
    pitch: 0.0,
    ringLabel: 'middle row',
  ),
  CaptureTarget(
    index: 2,
    ringIndex: 1,
    indexInRing: 0,
    yaw: -0.2855993321,
    pitch: 0.8063420421,
    ringLabel: 'upper row',
  ),
];

/// A plan over [sampleTargets].
CapturePlan get samplePlan => CapturePlan(
  targets: sampleTargets,
  intrinsics: sampleIntrinsics,
  overlapFraction: 0.33,
  coverage: sampleCoverage,
);

/// A three-shot bracket with a null-and-non-null mix in the optional fields.
const List<ExposureShot> sampleShots = [
  ExposureShot(
    filePath: 'pos_000_ev-2.jpg',
    evBias: -2.0,
    timestampUs: 1738245901234567,
    exposureTimeNs: 4166667,
    iso: 400,
  ),
  ExposureShot(
    filePath: 'pos_000_ev0.jpg',
    evBias: 0.0,
    timestampUs: 1738245901301234,
    exposureTimeNs: 16666667,
    iso: 400,
  ),
  ExposureShot(
    // Optionals left null on purpose — a platform that does not report them
    // must round-trip as "not reported", not as zero.
    filePath: 'pos_000_ev+2.jpg',
    evBias: 2.0,
    timestampUs: 1738245901367890,
  ),
];

/// Two captured positions, so list ordering is exercised.
List<CapturedPosition> get samplePositions => [
  CapturedPosition(
    targetIndex: 0,
    pose: samplePose(),
    shots: sampleShots,
    sharpness: 187.4523876,
    steadinessRadPerSec: 0.0412345678,
  ),
  CapturedPosition(
    targetIndex: 1,
    pose: samplePose(timestampUs: 1738245903987654),
    shots: const [
      ExposureShot(
        filePath: 'pos_001_ev0.jpg',
        evBias: 0.0,
        timestampUs: 1738245903987654,
        exposureTimeNs: 16666667,
        iso: 500,
      ),
    ],
    sharpness: 92.1187654,
    steadinessRadPerSec: 0.1098765432,
  ),
];

/// Device diagnostics, nested and untyped, with every JSON scalar kind present.
const Map<String, Object?> sampleDeviceInfo = {
  // The block Phase 11 §2's EXIF Make/Model comes out of. Nested rather than
  // flat because it is one fact read once at open time, and the flat `model`
  // below is older diagnostic text that predates it.
  'device_identity': {
    'make': 'Samsung',
    'model': 'SM-X910',
    'os_version': 'Android 14 (API 34)',
  },
  'model': 'Galaxy Tab Active5',
  'os': 'Android 14',
  'total_ram_mb': 6144,
  'tier': 'mid',
  'thermal_state': 'nominal',
  'has_gyroscope': true,
  'lens_intrinsic_calibration_available': false,
  'burst_latency_ms': 612.4387,
  'plugin_versions': {'camera': '0.1.0', 'ahrs': '0.1.0'},
  'warnings': ['LENS_DISTORTION unavailable', 'DISTORTION_CORRECTION_MODE OFF'],
  'unset_field': null,
};

/// A complete bundle rooted at [directory].
CaptureBundle sampleBundle(Directory directory) => CaptureBundle(
  sessionId: 'station-07-2026-08-06T11:42:19.334Z',
  directory: directory,
  plan: samplePlan,
  intrinsics: sampleIntrinsics,
  positions: samplePositions,
  heading: PanoramaHeading.fromPlan(127.4839201),
  location: GeoLocation(
    latitudeDegrees: 51.5074,
    longitudeDegrees: -0.1278,
    altitudeMeters: 34.5,
  ),
  capturedAt: DateTime.utc(2026, 8, 6, 11, 42, 19),
  deviceInfo: sampleDeviceInfo,
);

/// A report that deliberately fails several targets, with warnings attached.
StitchReport get sampleReport => StitchReport(
  rmsReprojectionErrorPx: 0.8734512,
  loopClosureErrorDegrees: 0.1938476,
  maxGainRatio: 1.0187654,
  coverageFraction: 0.9987345,
  refinedFocalPx: 3251.7788991,
  refinedIntrinsics: sampleIntrinsics.copyWith(
    source: IntrinsicsSource.refinedByStitcher,
  ),
  residualTiltDegrees: 0.1123456,
  droppedPositionIndices: const [4, 17],
  warnings: const [
    StitchWarning(
      StitchWarningCode.imuOnlyFrames,
      data: {'frames': 2, 'total': 29, 'min_inliers': 25},
      detail: 'positions 4 and 17 fell back to the IMU prior',
    ),
    StitchWarning(
      StitchWarningCode.coverageIncomplete,
      data: {'fraction': 0.9987345},
      detail: 'the nadir cap was declared skipped and push-pull filled',
    ),
  ],
  elapsedMs: 41873,
  tierUsed: QualityTier.mid,
);

/// A finished panorama with [sampleReport].
StitchResult get sampleResult => StitchResult(
  equirectPath: '/data/user/0/app/panos/station-07.jpg',
  width: 6144,
  height: 3072,
  report: sampleReport,
);
