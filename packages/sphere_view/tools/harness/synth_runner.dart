import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:sphere_view/src/api/models/camera_intrinsics.dart';
import 'package:sphere_view/src/api/models/capture_bundle.dart';
import 'package:sphere_view/src/api/models/device_pose.dart';
import 'package:sphere_view/src/api/models/image_size.dart';
import 'package:sphere_view/src/metadata/panorama_metadata.dart';
import 'package:sphere_view/src/plan/plan_builder.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart';

import 'camera_model.dart';
import 'float_image.dart';
import 'frame_renderer.dart';
import 'ground_truth.dart';
import 'profiles.dart';
import 'rng.dart';
import 'scene.dart';

/// Turns a [SynthProfile] into a `CaptureBundle` on disk, plus the separate
/// ground truth that scores it.
///
/// The whole rig hangs off one rule: **nothing the renderer knows may reach
/// `bundle.json`.** The true rotation, the true focal, the true lens
/// coefficients, the gain that was actually applied — each is used to render
/// and then written to `ground_truth.json`, and what lands in the bundle is the
/// deliberately worse version a device would have recorded. Every place the two
/// diverge is marked below, because a single slip there would turn the harness
/// into a machine for confirming itself.
class SynthRunner {
  /// Creates a runner for [profile].
  SynthRunner({
    required this.profile,
    this.frameSize = const ImageSize(480, 640),
    this.horizontalFovDegrees = 50.0,
    this.groundTruthWidth = 2048,
    this.groundTruthOverride,
    this.onProgress,
  });

  /// Which capture set to build.
  final SynthProfile profile;

  /// Rendered frame size. Portrait, because capture is portrait-locked
  /// (Phase 09 §4) and the larger VFOV is what keeps the ring count down.
  final ImageSize frameSize;

  /// True horizontal field of view. Mid-range for the tablet fleet R2
  /// measured — deliberately *not* the 52° the old code hard-coded, so a
  /// stitcher that still assumes 52° is caught rather than flattered.
  final double horizontalFovDegrees;

  /// Ground-truth equirect width; height is half. ~2048 keeps a committed
  /// fixture small enough to live in the repo.
  final int groundTruthWidth;

  /// A ground-truth equirect to render from instead of the procedural room.
  ///
  /// Exists for `test/synthetic_sanity_test.dart`, which needs a scene made of
  /// markers at hand-computed pixel positions rather than of walls. The depth
  /// and EV maps still come from the room, which is harmless because the only
  /// profile the test uses has no parallax and no dynamic range.
  final FloatImage? groundTruthOverride;

  /// Called with `(done, total)` after each position, for the CLI's progress
  /// line.
  final void Function(int done, int total)? onProgress;

  /// Seconds between positions — 40 targets inside S7's 90 s budget.
  static const double _secondsPerPosition = 2.2;

  /// Seconds between the exposures of one bracket, matching the ~600 ms burst
  /// budget R3 could not find a measured number for.
  static const double _secondsPerBracketShot = 0.06;

  /// Renders the whole capture set into [directory].
  Future<CaptureBundle> run(Directory directory) async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    await directory.create(recursive: true);

    final canvas = EquirectCanvas.fromWidth(groundTruthWidth);
    final sceneSeed = Rng.seedFromString('scene:${profile.sceneStyle.name}');
    final scene = RoomScene.forStyle(
      profile.sceneStyle,
      nearestSurfaceMetres: profile.nearestSurfaceMetres,
      dynamicRangeScale: profile.dynamicRangeScale,
      seed: sceneSeed,
    );
    var maps = scene.render(canvas);
    final override = groundTruthOverride;
    if (override != null) {
      if (override.width != canvas.width || override.height != canvas.height) {
        throw ArgumentError(
          'groundTruthOverride is ${override.width}x${override.height} but the '
          'canvas is ${canvas.width}x${canvas.height}',
        );
      }
      maps = (image: override, depth: maps.depth, ev: maps.ev);
    }
    final hasEv = maps.ev.data.any((v) => v != 0);

