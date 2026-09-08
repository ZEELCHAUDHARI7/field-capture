import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';

/// Guards the two properties every later phase silently relies on: rescaling
/// preserves field of view, and FOV ↔ focal is an exact round-trip.
///
/// They matter because registration runs at ~0.6 MP while compositing runs at
/// up to 8192 wide, both from one calibration. If `scaledTo` were even slightly
/// lossy, the focal used to match features would differ from the focal used to
/// warp them, and the panorama would fail to close — the same class of failure
/// as the old hard-coded 52° HFOV, just harder to see.
void main() {
  const fullSize = ImageSize(4032, 3024);

  /// All five coefficients distinct and non-zero, so a reorder is visible.
  const sampleBrownConrady = BrownConradyDistortion(
    k1: -0.21,
    k2: 0.07,
    p1: 0.0012,
    p2: -0.0023,
    k3: -0.0098,
  );

  CameraIntrinsics nominal({DistortionModel? distortion}) => CameraIntrinsics(
    fx: 2975.0,
    fy: 2975.0,
    cx: 2016.0,
    cy: 1512.0,
    imageSize: fullSize,
    source: IntrinsicsSource.derivedFromPhysics,
    distortion: distortion,
  );

  group('scaledTo', () {
    test('preserves horizontal and vertical FOV exactly', () {
      final k = nominal();
      for (final target in const [
        ImageSize(2016, 1512),
        ImageSize(1008, 756),
        ImageSize(896, 672), // ~0.6 MP registration scale
        ImageSize(8064, 6048),
      ]) {
        final scaled = k.scaledTo(target);
        expect(
          scaled.hfovRadians,
          closeTo(k.hfovRadians, 1e-12),
          reason: 'hfov at $target',
        );
        expect(
          scaled.vfovRadians,
          closeTo(k.vfovRadians, 1e-12),
          reason: 'vfov at $target',
        );
      }
    });

    test('scales focal and principal point by the same factor', () {
      final scaled = nominal().scaledTo(const ImageSize(2016, 1512));
      expect(scaled.fx, closeTo(1487.5, 1e-9));
      expect(scaled.fy, closeTo(1487.5, 1e-9));
      expect(scaled.cx, closeTo(1008.0, 1e-9));
      expect(scaled.cy, closeTo(756.0, 1e-9));
      expect(scaled.imageSize, const ImageSize(2016, 1512));
    });

    test('is the identity when the size is unchanged', () {
      final k = nominal();
      expect(k.scaledTo(fullSize), k);
    });

    test('composes: scaling twice equals scaling once', () {
      final k = nominal();
      final twoSteps = k
          .scaledTo(const ImageSize(2016, 1512))
          .scaledTo(const ImageSize(1008, 756));
      final oneStep = k.scaledTo(const ImageSize(1008, 756));
      expect(twoSteps.fx, closeTo(oneStep.fx, 1e-9));
      expect(twoSteps.fy, closeTo(oneStep.fy, 1e-9));
      expect(twoSteps.cx, closeTo(oneStep.cx, 1e-9));
      expect(twoSteps.cy, closeTo(oneStep.cy, 1e-9));
    });

    test('carries provenance and Brown-Conrady coefficients through', () {
      // Brown-Conrady operates on normalised coordinates, so it is
      // scale-invariant and must survive untouched.
      const distortion = BrownConradyDistortion(
        k1: -0.21,
        k2: 0.07,
        p1: 0.001,
        p2: -0.002,
        k3: -0.01,
      );
      final scaled = nominal(
        distortion: distortion,
      ).scaledTo(const ImageSize(1008, 756));
      expect(scaled.source, IntrinsicsSource.derivedFromPhysics);
      expect(scaled.distortion, distortion);
    });

    test('moves a lookup table centre with the image', () {
      // The LUT centre is in pixels, so unlike Brown-Conrady it is not
      // scale-invariant. Leaving it unscaled would put the distortion centre
      // in the wrong place at registration scale.
      const lut = LookupTableDistortion(
        magnifications: [1.0, 1.01, 1.04, 1.09],
        centerX: 2016.0,
        centerY: 1512.0,
      );
      final scaled = nominal(
        distortion: lut,
      ).scaledTo(const ImageSize(1008, 756));
      final scaledLut = scaled.distortion! as LookupTableDistortion;
      expect(scaledLut.centerX, closeTo(504.0, 1e-9));
      expect(scaledLut.centerY, closeTo(378.0, 1e-9));
      expect(scaledLut.magnifications, lut.magnifications);
    });
  });

  group('FOV ↔ focal', () {
    test('round-trips through fromHorizontalFov', () {
      for (final degrees in [46.0, 50.0, 52.0, 56.0, 69.0]) {
        final radians = degrees * math.pi / 180;
        final k = CameraIntrinsics.fromHorizontalFov(
          hfovRadians: radians,
          imageSize: const ImageSize(3024, 4032),
        );
        expect(k.hfovRadians, closeTo(radians, 1e-12), reason: '$degrees°');
        expect(k.hfovDegrees, closeTo(degrees, 1e-9));
      }
    });

    test('fromHorizontalFov centres the principal point and squares pixels', () {
      final k = CameraIntrinsics.fromHorizontalFov(
        hfovRadians: 50 * math.pi / 180,
        imageSize: const ImageSize(3024, 4032),
      );
      expect(k.fx, k.fy);
      expect(k.cx, closeTo(1512.0, 1e-9));
      expect(k.cy, closeTo(2016.0, 1e-9));
      expect(k.source, IntrinsicsSource.derivedFromPhysics);
    });

    test('portrait VFOV exceeds HFOV, which is why capture is portrait', () {
      // Phase 09 §4: portrait gives the larger vertical FOV, so Δpitch is
      // larger and the plan needs fewer rings.
      final k = CameraIntrinsics.fromHorizontalFov(
        hfovRadians: 50 * math.pi / 180,
        imageSize: const ImageSize(3024, 4032),
      );
      expect(k.vfovDegrees, greaterThan(k.hfovDegrees));
      // fx = 1512/tan(25°) = 1512/0.4663077 = 3242.44
      // vfov = 2·atan(2016/3242.44) = 2·atan(0.621757) = 2·31.871° = 63.742°
      expect(k.vfovDegrees, closeTo(63.742, 0.005));
    });

    test('the R2 worked example reproduces exactly', () {
      // Math §4.1: focal 4.25 mm, sensor 5.76×4.32 mm, array 4032×3024, full
      // crop, 1920×1080 output.
      //   pixelPitch = 5.76 / 4032 = 0.00142857 mm/px
      //   fx_sensor  = 4.25 / 0.00142857 = 2975.0
      const pixelPitch = 5.76 / 4032;
      final fxSensor = 4.25 / pixelPitch;
      expect(fxSensor, closeTo(2975.0, 1e-6));

      // The 16:9 stream letterboxes the 4:3 crop:
      //   streamSourceRect = (0, 378, 4032, 2268), scale = 1920/4032 = 0.47619
      const scale = 1920 / 4032;
      expect(scale, closeTo(0.47619, 1e-5));
      expect(fxSensor * scale, closeTo(1416.7, 0.05));

      // cx/cy landing exactly at image centre is the sanity check for a
      // centred crop.
      final k = CameraIntrinsics(
        fx: fxSensor,
        fy: fxSensor,
        cx: 2016.0,
        cy: 1512.0,
        imageSize: const ImageSize(4032, 3024),
        source: IntrinsicsSource.derivedFromPhysics,
      );
      // The crop is a 16:9 window on the 4:3 array, so this is not a pure
      // scale — model it as cropping to (0, 378, 4032, 2268) and then scaling.
      final cropped = CameraIntrinsics(
        fx: k.fx,
        fy: k.fy,
        cx: k.cx,
        cy: k.cy - 378,
        imageSize: const ImageSize(4032, 2268),
        source: k.source,
      ).scaledTo(const ImageSize(1920, 1080));
      expect(cropped.fx, closeTo(1416.7, 0.05));
      expect(cropped.fy, closeTo(1416.7, 0.05));
      expect(cropped.cx, closeTo(960.0, 1e-6));
      expect(cropped.cy, closeTo(540.0, 1e-6));
    });
  });

  group('Android LENS_DISTORTION reorder', () {
    test('is {kappa1, kappa2, kappa4, kappa5, kappa3}, a pure reorder', () {
      // R2, verified against AOSP: Android orders [R,R,R,T,T], OpenCV orders
      // [R,R,T,T,R]. No value transform.
      final bc = BrownConradyDistortion.fromAndroidLensDistortion(const [
        0.1, // kappa1 → k1
        0.2, // kappa2 → k2
        0.3, // kappa3 → k3
        0.4, // kappa4 → p1
        0.5, // kappa5 → p2
      ]);
      expect(bc.openCvCoefficients, [0.1, 0.2, 0.4, 0.5, 0.3]);
    });

    test('rejects an array that is not five elements', () {
      expect(
        () => BrownConradyDistortion.fromAndroidLensDistortion(const [1, 2, 3]),
        throwsArgumentError,
      );
    });
  });

  group('rotatedQuarterTurn', () {
    // Phase 08 needs this because the capture stream and the device are not
    // always in the same frame: iOS delivers photos in the sensor's landscape
    // orientation while the tablet is portrait-locked, and an Android camera
    // can be mounted 90° from the display. Planning from unrotated intrinsics
    // swaps the horizontal and vertical fields of view — and still returns a
    // plausible-looking ring count, which is what makes it dangerous.
    test('swaps the fields of view, which is the point', () {
      final landscape = CameraIntrinsics.fromHorizontalFov(
        hfovRadians: 69 * math.pi / 180,
        imageSize: const ImageSize(4032, 3024),
      );
      final portrait = landscape.rotatedQuarterTurn();
      expect(portrait.hfovDegrees, closeTo(landscape.vfovDegrees, 1e-9));
      expect(portrait.vfovDegrees, closeTo(landscape.hfovDegrees, 1e-9));
      expect(portrait.imageSize, const ImageSize(3024, 4032));
    });

    test('carries the principal point to where the pixel actually goes', () {
      // Clockwise, a pixel at (x, y) lands at (H − y, x): the old top-left
      // corner becomes the new top-right.
      final k = nominal().copyWith(cx: 2000, cy: 1400);
      final turned = k.rotatedQuarterTurn();
      expect(turned.cx, 3024 - 1400);
      expect(turned.cy, 2000);
      final back = k.rotatedQuarterTurn(clockwise: false);
      expect(back.cx, 1400);
      expect(back.cy, 4032 - 2000);
    });

    test('four turns are the identity, in both directions', () {
      for (final clockwise in [true, false]) {
        var k = nominal(distortion: sampleBrownConrady).copyWith(
          cx: 2000,
          cy: 1400,
        );
        for (var i = 0; i < 4; i++) {
          k = k.rotatedQuarterTurn(clockwise: clockwise);
        }
        expect(k, nominal(distortion: sampleBrownConrady).copyWith(
          cx: 2000,
          cy: 1400,
        ));
      }
    });

    test('tangential distortion turns with the frame; radial does not', () {
      // Substituting (x, y) → (−y, x) into Brown–Conrady gives
      // (p1, p2) → (p2, −p1) clockwise. The radial terms depend only on r, so
      // they are untouched — and getting this backwards would undistort toward
      // the wrong corner.
      final turned =
          nominal(distortion: sampleBrownConrady).rotatedQuarterTurn().distortion!
              as BrownConradyDistortion;
      expect(turned.k1, sampleBrownConrady.k1);
      expect(turned.k2, sampleBrownConrady.k2);
      expect(turned.k3, sampleBrownConrady.k3);
      expect(turned.p1, sampleBrownConrady.p2);
      expect(turned.p2, -sampleBrownConrady.p1);
    });

    test('a lookup table centre moves with the pixels it indexes', () {
      const table = LookupTableDistortion(
        magnifications: [1.0, 1.01, 1.04],
        centerX: 2000,
        centerY: 1400,
      );
      final turned =
          nominal(distortion: table).rotatedQuarterTurn().distortion!
              as LookupTableDistortion;
      expect(turned.centerX, 3024 - 1400);
      expect(turned.centerY, 2000);
      expect(turned.magnifications, table.magnifications);
    });

    test('no distortion stays no distortion, never zero coefficients', () {
      expect(nominal().rotatedQuarterTurn().distortion, isNull);
    });
  });

  group('ImageSize', () {
    test('aspect ratio and area', () {
      const s = ImageSize(4032, 3024);
      expect(s.aspectRatio, closeTo(4 / 3, 1e-12));
      expect(s.area, 4032.0 * 3024.0);
      expect(ImageSize.fromInts(1920, 1080).aspectRatio, closeTo(16 / 9, 1e-12));
    });

    test('a zero height does not divide by zero', () {
      expect(const ImageSize(100, 0).aspectRatio, 0);
    });
  });
}
