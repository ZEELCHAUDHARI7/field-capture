import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sphere_view/src/api/models/camera_intrinsics.dart';
import 'package:sphere_view/src/api/models/image_size.dart';
import 'package:vector_math/vector_math_64.dart';

import 'camera_model.dart';
import 'float_image.dart';
import 'stitcher_backend.dart';

/// The shared body of both Dart reprojection stitchers: warp every frame onto
/// the equirect canvas through its recorded pose, weight it with a separable
/// quadratic feather, and average.
///
/// Two subclasses differ by **one line** — which intrinsics they warp with —
/// and that is the point. [LegacyDartStitcher] uses the hard-coded 52° from the
/// old code; [ReferenceDartStitcher] uses the ones the bundle actually carries.
/// Running both on the same profile separates "the old stitcher was wrong about
/// the focal length" from "reprojection-and-average is the wrong algorithm",
/// which architecture §2 argues are two independent defects and which a single
/// control group would have left tangled together.
abstract class _ReprojectionStitcher implements StitcherBackend {
  const _ReprojectionStitcher();

  /// The intrinsics this stitcher will warp with. The single line that
  /// separates the control group from the reference.
  CameraIntrinsics intrinsicsFor(StitchJob job);

  /// Extra lines for the report's warning list.
  List<String> warningsFor(StitchJob job);

  @override
  Future<StitchOutcome> stitch(StitchJob job) async {
    final stages = <String, int>{};
    final canvas = job.canvas;
    final width = canvas.width;
    final height = canvas.height;
    final pixels = width * height;

    final accumulator = Float64List(pixels * 3);
    final weightSum = Float64List(pixels);
    final bestWeight = Float64List(pixels);
    final labels = Int32List(pixels)
      ..fillRange(0, pixels, StitchOutcome.uncovered);
    final counts = Uint8List(pixels);

    final positions = job.bundle.positions;
    final rotations = <Matrix3>[];

    final assumed = intrinsicsFor(job);

    final decodeWatch = Stopwatch();
    final warpWatch = Stopwatch();

    for (var index = 0; index < positions.length; index++) {
      final position = positions[index];

      decodeWatch.start();
      final frame = await FloatImage.loadRgb(
        position.baseShot.resolveIn(job.bundle.directory),
      );
      decodeWatch.stop();

      // Defect 1: the recorded orientation is taken at face value.
      final rotation = position.pose.deviceToWorld.asRotationMatrix();
      rotations.add(rotation);
      final camera = SyntheticCamera(
        deviceToWorld: rotation,
        intrinsics: assumed,
        // Defect 3: no distortion model, so nothing is undistorted.
        distortion: Distorter.identity,
      );

      warpWatch.start();
      _accumulate(
        camera: camera,
        frame: frame,
        canvas: canvas,
        index: index,
        accumulator: accumulator,
        weightSum: weightSum,
        bestWeight: bestWeight,
        labels: labels,
        counts: counts,
      );
      warpWatch.stop();
    }

    stages['decode'] = decodeWatch.elapsedMilliseconds;
    stages['warp+feather'] = warpWatch.elapsedMilliseconds;

    // Defect 4, the last act: divide by the accumulated weight. Where two
    // frames disagree, this *averages* the disagreement into a ghost rather
    // than cutting along a path where they agree.
    final resolve = Stopwatch()..start();
    final equirect = FloatImage(width, height, 3);
    for (var i = 0; i < pixels; i++) {
      final w = weightSum[i];
      if (w <= 0) continue;
      equirect.data[i * 3] = (accumulator[i * 3] / w).clamp(0.0, 1.0);
      equirect.data[i * 3 + 1] = (accumulator[i * 3 + 1] / w).clamp(0.0, 1.0);
      equirect.data[i * 3 + 2] = (accumulator[i * 3 + 2] / w).clamp(0.0, 1.0);
    }
    resolve.stop();
    stages['resolve'] = resolve.elapsedMilliseconds;

    final uncovered = labels.where((l) => l == StitchOutcome.uncovered).length;
    return StitchOutcome(
      equirect: equirect,
      labels: labels,
      counts: counts,
      estimatedDeviceToWorld: rotations,
      estimatedIntrinsics: assumed,
      stageMilliseconds: stages,
      warnings: [
        ...warningsFor(job),
        if (uncovered > 0)
          '$uncovered of $pixels output pixels were left uncovered; there is '
              'no pole fill in this pipeline.',
      ],
    );
  }