    // The truth, and the lie. `trueIntrinsics` renders; `recordedIntrinsics`
    // goes in the bundle and is what the stitcher gets to believe.
    final trueIntrinsics = CameraIntrinsics.fromHorizontalFov(
      hfovRadians: horizontalFovDegrees * math.pi / 180,
      imageSize: frameSize,
      distortion: profile.distortion.isIdentity
          ? null
          : profile.distortion.toModel(),
    );
    final focalScale = 1 + profile.focalErrorFraction;
    final recordedIntrinsics = CameraIntrinsics(
      fx: trueIntrinsics.fx * focalScale,
      fy: trueIntrinsics.fy * focalScale,
      cx: trueIntrinsics.cx,
      cy: trueIntrinsics.cy,
      imageSize: frameSize,
      source: IntrinsicsSource.derivedFromPhysics,
      // No distortion model, on purpose. R2 found `LENS_DISTORTION` null even
      // on Pixel hardware and iPad's calibration path unavailable on most of
      // the fleet, so the common case is a stitcher that has to cope with a
      // lens it was told nothing about.
    );

    // How a sensor mounted `sensorOrientationDegrees` off the screen turns the
    // frame, and the inverse the stitcher needs.
    //
    // The plan, the poses and the guidance live in the *device* frame, so the
    // plan below is still built from `recordedIntrinsics` as delivered. The
    // frames written to disk and the intrinsics recorded beside them are turned
    // into the *capture* frame, which is what a device actually writes.
    final captureToDeviceTurns = SphericalConventions.captureToDeviceQuarterTurns(
      landscapeCapture: profile.sensorOrientationDegrees % 180 == 90,
      sensorOrientationDegrees: profile.sensorOrientationDegrees,
    );
    final deviceToCaptureTurns = SphericalConventions.deviceToCaptureQuarterTurns(
      landscapeCapture: profile.sensorOrientationDegrees % 180 == 90,
      sensorOrientationDegrees: profile.sensorOrientationDegrees,
    );
    // `rotatedQuarterTurn(clockwise:)` takes capture -> device, so the recorded
    // intrinsics are the device-frame ones turned the other way.
    final captureIntrinsics = captureToDeviceTurns == 0
        ? recordedIntrinsics
        : recordedIntrinsics.rotatedQuarterTurn(
            clockwise: captureToDeviceTurns == 3,
          );

    // The plan is built from the *recorded* intrinsics, because that is all a
    // device has when it plans. A 3% focal error therefore also mis-sizes the
    // plan slightly, which is correct and is part of what the harness measures.
    final plan = const PlanBuilder().buildPlan(
      intrinsics: recordedIntrinsics,
      overlapFraction: profile.overlapFraction,
      captureNadir: profile.captureNadir,
      enforceCoverage: profile.enforceCoverage,
    );

    final renderer = FrameRenderer(
      profile: profile,
      canvas: canvas,
      groundTruth: maps.image,
      depth: profile.needsDepth ? maps.depth : null,
      ev: hasEv ? maps.ev : null,
    );

    final shot = (profile.completionFraction * plan.length).round();
    final count = shot.clamp(1, plan.length);
    final positions = <CapturedPosition>[];
    final truth = <GroundTruthPosition>[];
    final baseTimestampUs = DateTime.utc(2026, 8, 6, 11, 42, 19)
        .microsecondsSinceEpoch;

    final driftAxis = Vector3(0.21, 0.94, -0.27).normalized();

