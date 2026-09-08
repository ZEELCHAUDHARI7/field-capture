import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:sphere_view/src/camera/messages.g.dart';

/// The Phase 06 §6 unit test: "the intrinsics fallback chain picks the right
/// branch for each synthetic capability set".
///
/// This is the test the whole resolver design exists to make possible. R2 left
/// four questions open that only a device can answer — whether
/// `cameraIntrinsicMatrix` arrives on an iPad, the real null-rate of
/// `LENS_INTRINSIC_CALIBRATION`, and so on — and the honest response to "we
/// cannot know which branch the fleet takes" is to make *every* branch
/// exercisable without a device. The capability sets below include ones our
/// fleet will certainly never produce, because the point is that the chain is
/// correct rather than that it is lucky.
void main() {
  // R2's worked example, which Math §4.1 reproduces and `intrinsics_test.dart`
  // already checks the arithmetic of: focal 4.25 mm, sensor 5.76×4.32 mm,
  // array 4032×3024.
  PlatformSize size(int w, int h) => PlatformSize(width: w, height: h);
  PlatformRect rect(int l, int t, int w, int h) =>
      PlatformRect(left: l, top: t, width: w, height: h);

  AndroidIntrinsicFacts androidFacts({
    double? focalLengthMm = 4.25,
    double? physicalWidth = 5.76,
    double? physicalHeight = 4.32,
    PlatformSize? pixelArray,
    PlatformRect? preCorrection,
    PlatformRect? active,
    PlatformRect? crop,
    List<double>? calibration,
    List<double>? distortion,
    bool distortionOffRequested = true,
    bool supportsNonOff = false,
    bool arraysDiffer = false,
    double? focal35mm,
  }) => AndroidIntrinsicFacts(
    focalLengthMm: focalLengthMm,
    sensorPhysicalWidthMm: physicalWidth,
    sensorPhysicalHeightMm: physicalHeight,
    pixelArraySize: pixelArray ?? size(4032, 3024),
    preCorrectionActiveArray: preCorrection ?? rect(0, 0, 4032, 3024),
    activeArray: active ?? rect(0, 0, 4032, 3024),
    cropRegion: crop,
    lensIntrinsicCalibration: calibration,
    lensDistortion: distortion,
    distortionCorrectionModeOffRequested: distortionOffRequested,
    distortionCorrectionSupportsNonOff: supportsNonOff,
    activeArraysDiffer: arraysDiffer,
    focalLengthIn35mmFilm: focal35mm,
  );

  IosIntrinsicFacts iosFacts({
    List<double>? calibrationMatrix,
    PlatformSize? calibrationReference,
    List<double>? connectionMatrix,
    PlatformSize? connectionReference,
    bool connectionSupported = false,
    bool connectionArrived = false,
    double fov = 60.0,
    List<double>? lut,
    double? lutCenterX,
    double? lutCenterY,
    bool gdcDisabled = true,
    bool contentAwareDisabled = true,
    bool calibrationSupported = false,
    bool virtualDevice = false,
    double? focal35mm,
  }) => IosIntrinsicFacts(
    calibrationIntrinsicMatrix: calibrationMatrix,
    calibrationReferenceSize: calibrationReference,
    connectionIntrinsicMatrix: connectionMatrix,
    connectionIntrinsicReferenceSize: connectionReference,
    connectionIntrinsicDeliverySupported: connectionSupported,
    connectionIntrinsicAttachmentArrived: connectionArrived,
    videoFieldOfViewDegrees: fov,
    lensDistortionLookupTable: lut,
    lensDistortionCenterX: lutCenterX,
    lensDistortionCenterY: lutCenterY,
    geometricDistortionCorrectionDisabled: gdcDisabled,
    contentAwareDistortionCorrectionDisabled: contentAwareDisabled,
    calibrationDataDeliverySupported: calibrationSupported,
    isVirtualDevice: virtualDevice,
    focalLengthIn35mmFilm: focal35mm,
  );

  group('Android chain', () {
    test('physics is the primary path, and reproduces the R2 worked example', () {
      // The whole reversal R2 forced: with no LENS_INTRINSIC_CALIBRATION at all
      // — the common case, reported null even on Pixel hardware — the physics
      // derivation is not a fallback, it is the answer.
      final r = IntrinsicsResolver.resolveAndroid(
        androidFacts(),
        const ImageSize(4032, 3024),
      );
      expect(r.branch, 'android.physics');
      expect(r.intrinsics.source, IntrinsicsSource.derivedFromPhysics);
      // pixelPitch = 5.76/4032 → fx = 4.25/pitch = 2975.0
      expect(r.intrinsics.fx, closeTo(2975.0, 1e-6));
      expect(r.intrinsics.fy, closeTo(2975.0, 1e-6));
      expect(r.intrinsics.cx, closeTo(2016.0, 1e-9));
      expect(r.intrinsics.cy, closeTo(1512.0, 1e-9));
    });

    test('a 16:9 stream picks up the crop term, not a pure scale', () {
      // R2's worked example continued, and the reason §2.1 prefers 4:3: the
      // 16:9 stream letterboxes the 4:3 array to (0, 378, 4032, 2268), so
      // fx = 2975 × 1920/4032 = 1416.7 and cx/cy land exactly at image centre.
      // Treating the crop as a scale would give fy = 2975 × 1080/3024 = 1062.5,
      // a 25% error in the vertical focal.
      final r = IntrinsicsResolver.resolveAndroid(
        androidFacts(),
        const ImageSize(1920, 1080),
      );
      expect(r.intrinsics.fx, closeTo(1416.7, 0.05));
      expect(r.intrinsics.fy, closeTo(1416.7, 0.05));
      expect(r.intrinsics.cx, closeTo(960.0, 1e-6));
      expect(r.intrinsics.cy, closeTo(540.0, 1e-6));
      expect(
        r.notes.any((n) => n.contains('is a crop of')),
        isTrue,
        reason: 'the crop must be reported, not silently applied',
      );
    });

    test('LENS_INTRINSIC_CALIBRATION overrides physics when it is usable', () {
      final r = IntrinsicsResolver.resolveAndroid(
        androidFacts(calibration: const [3000.0, 3001.0, 2000.0, 1500.0, 0.0]),
        const ImageSize(4032, 3024),
      );
      expect(r.branch, 'android.lensIntrinsicCalibration');
      expect(r.intrinsics.source, IntrinsicsSource.platformCalibration);
      expect(r.intrinsics.fx, closeTo(3000.0, 1e-9));
      expect(r.intrinsics.fy, closeTo(3001.0, 1e-9));
      expect(r.intrinsics.cx, closeTo(2000.0, 1e-9));
      expect(r.intrinsics.cy, closeTo(1500.0, 1e-9));
    });

    test('an all-zero calibration is rejected, not believed', () {
      // R2 cites the key coming back "null/zeroed even on a Google Pixel". A
      // present-but-zeroed key is exactly as useless as a null one while
      // looking like success — believing it would give fx = 0 and an infinite
      // field of view.
      final r = IntrinsicsResolver.resolveAndroid(
        androidFacts(calibration: const [0.0, 0.0, 0.0, 0.0, 0.0]),
        const ImageSize(4032, 3024),
      );
      expect(r.branch, 'android.physics');
      expect(r.intrinsics.fx, closeTo(2975.0, 1e-6));
      expect(r.notes.any((n) => n.contains('all zero')), isTrue);
    });

    test('calibration values are cropped and scaled like any others', () {
      // The override substitutes sensor-frame values; it does not bypass the
      // crop-and-scale transform. A calibration matrix applied straight to a
      // 1920×1080 stream would be out by the full 0.476 scale factor.
      final r = IntrinsicsResolver.resolveAndroid(
        androidFacts(calibration: const [2975.0, 2975.0, 2016.0, 1512.0, 0.0]),
        const ImageSize(1920, 1080),
      );
      expect(r.branch, 'android.lensIntrinsicCalibration');
      expect(r.intrinsics.fx, closeTo(1416.7, 0.05));
      expect(r.intrinsics.cy, closeTo(540.0, 1e-6));
    });

    test('LENS_DISTORTION arrives reordered to OpenCV order', () {
      // R2's pure reorder, end to end through the resolver rather than only
      // through BrownConradyDistortion's own factory.
      final r = IntrinsicsResolver.resolveAndroid(
        androidFacts(distortion: const [0.1, 0.2, 0.3, 0.4, 0.5]),
        const ImageSize(4032, 3024),
      );
      final d = r.intrinsics.distortion! as BrownConradyDistortion;
      expect(d.openCvCoefficients, [0.1, 0.2, 0.4, 0.5, 0.3]);
    });

    test('a missing distortion model is null, never zeroed', () {
      // Substituting zero coefficients would claim a rectilinear lens, which
      // no phone lens is, and would silence the report.
      final r = IntrinsicsResolver.resolveAndroid(
        androidFacts(),
        const ImageSize(4032, 3024),
      );
      expect(r.intrinsics.distortion, isNull);
      expect(r.notes.any((n) => n.contains('LENS_DISTORTION is null')), isTrue);
    });

    test('a crop region moves the principal point but not the focal', () {
      // Digital zoom: fx is unchanged by cropping, cx/cy shift by the crop
      // origin. Getting this backwards is a classic way to break a zoomed
      // capture.
      final r = IntrinsicsResolver.resolveAndroid(
        androidFacts(crop: rect(1008, 756, 2016, 1512)),
        const ImageSize(2016, 1512),
      );
      expect(r.intrinsics.fx, closeTo(2975.0, 1e-6));
      expect(r.intrinsics.cx, closeTo(1008.0, 1e-9));
      expect(r.intrinsics.cy, closeTo(756.0, 1e-9));
    });

    test('the anchor is preCorrectionActiveArraySize when the two differ', () {
      // Math §4.1 anchors every coordinate to the pre-correction array. Using
      // the active array here would put the principal point 8 px out.
      final r = IntrinsicsResolver.resolveAndroid(
        androidFacts(
          preCorrection: rect(0, 0, 4032, 3024),
          active: rect(8, 8, 4016, 3008),
          arraysDiffer: true,
        ),
        const ImageSize(4032, 3024),
      );
      expect(r.intrinsics.cx, closeTo(2016.0, 1e-9));
      expect(r.notes.any((n) => n.contains('preCorrectionActiveArraySize')), isTrue);
    });

    test('falls back to the active array when pre-correction is absent', () {
      // API < 28. R2 §4 quotes AOSP: a device with no DISTORTION_CORRECTION_MODE
      // control must have the two arrays identical, so the active array is the
      // correct anchor rather than a compromise.
      final r = IntrinsicsResolver.resolveAndroid(
        androidFacts(preCorrection: null),
        const ImageSize(4032, 3024),
      );
      expect(r.branch, 'android.physics');
      expect(r.intrinsics.cx, closeTo(2016.0, 1e-9));
    });

    test('a HAL correction left enabled is reported', () {
      final r = IntrinsicsResolver.resolveAndroid(
        androidFacts(distortionOffRequested: false, supportsNonOff: true),
        const ImageSize(4032, 3024),
      );
      expect(
        r.notes.any((n) => n.contains('DISTORTION_CORRECTION_MODE_OFF was not requested')),
        isTrue,
      );
    });

    test('falls through to EXIF when the physics inputs are missing', () {
      final r = IntrinsicsResolver.resolveAndroid(
        androidFacts(focalLengthMm: null, physicalWidth: null, focal35mm: 26.0),
        const ImageSize(4032, 3024),
      );
      expect(r.branch, 'exif');
      expect(r.intrinsics.source, IntrinsicsSource.exifFallback);
      // fx = 4032 × 26 / 36
      expect(r.intrinsics.fx, closeTo(4032 * 26 / 36, 1e-6));
    });

    test('throws rather than guessing when every rung fails', () {
      // The defect this phase exists to remove is a *guessed* focal — the old
      // hard-coded 52° HFOV that no device in the fleet actually has. A
      // plausible default here would reintroduce it invisibly.
      expect(
        () => IntrinsicsResolver.resolveAndroid(
          androidFacts(focalLengthMm: null, physicalWidth: null),
          const ImageSize(4032, 3024),
        ),
        throwsA(isA<IntrinsicsUnavailable>()),
      );
    });
  });

  group('iOS chain', () {
    test('tier 1 wins when calibration data is delivered', () {
      final r = IntrinsicsResolver.resolveIos(
        iosFacts(
          calibrationMatrix: const [3000, 0, 2016, 0, 3000, 1512, 0, 0, 1],
          calibrationReference: size(4032, 3024),
          calibrationSupported: true,
          virtualDevice: true,
          connectionMatrix: const [9999, 0, 100, 0, 9999, 100, 0, 0, 1],
          connectionReference: size(4032, 3024),
          connectionArrived: true,
        ),
        const ImageSize(4032, 3024),
      );
      expect(r.branch, 'ios.cameraCalibrationData');
      expect(r.intrinsics.fx, closeTo(3000.0, 1e-9));
      expect(r.intrinsics.source, IntrinsicsSource.platformCalibration);
    });

    test('tier 2 is used when the attachment actually arrived', () {
      final r = IntrinsicsResolver.resolveIos(
        iosFacts(
          connectionMatrix: const [3000, 0, 2016, 0, 3000, 1512, 0, 0, 1],
          connectionReference: size(4032, 3024),
          connectionSupported: true,
          connectionArrived: true,
        ),
        const ImageSize(4032, 3024),
      );
      expect(r.branch, 'ios.connectionIntrinsicMatrix');
      expect(r.intrinsics.fx, closeTo(3000.0, 1e-9));
    });

    test('a supported-but-never-delivered attachment falls through, and says so', () {
      // The contested iPad behaviour: `isCameraIntrinsicMatrixDeliverySupported`
      // returns true and no attachment ever arrives. Trusting the flag is the
      // mistake that left R2's top question open since 2017.
      final r = IntrinsicsResolver.resolveIos(
        iosFacts(connectionSupported: true, connectionArrived: false, fov: 60.0),
        const ImageSize(4032, 3024),
      );
      expect(r.branch, 'ios.videoFieldOfView');
      expect(
        r.notes.any((n) => n.contains('no\nkCMSampleBufferAttachmentKey') ||
            n.contains('attachment ever')),
        isTrue,
      );
    });

    test('tier 3 reads videoFieldOfView as HORIZONTAL', () {
      // R2's confirmed answer. Reading 60° as diagonal on a 4:3 frame would
      // give fx = (5040/2)/tan(30°) = 4365 instead of 3492 — a 25% error that
      // BundleAdjusterRay would not recover from.
      final r = IntrinsicsResolver.resolveIos(
        iosFacts(fov: 60.0),
        const ImageSize(4032, 3024),
      );
      expect(r.branch, 'ios.videoFieldOfView');
      expect(r.intrinsics.source, IntrinsicsSource.derivedFromPhysics);
      expect(r.intrinsics.fx, closeTo(2016 / math.tan(30 * math.pi / 180), 1e-6));
      expect(r.intrinsics.hfovDegrees, closeTo(60.0, 1e-9));
      // The sanity check that distinguishes the two readings: a horizontal 60°
      // on 4:3 gives a vertical FOV of ~46.8°, a diagonal reading gives ~38.6°.
      expect(r.intrinsics.vfovDegrees, closeTo(46.83, 0.01));
    });

    test('a matrix stated for another size is rescaled, not applied raw', () {
      // The tier-2 matrix arrives with the preview buffer, not the still.
      // Applying a 1280-wide focal to a 4032-wide frame would understate fx by
      // a factor of 3.15 — and the panorama would not close by a wide margin.
      final r = IntrinsicsResolver.resolveIos(
        iosFacts(
          connectionMatrix: const [1000, 0, 640, 0, 1000, 480, 0, 0, 1],
          connectionReference: size(1280, 960),
          connectionSupported: true,
          connectionArrived: true,
        ),
        const ImageSize(4032, 3024),
      );
      expect(r.intrinsics.fx, closeTo(1000 * 4032 / 1280, 1e-6));
      expect(r.intrinsics.cx, closeTo(640 * 4032 / 1280, 1e-6));
      expect(r.intrinsics.cy, closeTo(480 * 4032 / 1280, 1e-6));
      // Same reference and output aspect, so no vertical offset is introduced
      // and the field of view is preserved exactly.
      expect(r.intrinsics.hfovDegrees, closeTo(2 * math.atan(640 / 1000) * 180 / math.pi, 1e-9));
    });

    test('a 16:9 reference against a 4:3 output centres vertically', () {
      // Both formats read the full sensor width, so the mapping matches width
      // and centres the height. fy is unchanged by that; cy moves.
      final r = IntrinsicsResolver.resolveIos(
        iosFacts(
          connectionMatrix: const [1920, 0, 960, 0, 1920, 540, 0, 0, 1],
          connectionReference: size(1920, 1080),
          connectionSupported: true,
          connectionArrived: true,
        ),
        const ImageSize(1920, 1440),
      );
      expect(r.intrinsics.fx, closeTo(1920.0, 1e-9));
      // scaledHeight 1080, output 1440 → offset = (1080-1440)/2 = -180
      expect(r.intrinsics.cy, closeTo(540 + 180, 1e-9));
      expect(r.notes.any((n) => n.contains('centring vertically')), isTrue);
    });

    test('the lookup table is carried through raw, never fitted here', () {
      // DistortionModel's own reasoning: a least-squares fit is where error is
      // introduced, so the raw table travels in the bundle and the fit happens
      // once, in the native stage that needs it.
      final r = IntrinsicsResolver.resolveIos(
        iosFacts(
          calibrationMatrix: const [3000, 0, 2016, 0, 3000, 1512, 0, 0, 1],
          calibrationReference: size(4032, 3024),
          calibrationSupported: true,
          virtualDevice: true,
          lut: const [1.0, 1.01, 1.04, 1.09],
          lutCenterX: 2016,
          lutCenterY: 1512,
        ),
        const ImageSize(4032, 3024),
      );
      final d = r.intrinsics.distortion! as LookupTableDistortion;
      expect(d.magnifications, const [1.0, 1.01, 1.04, 1.09]);
      expect(d.centerX, closeTo(2016.0, 1e-9));
      expect(r.notes.any((n) => n.contains('p1 = p2 = 0')), isTrue);
    });

    test('an enabled distortion correction is reported on every tier', () {
      // Mandatory whichever rung is reached (R2 §8): Apple applies
      // content-aware correction "at its discretion", so no fixed intrinsics
      // model is valid while it is on.
      final r = IntrinsicsResolver.resolveIos(
        iosFacts(gdcDisabled: false, contentAwareDisabled: false),
        const ImageSize(4032, 3024),
      );
      expect(r.branch, 'ios.videoFieldOfView');
      expect(r.notes.any((n) => n.contains('geometric distortion correction is ENABLED')), isTrue);
      expect(r.notes.any((n) => n.contains('content-aware distortion correction is ENABLED')), isTrue);
    });

    test('falls through to EXIF when the field of view is unknown', () {
      final r = IntrinsicsResolver.resolveIos(
        iosFacts(fov: 0, focal35mm: 26.0),
        const ImageSize(4032, 3024),
      );
      expect(r.branch, 'exif');
      expect(r.intrinsics.fx, closeTo(4032 * 26 / 36, 1e-6));
    });

    test('throws rather than guessing when every rung fails', () {
      expect(
        () => IntrinsicsResolver.resolveIos(
          iosFacts(fov: 0),
          const ImageSize(4032, 3024),
        ),
        throwsA(isA<IntrinsicsUnavailable>()),
      );
    });

    test('the realistic fleet case: single-lens iPad, tier 3, no distortion', () {
      // What R2 says to design *for* rather than treat as degraded: no
      // multi-camera device, so no calibration data; the connection attachment
      // unconfirmed and assumed absent; FOV-derived fx and a null distortion
      // model that bundle adjustment absorbs what it can of.
      final r = IntrinsicsResolver.resolveIos(
        iosFacts(fov: 63.0, calibrationSupported: false, virtualDevice: false),
        const ImageSize(4032, 3024),
      );
      expect(r.branch, 'ios.videoFieldOfView');
      expect(r.intrinsics.distortion, isNull);
      expect(r.intrinsics.source, IntrinsicsSource.derivedFromPhysics);
      expect(r.intrinsics.hfovDegrees, closeTo(63.0, 1e-9));
    });
  });

  group('provenance reaches the report', () {
    test('every branch carries a distinct machine-readable id', () {
      // Math §6: IntrinsicsSource must reach StitchReport so a soft panorama
      // can be traced to a weak intrinsics path instead of being blamed on the
      // stitcher. The branch id is the finer-grained half of that.
      final branches = <String>{
        IntrinsicsResolver.resolveAndroid(
          androidFacts(),
          const ImageSize(4032, 3024),
        ).branch,
        IntrinsicsResolver.resolveAndroid(
          androidFacts(calibration: const [3000.0, 3000.0, 2016.0, 1512.0, 0.0]),
          const ImageSize(4032, 3024),
        ).branch,
        IntrinsicsResolver.resolveIos(
          iosFacts(
            calibrationMatrix: const [3000, 0, 2016, 0, 3000, 1512, 0, 0, 1],
            calibrationReference: size(4032, 3024),
            calibrationSupported: true,
            virtualDevice: true,
          ),
          const ImageSize(4032, 3024),
        ).branch,
        IntrinsicsResolver.resolveIos(
          iosFacts(
            connectionMatrix: const [3000, 0, 2016, 0, 3000, 1512, 0, 0, 1],
            connectionReference: size(4032, 3024),
            connectionArrived: true,
          ),
          const ImageSize(4032, 3024),
        ).branch,
        IntrinsicsResolver.resolveIos(
          iosFacts(),
          const ImageSize(4032, 3024),
        ).branch,
        IntrinsicsResolver.resolveIos(
          iosFacts(fov: 0, focal35mm: 26),
          const ImageSize(4032, 3024),
        ).branch,
      };
      expect(branches, hasLength(6));
    });
  });
}