  /// Warps one frame onto the canvas and adds it in, weighted.
  ///
  /// Only the frame's equirect footprint is visited rather than the whole
  /// canvas. Not an optimisation for its own sake: at 40 positions a
  /// whole-canvas pass per frame is 84 million ray projections, which would put
  /// the control group's runtime above the five-minute budget the exit criteria
  /// set for the *entire* suite.
  void _accumulate({
    required SyntheticCamera camera,
    required FloatImage frame,
    required EquirectCanvas canvas,
    required int index,
    required Float64List accumulator,
    required Float64List weightSum,
    required Float64List bestWeight,
    required Int32List labels,
    required Uint8List counts,
  }) {
    final footprint = _footprint(camera, canvas);
    final rgb = List<double>.filled(3, 0);
    final frameWidth = camera.intrinsics.imageSize.width;
    final frameHeight = camera.intrinsics.imageSize.height;

    for (var y = footprint.top; y <= footprint.bottom; y++) {
      if (y < 0 || y >= canvas.height) continue;
      for (var xRaw = footprint.left; xRaw <= footprint.right; xRaw++) {
        var x = xRaw % canvas.width;
        if (x < 0) x += canvas.width;

        final direction = canvas.directionForPixel(x + 0.5, y + 0.5);
        final pixel = camera.pixelForRay(direction);
        if (pixel == null) continue;
        if (pixel.x < 0 ||
            pixel.x >= frameWidth ||
            pixel.y < 0 ||
            pixel.y >= frameHeight) {
          continue;
        }

        final weight = _featherWeight(
          pixel.x / frameWidth,
          pixel.y / frameHeight,
        );
        if (weight <= 0) continue;

        frame.sampleBilinear(pixel.x - 0.5, pixel.y - 0.5, rgb);
        final i = y * canvas.width + x;
        accumulator[i * 3] += rgb[0] * weight;
        accumulator[i * 3 + 1] += rgb[1] * weight;
        accumulator[i * 3 + 2] += rgb[2] * weight;
        weightSum[i] += weight;
        if (counts[i] < 255) counts[i]++;
        if (weight > bestWeight[i]) {
          bestWeight[i] = weight;
          labels[i] = index;
        }
      }
    }
  }

  /// The separable quadratic feather: `(1−(2u−1)²)·(1−(2v−1)²)`, one at the
  /// frame centre and zero at every edge.
  static double _featherWeight(double u, double v) {
    final a = 1 - (2 * u - 1) * (2 * u - 1);
    final b = 1 - (2 * v - 1) * (2 * v - 1);
    return a <= 0 || b <= 0 ? 0 : a * b;
  }

  /// Bounding box of a frame's equirect footprint, in canvas pixels, with
  /// `left` possibly negative so a frame straddling the ±180° meridian stays
  /// one contiguous range.
  ///
  /// A frame containing a pole gets the full width, because every yaw is inside
  /// it there and a yaw bounding box is meaningless.
  ({int left, int right, int top, int bottom}) _footprint(
    SyntheticCamera camera,
    EquirectCanvas canvas,
  ) {
    final w = camera.intrinsics.imageSize.width;
    final h = camera.intrinsics.imageSize.height;
    final axis = camera.deviceToWorld.transformed(Vector3(0, 0, -1));
    final centreYaw = math.atan2(axis.x, axis.z);

    var minPitch = double.infinity;
    var maxPitch = double.negativeInfinity;
    var minDelta = double.infinity;
    var maxDelta = double.negativeInfinity;

    const samples = 48;
    for (var i = 0; i <= samples; i++) {
      final t = i / samples;
      for (final (px, py) in [
        (t * w, 0.0),
        (t * w, h),
        (0.0, t * h),
        (w, t * h),
      ]) {
        final direction = camera.rayForPixel(px, py);
        final pitch = math.asin(direction.y.clamp(-1.0, 1.0));
        if (pitch < minPitch) minPitch = pitch;
        if (pitch > maxPitch) maxPitch = pitch;
        final delta = _wrapPi(math.atan2(direction.x, direction.z) - centreYaw);
        if (delta < minDelta) minDelta = delta;
        if (delta > maxDelta) maxDelta = delta;
      }
    }

    // A pole inside the frame breaks the yaw bounding box — every yaw is
    // present there — and also breaks the pitch box, because the extreme pitch
    // is then at the pole itself rather than anywhere on the frame's border.
    final seesZenith = camera.sees(Vector3(0, 1, 0));
    final seesNadir = camera.sees(Vector3(0, -1, 0));
    if (seesZenith) maxPitch = math.pi / 2;
    if (seesNadir) minPitch = -math.pi / 2;
    final containsPole = seesZenith || seesNadir;

    final top = canvas.height * (0.5 - maxPitch / math.pi);
    final bottom = canvas.height * (0.5 - minPitch / math.pi);
    if (containsPole) {
      return (
        left: 0,
        right: canvas.width - 1,
        top: top.floor() - 1,
        bottom: bottom.ceil() + 1,
      );
    }

    // x = W(½ − yaw/2π), so a *larger* yaw is a *smaller* x: the deltas swap.
    final centreX = canvas.width * (0.5 - centreYaw / (2 * math.pi));
    final left = centreX - canvas.width * maxDelta / (2 * math.pi);
    final right = centreX - canvas.width * minDelta / (2 * math.pi);
    return (
      left: left.floor() - 1,
      right: right.ceil() + 1,
      top: top.floor() - 1,
      bottom: bottom.ceil() + 1,
    );
  }