    for (var i = 0; i < count; i++) {
      final target = plan.targets[i];
      final rng = Rng(Rng.hashSeed(Rng.seedFromString(profile.name), i, 0));
      final elapsed = i * _secondsPerPosition;

      final trueRotation = SphericalConventions.aimingDeviceToWorld(
        target.yaw,
        target.pitch,
      );

      // Steps 7 and 8's driver: how fast the tablet was still turning when the
      // shutter fired. Mostly about the vertical axis, because that is how a
      // person pans, with enough jitter that the blur direction is not
      // identical on every frame.
      final speed =
          profile.angularSpeedRadPerSec * (0.6 + 0.8 * rng.next());
      final axis = Vector3(
        rng.gaussian() * 0.25,
        1.0,
        rng.gaussian() * 0.25,
      ).normalized();
      final angularVelocity = axis * speed;

      // Step 11: handheld, the pupil sits a radius in front of the pivot, so it
      // traces a circle as the user turns — architecture §3's `r`.
      final forward = SphericalConventions.directionOf(target.yaw, target.pitch);
      final horizontal = Vector3(forward.x, 0, forward.z);
      final lensOffset = horizontal.length < 1e-9
          ? Vector3.zero()
          : (horizontal.normalized() * profile.lensOffsetMetres);

      // Step 4: the AE lock that is not quite a lock.
      final gain = math
          .pow(2.0, rng.gaussian() * profile.gainRmsStops)
          .toDouble();

      final trueCamera = SyntheticCamera(
        deviceToWorld: trueRotation,
        intrinsics: trueIntrinsics,
        distortion: profile.distortion,
      );

      final shots = <ExposureShot>[];
      double? sharpness;
      final biases = profile.exposure.evBiases;
      for (var b = 0; b < biases.length; b++) {
        final bias = biases[b];
        final frame = renderer.render(
          camera: trueCamera,
          // The metering pre-sweep's choice, plus this shot's own bracket bias.
          // The bundle records only the bias, because the bias is what the app
          // asked the camera for and the metered exposure is the locked reference
          // it asked for it *relative to* — which is exactly what
          // `ExposureShot.evBias` means.
          evBias: profile.meteredEvBias + bias,
          gain: gain,
          angularVelocity: angularVelocity,
          lensOffset: lensOffset,
          rng: Rng(Rng.hashSeed(Rng.seedFromString(profile.name), i, b + 1)),
        );
        if (bias == 0.0) sharpness = _laplacianVariance(frame);

        // JPEG, not PNG, and at the top quality setting.
        //
        // §1 of the phase doc requires a synthetic bundle to be
        // "indistinguishable in structure from one a real device produces", and
        // a real device writes JPEG. It is not cosmetic: R1 settled the shipped
        // OpenCV module list as JPEG-only — no PNG, which also keeps zlib out —
        // so a PNG frame is one the native pipeline physically cannot decode.
        // Writing PNG here would mean the harness exercised a code path the
        // device never runs, which is the one thing PHASE_02 §2 says it must
        // not do.
        //
        // Quality 100 keeps `pristine` honest. The geometric criteria (S1, S2,
        // focal) are computed from recovered rotations and are untouched by
        // compression either way; this only matters to S6, and at q=100 the
        // penalty is far below the 0.97 SSIM target.
        final name = 'pos_${i.toString().padLeft(3, '0')}_ev${_evTag(bias)}.jpg';
        // Into the capture frame, the way the sensor delivers it. The renderer
        // works in the device frame throughout — that is what keeps the geometry
        // one frame and readable — so the turn is applied here, at the one place
        // pixels leave the rig, and the intrinsics recorded in the bundle are
        // turned to match.
        final written = deviceToCaptureTurns == 0
            ? frame.toRgb8()
            : img.copyRotate(
                frame.toRgb8(),
                angle: 90 * deviceToCaptureTurns,
              );
        await File(
          '${directory.path}${Platform.pathSeparator}$name',
        ).writeAsBytes(img.encodeJpg(written, quality: 100));

        final timestampUs =
            baseTimestampUs +
            ((elapsed + b * _secondsPerBracketShot) * 1e6).round();
        shots.add(
          ExposureShot(
            filePath: name,
            evBias: bias,
            timestampUs: timestampUs,
            // Actual, not requested: the metering is in here, because a camera
            // reports the exposure it used. Phase 05 §4 normalises on this rather
            // than on `evBias`, so the two must not be the same number.
            exposureTimeNs:
                (profile.exposureSeconds *
                        math.pow(2.0, profile.meteredEvBias + bias) *
                        1e9)
                    .round(),
            iso: 400,
          ),
        );
      }

      // Step 9: the pose the *device* thinks it had. `R_true · δR` — the error
      // is in the device frame, where a gyro's is — plus a bias drift that
      // grows with elapsed session time. The drift matters more than its size
      // suggests: per-frame noise averages out across a bundle adjustment,
      // while a drift is a consistent story that BA can be led to believe.
      final noiseAngle =
          rng.gaussian() * profile.poseErrorRmsDegrees * math.pi / 180;
      final noiseAxisValues = rng.unitVector();
      final recorded =
          FrameRenderer.rotationAbout(
            driftAxis,
            elapsed /
                60 *
                profile.poseDriftDegreesPerMinute *
                math.pi /
                180,
          ) *
          trueRotation *
          FrameRenderer.rotationAbout(
            Vector3(
              noiseAxisValues[0],
              noiseAxisValues[1],
              noiseAxisValues[2],
            ),
            noiseAngle,
          );

      positions.add(
        CapturedPosition(
          targetIndex: target.index,
          pose: DevicePose(
            deviceToWorld: Quaternion.fromRotation(recorded as Matrix3)
              ..normalize(),
            // Gravity is measured, not derived from the drifting attitude —
            // which is exactly why Math §7 can level against it.
            gravityWorld: Vector3(0, 1, 0),
            timestampUs: baseTimestampUs + (elapsed * 1e6).round(),
            angularSpeedRadPerSec: speed,
          ),
          shots: shots,
          sharpness: sharpness ?? 0,
          steadinessRadPerSec: speed,
        ),
      );

      truth.add(
        GroundTruthPosition(
          targetIndex: target.index,
          trueDeviceToWorld: trueRotation,
          trueGain: gain,
          lensOffsetMetres: lensOffset,
          angularVelocityRadPerSec: angularVelocity,
        ),
      );

      onProgress?.call(i + 1, count);
    }