  static double _wrapPi(double angle) {
    var a = (angle + math.pi) % (2 * math.pi);
    if (a < 0) a += 2 * math.pi;
    return a - math.pi;
  }
}

/// The stitcher this project is replacing, kept alive on purpose as the
/// harness's control group.
///
/// Architecture §2 lists five defects, and this reproduces four of them
/// faithfully:
///
/// 1. **The IMU pose is trusted as a measurement.** No feature matching, no
///    bundle adjustment; the recorded quaternion is used as-is, so the frames
///    land wherever a ±2–5° attitude estimate puts them.
/// 2. **The focal length is a hard-coded guess** — [legacyHfovDegrees], 52°,
///    from the old `capture_config.dart`. This is the defect that makes the
///    control group fail even on `pristine`, where the pose is exact and the
///    lens is perfect: a wrong focal is a wrong angular scale, so frames land
///    correct at the centre and progressively wrong towards the edges, and the
///    panorama does not close.
/// 3. **No lens distortion model at all**, so the frame edges cannot align with
///    their neighbours even when the pose is right.
/// 5. **No exposure compensation**, so per-frame gain drift becomes banding.
///
/// Defect 4 — averaging misaligned pixels instead of cutting along a path where
/// they agree — is the separable quadratic feather in [_featherWeight].
///
/// The one thing deliberately **not** ported is the old yaw origin. Math §3
/// notes the previous code placed yaw +π at `x = 0` rather than the normative
/// yaw 0 at the image centre. Reproducing that would shift the output by half a
/// canvas and drown every interesting failure in one uninteresting one; the
/// control group is more useful failing for the reasons the architecture
/// argues about than for a re-centring the document already calls
/// algebraically equivalent.
class LegacyDartStitcher extends _ReprojectionStitcher {
  /// Creates the control-group stitcher.
  const LegacyDartStitcher();

  /// The hard-coded horizontal FOV from the old `capture_config.dart:57`.
  /// Real main-camera HFOV in portrait ranges ~46°-56° across the fleet, so
  /// this is wrong on nearly every device — including, by construction, the
  /// synthetic one.
  static const double legacyHfovDegrees = 52.0;

  @override
  String get name => 'legacy-dart';

  @override
  String get description =>
      'the pre-Phase-02 Dart reprojection stitcher: IMU-only poses, a '
      'hard-coded ${legacyHfovDegrees.toStringAsFixed(0)}\u00b0 HFOV, no '
      'undistortion, no gain compensation, quadratic feather averaging. '
      'Expected to FAIL — it is the harness\'s control group.';

  @override
  CameraIntrinsics intrinsicsFor(StitchJob job) {
    // Defect 2: the intrinsics the bundle actually carries are ignored in
    // favour of a constant compiled into the app.
    final size = job.bundle.intrinsics.imageSize;
    return CameraIntrinsics.fromHorizontalFov(
      hfovRadians: legacyHfovDegrees * math.pi / 180,
      imageSize: ImageSize(size.width, size.height),
    );
  }

  @override
  List<String> warningsFor(StitchJob job) => [
    'Poses were used exactly as recorded; no bundle adjustment ran.',
    'Focal length was assumed to be ${legacyHfovDegrees.toStringAsFixed(0)}\u00b0 '
        'HFOV rather than read from the bundle.',
    'No lens undistortion and no exposure compensation were applied.',
  ];
}

/// The same naive reprojection, but honest about the camera.
///
/// It reads the intrinsics out of the bundle instead of assuming them, and is
/// otherwise identical to [LegacyDartStitcher] — still IMU-only, still
/// averaging, still no undistortion or gain compensation. It exists for two
/// jobs. It is the geometric reference `test/synthetic_sanity_test.dart` needs:
/// that test is asking whether the mapping conventions are right, and a
/// stitcher with a deliberate 4% scale error would drown a 2 px assertion in
/// its own defect. And on `pristine` it answers the question the phase doc says
/// that profile exists to ask — with exact poses, exact intrinsics and no
/// noise, is the output near-pixel-perfect? If this backend cannot manage that,
/// the geometry or the conventions are wrong and no other number matters.
class ReferenceDartStitcher extends _ReprojectionStitcher {
  /// Creates the reference stitcher.
  const ReferenceDartStitcher();

  @override
  String get name => 'reference-dart';

  @override
  String get description =>
      'naive reprojection with the bundle\'s real intrinsics: the geometric '
      'reference. Still IMU-only and still averaging, so it is not a good '
      'stitcher — only a correctly-calibrated one.';

  @override
  CameraIntrinsics intrinsicsFor(StitchJob job) => job.bundle.intrinsics;

  @override
  List<String> warningsFor(StitchJob job) => const [
    'Poses were used exactly as recorded; no bundle adjustment ran.',
    'No lens undistortion and no exposure compensation were applied.',
  ];
}