    await _writeMaps(directory, maps, hasEv);

    final bundle = CaptureBundle(
      sessionId: 'synth-${profile.name}',
      directory: directory,
      plan: plan,
      intrinsics: captureIntrinsics,
      captureQuarterTurns: deviceToCaptureTurns,
      positions: positions,
      // No heading: the rig has no magnetometer and no plan, and Phase 11 §2's
      // third option is to omit rather than invent. A synthetic panorama that
      // claimed a bearing would be the one number in the corpus that was made
      // up.
      heading: PanoramaHeading.unknown,
      deviceInfo: {
        'source': 'tools/synth',
        'profile': profile.name,
        'purpose': profile.purpose,
        'frame_format': 'jpg',
        'note':
            'Synthetic. Ground truth is in ${GroundTruth.fileName}, which the '
            'stitcher must not read.',
      },
    );
    await bundle.save();

    await GroundTruth(
      profile: profile.name,
      sceneStyle: profile.sceneStyle.name,
      nearestSurfaceMetres: profile.nearestSurfaceMetres,
      sceneSeed: sceneSeed,
      canvasWidth: canvas.width,
      canvasHeight: canvas.height,
      trueIntrinsics: trueIntrinsics,
      positions: truth,
      recordedFocalScale: focalScale,
      depthFileName: profile.needsDepth ? 'ground_truth_depth.png' : null,
      evFileName: hasEv ? 'ground_truth_ev.png' : null,
    ).save(directory);

    return bundle;
  }

  Future<void> _writeMaps(
    Directory directory,
    ({FloatImage image, FloatImage depth, FloatImage ev}) maps,
    bool hasEv,
  ) async {
    final separator = Platform.pathSeparator;
    await File(
      '${directory.path}$separator${GroundTruth.imageFileName}',
    ).writeAsBytes(img.encodePng(maps.image.toRgb8()));
    if (profile.needsDepth) {
      await File(
        '${directory.path}${separator}ground_truth_depth.png',
      ).writeAsBytes(
        img.encodePng(
          maps.depth.toScalar16(scale: GroundTruth.depthScaleMetres),
        ),
      );
    }
    if (hasEv) {
      await File(
        '${directory.path}${separator}ground_truth_ev.png',
      ).writeAsBytes(
        img.encodePng(
          maps.ev.toScalar16(
            scale: 2 * GroundTruth.evScaleStops,
            bias: -GroundTruth.evScaleStops,
          ),
        ),
      );
    }
  }

  /// Laplacian variance of the frame's luma — the same sharpness number the
  /// capture-side gate uses, computed here so `motion_blur` records a genuinely
  /// soft frame instead of a made-up one.
  static double _laplacianVariance(FloatImage frame) {
    var sum = 0.0;
    var sumSquares = 0.0;
    var n = 0;
    double luma(int x, int y) {
      final o = frame.offset(x, y);
      return 0.299 * frame.data[o] +
          0.587 * frame.data[o + 1] +
          0.114 * frame.data[o + 2];
    }

    for (var y = 1; y < frame.height - 1; y++) {
      for (var x = 1; x < frame.width - 1; x++) {
        final v =
            (luma(x - 1, y) +
                    luma(x + 1, y) +
                    luma(x, y - 1) +
                    luma(x, y + 1) -
                    4 * luma(x, y)) *
                255;
        sum += v;
        sumSquares += v * v;
        n++;
      }
    }
    final mean = sum / n;
    return sumSquares / n - mean * mean;
  }

  static String _evTag(double bias) {
    if (bias == 0) return '0';
    final text = bias.abs() == bias.abs().roundToDouble()
        ? bias.abs().round().toString()
        : bias.abs().toString();
    return bias > 0 ? '+$text' : '-$text';
  }
}
