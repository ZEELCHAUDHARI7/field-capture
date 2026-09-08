/// The single implementation of the intrinsics fallback chains — Math §4.1 for
/// Android, §4.2 for iOS.
///
/// It lives in Dart, over raw facts the native halves report, rather than in
/// Kotlin and Swift. Three reasons, in order of how much they cost if ignored:
///
/// 1. **Two implementations of one formula drift.** This formula decides the
///    focal length, and architecture §2 defect 2 is that a 4% focal error means
///    the panorama does not close — the last frame of a full turn lands ~14°
///    from the first. A divergence between the Kotlin and Swift copies would
///    look exactly like a device-specific stitcher bug.
/// 2. **Phase 06 §6 requires a unit test** that the chain "picks the right
///    branch for each synthetic capability set". A chain in Kotlin and Swift is
///    testable on two devices; a chain in Dart is testable on a laptop, over
///    every branch including the ones our fleet will never take.
/// 3. `android/README.md` already draws this line for the R2 coefficient
///    reorder — "that reorder already exists in Dart […] do not write a second
///    copy in Kotlin". The derivation is the same argument, one step up.
///
/// So Kotlin reads `CameraCharacteristics`, Swift reads `AVCaptureDevice`, and
/// neither of them computes an `fx`.
///
/// **Orientation.** Everything here is in the capture stream's own coordinates,
/// which are the sensor's — landscape on effectively every device. Capture is
/// portrait-locked (Phase 09 §4), but that rotates the *device*, not the image:
/// the JPEG still comes off the sensor in sensor orientation. The shot planner
/// is what swaps the two field-of-view numbers, and it is the only thing that
/// should.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../api/models/camera_intrinsics.dart';
import '../api/models/distortion_model.dart';
import '../api/models/image_size.dart';
import 'messages.g.dart';

/// The outcome of running a fallback chain: the intrinsics, which rung was
/// reached, and everything that was noticed on the way down.
///
/// [branch] is finer-grained than [CameraIntrinsics.source] on purpose. R2
/// established a three-rung *gradient* on iOS — calibrated dual-cam >
/// intrinsic-matrix-only > FOV-derived — while [IntrinsicsSource] has one value
/// covering the first two. The enum keeps the distinction that changes what the
/// stitcher can trust (measured vs. derived); this string keeps the one that
/// explains a device.
class IntrinsicsResolution {
  /// Creates a resolution.
  const IntrinsicsResolution({
    required this.intrinsics,
    required this.branch,
    this.notes = const [],
  });

  /// The intrinsics, expressed for the capture stream's pixel dimensions.
  final CameraIntrinsics intrinsics;

  /// Which rung of the chain produced them, as a stable machine-readable id —
  /// e.g. `android.physics`, `android.lensIntrinsicCalibration`,
  /// `ios.connectionIntrinsicMatrix`, `ios.videoFieldOfView`, `exif`.
  ///
  /// Goes into `bundle.json` and from there into `StitchReport`, which is how
  /// a soft panorama gets traced to a weak intrinsics path instead of being
  /// blamed on the stitcher (Math §6).
  final String branch;

  /// Everything that was compromised, missing or surprising. Never swallowed:
  /// architecture §8's rule is that no degradation is silent.
  final List<String> notes;

  @override
  String toString() =>
      'IntrinsicsResolution($branch, ${intrinsics.hfovDegrees.toStringAsFixed(2)}° '
      'HFOV, ${notes.length} notes)';
}

/// Thrown when no rung of the chain could produce intrinsics at all.
///
/// This is a hard failure rather than a guess, because a guessed focal is
/// exactly the defect this whole phase exists to remove: the previous
/// implementation hard-coded 52° and no device in the fleet actually has it.
class IntrinsicsUnavailable implements Exception {
  /// Creates the failure with the [reasons] each rung gave.
  const IntrinsicsUnavailable(this.platform, this.reasons);

  /// `android` or `ios`.
  final String platform;

  /// Why each rung declined, in chain order.
  final List<String> reasons;

  @override
  String toString() =>
      'IntrinsicsUnavailable($platform): no rung of the chain produced '
      'intrinsics.\n  ${reasons.join('\n  ')}';
}

/// Resolves platform facts into [CameraIntrinsics].
abstract final class IntrinsicsResolver {
  /// A 35 mm frame is 36 mm wide. This is the denominator of the EXIF
  /// last-resort formula and the reason it applies to the image's **long**
  /// side, not blindly to its width.
  static const double _film35mmWidthMm = 36.0;

  /// Two aspect ratios closer than this are treated as the same aspect.
  /// 0.02 is the tolerance the Spike B probe already uses to recognise 4:3
  /// among reported output sizes.
  static const double _aspectTolerance = 0.02;

  // ------------------------------------------------------------- Android --

  /// Math §4.1. Physics first, `LENS_INTRINSIC_CALIBRATION` as an override.
  ///
  /// That ordering is the reverse of the obvious one and it is what R2's
  /// evidence supports: the key is gated by no capability flag, is documented
  /// only as "may be null on some devices", and is reported null — or present
  /// but all-zero, which is worse because it looks like success — even on
  /// Pixel hardware.
  /// Takes a pigeon-generated wire type, and is therefore `@internal`: it is
  /// reachable from an exported class but is not part of the API. The facts
  /// come off the platform channel and their shape is regenerated, so a
  /// consumer who built against it would be building against a file whose
  /// header says not to edit it.
  @internal
  static IntrinsicsResolution resolveAndroid(
    AndroidIntrinsicFacts facts,
    ImageSize outputSize,
  ) {
    final notes = <String>[];
    final reasons = <String>[];

    if (!facts.distortionCorrectionModeOffRequested &&
        facts.distortionCorrectionSupportsNonOff) {
      notes.add(
        'DISTORTION_CORRECTION_MODE_OFF was not requested on a device that '
        'supports a non-OFF mode; the HAL may be warping geometry under us '
        '(AOSP concedes its own correction is imprecise)',
      );
    }
    if (facts.activeArraysDiffer) {
      notes.add(
        'activeArraySize differs from preCorrectionActiveArraySize, so the '
        'pre-correction distinction is live on this device; every coordinate '
        'below is anchored to preCorrectionActiveArraySize',
      );
    }

    // The frame every Android coordinate is expressed in (Math §4.1). Falls
    // back to the active array on API < 28, where R2 §4 says the two are
    // necessarily identical: a device with no DISTORTION_CORRECTION_MODE
    // control "must" have activeArray == preCorrectionActiveArray.
    final anchor = facts.preCorrectionActiveArray ?? facts.activeArray;
    if (anchor == null) {
      reasons.add('no pre-correction or active array rectangle reported');
    }

    // The crop actually applied. No zoom means the full anchor rectangle.
    final crop = facts.cropRegion ?? anchor;

    // ---- rung 1/2: sensor-frame fx, fy, cx, cy --------------------------
    double? fxSensor;
    double? fySensor;
    double? cxSensor;
    double? cySensor;
    var branch = 'android.physics';
    var source = IntrinsicsSource.derivedFromPhysics;

    final physicalW = facts.sensorPhysicalWidthMm;
    final physicalH = facts.sensorPhysicalHeightMm;
    final pixelArray = facts.pixelArraySize;
    final focal = facts.focalLengthMm;

    if (focal != null &&
        focal > 0 &&
        physicalW != null &&
        physicalH != null &&
        physicalW > 0 &&
        physicalH > 0 &&
        pixelArray != null &&
        pixelArray.width > 0 &&
        pixelArray.height > 0) {
      final pitchX = physicalW / pixelArray.width;
      final pitchY = physicalH / pixelArray.height;
      fxSensor = focal / pitchX;
      fySensor = focal / pitchY;
    } else {
      reasons.add(
        'physics path unavailable: focalLengthMm=$focal, '
        'physicalSizeMm=($physicalW, $physicalH), pixelArraySize=$pixelArray',
      );
    }

    if (anchor != null) {
      cxSensor = anchor.left + anchor.width / 2.0;
      cySensor = anchor.top + anchor.height / 2.0;
    }

    // The override. Its values are already in pre-correction-array pixels, so
    // it substitutes at exactly this point and then goes through the same
    // crop-and-scale transform as the derived numbers.
    final calibration = facts.lensIntrinsicCalibration;
    final calibrationFov = _isUsableCalibration(calibration) && anchor != null
        ? _hfovDegreesFor(calibration![0], anchor.width.toDouble())
        : null;
    if (calibrationFov != null && !_isPlausibleHfov(calibrationFov)) {
      // The override is rejected rather than adopted, so the ladder falls
      // through to the physics rung below.
      //
      // R2 already found this key unreliable — null, or all-zero on Pixel
      // hardware, which is worse because it looks like success. An
      // out-of-family focal is the third way it fails, and the most damaging:
      // it *is* a number, it passes every structural check, and the whole
      // pipeline downstream is built on it. Physics (sensor size and focal
      // length in mm) is far harder to get wrong, so it is the better rung even
      // though it nominally ranks lower.
      notes.add(
        'LENS_INTRINSIC_CALIBRATION implies a horizontal field of view of '
        '${calibrationFov.toStringAsFixed(1)}°, outside the '
        '${_minPlausibleHfovDegrees.toStringAsFixed(0)}–'
        '${_maxPlausibleHfovDegrees.toStringAsFixed(0)}° a phone or tablet rear '
        'camera can have; rejected in favour of the physics path',
      );
    } else if (_isUsableCalibration(calibration)) {
      // [fx, fy, cx, cy, s]. The skew term s is deliberately dropped: OpenCV's
      // K carries no skew, and every reported value in the wild is zero.
      fxSensor = calibration![0];
      fySensor = calibration[1];
      cxSensor = calibration[2];
      cySensor = calibration[3];
      branch = 'android.lensIntrinsicCalibration';
      source = IntrinsicsSource.platformCalibration;
      if (calibration.length > 4 && calibration[4].abs() > 1e-9) {
        notes.add(
          'LENS_INTRINSIC_CALIBRATION reports a non-zero skew of '
          '${calibration[4]}, which the pinhole model in Math §4 has no term '
          'for; dropped',
        );
      }
    } else if (calibration != null) {
      notes.add(
        'LENS_INTRINSIC_CALIBRATION was present but unusable '
        '(${calibration.every((v) => v == 0) ? 'all zero' : 'malformed'}) — '
        'exactly the failure R2 saw on Pixel hardware; using physics',
      );
    }

    if (fxSensor == null ||
        fySensor == null ||
        cxSensor == null ||
        cySensor == null ||
        crop == null) {
      // ---- rung 3: EXIF ---------------------------------------------------
      final exif = _exifFallback(
        facts.focalLengthIn35mmFilm,
        outputSize,
        notes,
        reasons,
      );
      if (exif != null) return exif;
      throw IntrinsicsUnavailable('android', reasons);
    }

    // ---- crop, then the stream's aspect-fit sub-rect, then scale ----------
    final cxCrop = cxSensor - crop.left;
    final cyCrop = cySensor - crop.top;

    final stream = _aspectFitSubRect(
      sourceWidth: crop.width.toDouble(),
      sourceHeight: crop.height.toDouble(),
      outputAspect: outputSize.aspectRatio,
    );
    if (stream.isCrop) {
      notes.add(
        'the ${_ratioLabel(outputSize.aspectRatio)} stream is a crop of the '
        '${_ratioLabel(crop.width / crop.height)} crop region, not a pure '
        'scale; source rect is '
        '(${stream.left.toStringAsFixed(1)}, ${stream.top.toStringAsFixed(1)}, '
        '${stream.width.toStringAsFixed(1)}, ${stream.height.toStringAsFixed(1)}). '
        'Phase 06 §2.1 prefers a 4:3 output precisely to avoid this',
      );
    }

    final scaleX = outputSize.width / stream.width;
    final scaleY = outputSize.height / stream.height;

    final distortion = _androidDistortion(facts.lensDistortion, notes);

    return _guardFieldOfView(
      IntrinsicsResolution(
        intrinsics: CameraIntrinsics(
          fx: fxSensor * scaleX,
          fy: fySensor * scaleY,
          cx: (cxCrop - stream.left) * scaleX,
          cy: (cyCrop - stream.top) * scaleY,
          imageSize: outputSize,
          source: source,
          distortion: distortion,
        ),
        branch: branch,
        notes: notes,
      ),
      // Judged on the whole sensor rectangle, so a digital-zoom crop is not
      // mistaken for a telephoto lens.
      lensHfovDegrees: anchor == null
          ? null
          : _hfovDegreesFor(fxSensor, anchor.width.toDouble()),
    );
  }

  /// Last line of defence on the field of view, whichever rung produced it.
  ///
  /// The per-rung checks above prefer a *different source* when one looks wrong,
  /// which is always the better answer. This one runs when every rung has been
  /// tried and the answer is still out of family: it clamps the focal to the
  /// nearest plausible bound and says so, loudly, in the notes.
  ///
  /// Clamping rather than throwing because refusing here would mean no capture at
  /// all on a device whose HAL misreports, and a panorama built on a 40° bound is
  /// wrong by a factor the operator can see and re-shoot, where one built on 23.5°
  /// is unusable and looks like a stitcher bug. The note is what makes it
  /// diagnosable instead of mysterious.
  /// [lensHfovDegrees] is the *uncropped* field of view, when the caller knows
  /// it, and is what the band is judged against.
  ///
  /// The distinction is load-bearing. Digital zoom delivers a crop of the sensor,
  /// so the stream's own field of view is legitimately narrow — a 2x crop of a
  /// 67° lens is about 37°, under the floor — while the lens behind it is
  /// perfectly ordinary. Judging the crop would clamp a correctly resolved zoom
  /// capture and corrupt exactly the intrinsics this method exists to protect.
  static IntrinsicsResolution _guardFieldOfView(
    IntrinsicsResolution resolution, {
    double? lensHfovDegrees,
  }) {
    final hfov = resolution.intrinsics.hfovDegrees;
    if (_isPlausibleHfov(lensHfovDegrees ?? hfov)) return resolution;

    final bound = hfov < _minPlausibleHfovDegrees
        ? _minPlausibleHfovDegrees
        : _maxPlausibleHfovDegrees;
    final width = resolution.intrinsics.imageSize.width.toDouble();
    final clampedFx = width / (2 * math.tan(bound * math.pi / 360));
    final ratio = clampedFx / resolution.intrinsics.fx;

    return IntrinsicsResolution(
      intrinsics: CameraIntrinsics(
        fx: clampedFx,
        fy: resolution.intrinsics.fy * ratio,
        cx: resolution.intrinsics.cx,
        cy: resolution.intrinsics.cy,
        imageSize: resolution.intrinsics.imageSize,
        source: resolution.intrinsics.source,
        distortion: resolution.intrinsics.distortion,
      ),
      branch: resolution.branch,
      notes: [
        ...resolution.notes,
        'every intrinsics rung produced an implausible horizontal field of view '
            'of ${hfov.toStringAsFixed(1)}°; clamped to '
            '${bound.toStringAsFixed(0)}° so the shot plan and the warp are built '
            'on a figure a camera could actually have. Geometry from this capture '
            'is approximate — the device did not report a usable lens '
            'specification.',
      ],
    );
  }

  // ----------------------------------------------------------------- iOS --

  /// Math §4.2, all three tiers, in order.
  ///
  /// R2 says to expect tier 3 and design for it rather than treat it as
  /// degraded: full `AVCameraCalibrationData` needs a multi-camera virtual
  /// device — confirmed by an Apple engineer — which excludes base iPad, iPad
  /// Air and iPad mini outright, and the last qualifying model was the 2022 M2
  /// iPad Pro.
  /// Takes a pigeon-generated wire type, and is therefore `@internal`: it is
  /// reachable from an exported class but is not part of the API. The facts
  /// come off the platform channel and their shape is regenerated, so a
  /// consumer who built against it would be building against a file whose
  /// header says not to edit it.
  @internal
  static IntrinsicsResolution resolveIos(
    IosIntrinsicFacts facts,
    ImageSize outputSize,
  ) {
    final notes = <String>[];
    final reasons = <String>[];

    // Mandatory on every capture whichever tier is used (R2 §8): Apple's
    // content-aware correction is applied "at its discretion", i.e. variably
    // and per-frame, which invalidates any fixed intrinsics model.
    if (!facts.geometricDistortionCorrectionDisabled) {
      notes.add(
        'geometric distortion correction is ENABLED — the fixed intrinsics '
        'model below does not describe the delivered frames, and '
        'videoFieldOfView is the wrong number to derive from',
      );
    }
    if (!facts.contentAwareDistortionCorrectionDisabled) {
      notes.add(
        'content-aware distortion correction is ENABLED — Apple applies it '
        'variably per frame, so no fixed intrinsics model is valid',
      );
    }

    final lut = _iosDistortion(facts, outputSize, notes);

    // ---- tier 1: AVCameraCalibrationData --------------------------------
    final calib = facts.calibrationIntrinsicMatrix;
    final calibRef = facts.calibrationReferenceSize;
    if (_isUsableMatrix(calib) && calibRef != null) {
      return _guardFieldOfView(IntrinsicsResolution(
        intrinsics: _fromMatrix(
          calib!,
          reference: ImageSize.fromInts(calibRef.width, calibRef.height),
          output: outputSize,
          source: IntrinsicsSource.platformCalibration,
          distortion: lut,
          notes: notes,
        ),
        branch: 'ios.cameraCalibrationData',
        notes: notes,
      ));
    }
    reasons.add(
      'AVCameraCalibrationData unavailable '
      '(deliverySupported=${facts.calibrationDataDeliverySupported}, '
      'isVirtualDevice=${facts.isVirtualDevice}) — expected on a single-lens '
      'iPad, per R2',
    );

    // ---- tier 2: AVCaptureConnection.cameraIntrinsicMatrix --------------
    final conn = facts.connectionIntrinsicMatrix;
    final connRef = facts.connectionIntrinsicReferenceSize;
    if (facts.connectionIntrinsicAttachmentArrived &&
        _isUsableMatrix(conn) &&
        connRef != null) {
      return _guardFieldOfView(IntrinsicsResolution(
        intrinsics: _fromMatrix(
          conn!,
          reference: ImageSize.fromInts(connRef.width, connRef.height),
          output: outputSize,
          source: IntrinsicsSource.platformCalibration,
          distortion: lut,
          notes: notes,
        ),
        branch: 'ios.connectionIntrinsicMatrix',
        notes: notes,
      ));
    }
    if (facts.connectionIntrinsicDeliverySupported &&
        !facts.connectionIntrinsicAttachmentArrived) {
      // The exact failure Spike B was built to catch. Reporting the capability
      // flag is what left this question open from 2017; the flag said yes and
      // no attachment ever arrived.
      notes.add(
        'isCameraIntrinsicMatrixDeliverySupported was true but no '
        'kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix attachment ever '
        'arrived on a real frame — this is the contested iPad behaviour from '
        'R2 "Still unknown" #1, now observed',
      );
    }
    reasons.add(
      'AVCaptureConnection.cameraIntrinsicMatrix unavailable '
      '(supported=${facts.connectionIntrinsicDeliverySupported}, '
      'attachmentArrived=${facts.connectionIntrinsicAttachmentArrived})',
    );

    // ---- tier 3: videoFieldOfView ---------------------------------------
    // R2 confirmed this is HORIZONTAL, not diagonal. Reading it as diagonal
    // would put fx out by roughly 20% on a 4:3 frame.
    if (facts.videoFieldOfViewDegrees > 0) {
      final hfov = facts.videoFieldOfViewDegrees * math.pi / 180;
      notes.add(
        'derived from videoFieldOfView = '
        '${facts.videoFieldOfViewDegrees.toStringAsFixed(2)}°, read as '
        'HORIZONTAL per R2; principal point assumed centred and pixels square, '
        'which is all this rung can honestly claim',
      );
      return _guardFieldOfView(IntrinsicsResolution(
        intrinsics: CameraIntrinsics.fromHorizontalFov(
          hfovRadians: hfov,
          imageSize: outputSize,
          distortion: lut,
        ),
        branch: 'ios.videoFieldOfView',
        notes: notes,
      ));
    }
    reasons.add('videoFieldOfView reported 0, i.e. unknown');

    // ---- tier 4: EXIF ----------------------------------------------------
    final exif = _exifFallback(
      facts.focalLengthIn35mmFilm,
      outputSize,
      notes,
      reasons,
    );
    if (exif != null) return exif;

    throw IntrinsicsUnavailable('ios', reasons);
  }

  // ------------------------------------------------------------- helpers --

  /// `fx = longSide · FocalLengthIn35mmFilm / 36`.
  ///
  /// Against the **long** side, not blindly against the width: the 36 mm in
  /// the denominator is the width of a 35 mm *frame*, so the equivalence is
  /// stated along the sensor's longer dimension. On a landscape capture stream
  /// that is the width and the distinction never shows; getting it wrong on a
  /// portrait one would cost a factor of 4/3.
  static IntrinsicsResolution? _exifFallback(
    double? focal35mm,
    ImageSize outputSize,
    List<String> notes,
    List<String> reasons,
  ) {
    if (focal35mm == null || focal35mm <= 0) {
      reasons.add('no FocalLengthIn35mmFilm for the EXIF fallback either');
      return null;
    }
    final longSide = math.max(outputSize.width, outputSize.height);
    final fx = longSide * focal35mm / _film35mmWidthMm;
    notes.add(
      'EXIF fallback: fx = $longSide × $focal35mm / 36 = '
      '${fx.toStringAsFixed(1)}. Good to maybe 10%, which BundleAdjusterRay '
      'can still recover from (Math §4.3) — but only just',
    );
    return IntrinsicsResolution(
      intrinsics: CameraIntrinsics(
        fx: fx,
        fy: fx,
        cx: outputSize.width / 2,
        cy: outputSize.height / 2,
        imageSize: outputSize,
        source: IntrinsicsSource.exifFallback,
      ),
      branch: 'exif',
      notes: notes,
    );
  }

  /// Re-expresses a platform 3×3 for [output].
  ///
  /// The two renderings come off one sensor, and camera formats differ by a
  /// *vertical* crop at constant full sensor width far more often than by
  /// anything else — 4:3 and 16:9 on the same device are the same width. So
  /// the transform is: scale both axes to a common width, then centre-crop or
  /// centre-pad vertically. When the aspects already agree, which is the case
  /// we engineer for by preferring a 4:3 capture, this degenerates to the pure
  /// scale of [CameraIntrinsics.scaledTo].
  static CameraIntrinsics _fromMatrix(
    List<double> m, {
    required ImageSize reference,
    required ImageSize output,
    required IntrinsicsSource source,
    required DistortionModel? distortion,
    required List<String> notes,
  }) {
    final scale = output.width / reference.width;
    final scaledHeight = reference.height * scale;
    final verticalOffset = (scaledHeight - output.height) / 2;

    if ((reference.aspectRatio - output.aspectRatio).abs() > _aspectTolerance) {
      notes.add(
        'the intrinsic matrix is stated for ${reference.width.toInt()}×'
        '${reference.height.toInt()} but the capture stream is '
        '${output.width.toInt()}×${output.height.toInt()}; mapped by matching '
        'width and centring vertically, which assumes both formats read the '
        'full sensor width',
      );
    }

    return CameraIntrinsics(
      fx: m[0] * scale,
      fy: m[4] * scale,
      cx: m[2] * scale,
      cy: m[5] * scale - verticalOffset,
      imageSize: output,
      source: source,
      distortion: distortion,
    );
  }

  /// R2's pure reorder, `{κ1, κ2, κ4, κ5, κ3}` → `(k1, k2, p1, p2, k3)`.
  ///
  /// Delegated to [BrownConradyDistortion.fromAndroidLensDistortion] rather
  /// than re-indexed here, so there is exactly one place in the codebase that
  /// knows the permutation.
  static DistortionModel? _androidDistortion(
    List<double>? kappa,
    List<String> notes,
  ) {
    if (kappa == null) {
      notes.add(
        'LENS_DISTORTION is null, so no distortion model — common, and the '
        'null-rate R2 could find no fleet data for. Bundle adjustment absorbs '
        'what it can; straight lines near the frame border will not be '
        'straight',
      );
      return null;
    }
    if (kappa.length != 5) {
      notes.add(
        'LENS_DISTORTION had ${kappa.length} elements, not 5; ignored',
      );
      return null;
    }
    final model = BrownConradyDistortion.fromAndroidLensDistortion(kappa);
    if (model.isIdentity) {
      notes.add(
        'LENS_DISTORTION is present but all-zero, i.e. the HAL claims a '
        'perfectly rectilinear lens. Taken at face value, but no phone lens '
        'is rectilinear and this is one of the two shapes R2 saw the key fail '
        'in',
      );
    }
    return model;
  }

  /// iOS distortion is radial-only: a magnification lookup table along the
  /// radius from `lensDistortionCenter`, with **no tangential component** at
  /// all. Stored in that raw form, per `DistortionModel`'s own reasoning — the
  /// Brown–Conrady fit is a least-squares step, and a fit is where error gets
  /// introduced, so it belongs in the native stage that needs it and not here.
  static DistortionModel? _iosDistortion(
    IosIntrinsicFacts facts,
    ImageSize output,
    List<String> notes,
  ) {
    final table = facts.lensDistortionLookupTable;
    if (table == null || table.isEmpty) return null;

    // The centre is in the calibration reference frame's pixels. Move it to
    // the output frame the same way the matrix moves.
    final reference = facts.calibrationReferenceSize;
    var cx = facts.lensDistortionCenterX ?? output.width / 2;
    var cy = facts.lensDistortionCenterY ?? output.height / 2;
    if (reference != null && reference.width > 0) {
      final scale = output.width / reference.width;
      final verticalOffset = (reference.height * scale - output.height) / 2;
      cx *= scale;
      cy = cy * scale - verticalOffset;
    }
    notes.add(
      '${table.length}-entry lensDistortionLookupTable carried through raw; '
      'the Brown–Conrady fit forces p1 = p2 = 0, because Apple’s model is '
      'purely radial and fitting tangential terms would be fitting noise',
    );
    return LookupTableDistortion(
      magnifications: table,
      centerX: cx,
      centerY: cy,
    );
  }

  /// True when `LENS_INTRINSIC_CALIBRATION` is present *and* means something.
  ///
  /// The all-zero check is not defensive padding: R2 cites a community report
  /// of the key coming back "null/zeroed even on a Google Pixel", and a
  /// present-but-zeroed key is exactly as useless as a null one while looking
  /// like success. Spike B records the two shapes separately for this reason.
  /// The narrowest horizontal field of view a rear camera on a phone or tablet
  /// plausibly has. Below this it is a telephoto, which no device exposes as its
  /// main capture camera, and a shot plan built on it would be wrong.
  static const double _minPlausibleHfovDegrees = 40.0;

  /// The widest. Ultra-wides reach the low 120s; past this it is a fisheye the
  /// pinhole model cannot describe anyway.
  static const double _maxPlausibleHfovDegrees = 130.0;

  /// Horizontal field of view for a focal expressed in pixels of a frame
  /// [widthPx] wide.
  static double _hfovDegreesFor(double fxPx, double widthPx) =>
      2 * math.atan(widthPx / (2 * fxPx)) * 180 / math.pi;

  /// Whether [hfovDegrees] is in family for a device rear camera.
  ///
  /// The band exists because every stage downstream trusts this number
  /// completely: the shot plan spaces its positions by it
  /// (`plan_builder.dart`), and the warp places every pixel by it. A capture
  /// that reported 23.5° — a telephoto figure from a camera with about 67° —
  /// produced a panorama that was 46.6% photography and the rest fill, and
  /// nothing anywhere questioned the number.
  static bool _isPlausibleHfov(double hfovDegrees) =>
      hfovDegrees.isFinite &&
      hfovDegrees >= _minPlausibleHfovDegrees &&
      hfovDegrees <= _maxPlausibleHfovDegrees;

  static bool _isUsableCalibration(List<double>? c) =>
      c != null &&
      c.length >= 4 &&
      c[0] > 0 &&
      c[1] > 0 &&
      c.every((v) => v.isFinite);

  /// A row-major 3×3 is usable when it has a positive focal on both axes.
  static bool _isUsableMatrix(List<double>? m) =>
      m != null &&
      m.length == 9 &&
      m.every((v) => v.isFinite) &&
      m[0] > 0 &&
      m[4] > 0;

  /// `SCALER_CROP_REGION`'s own letterbox/pillarbox rule: the stream takes the
  /// largest centred sub-rect of the source with the output's aspect ratio.
  ///
  /// Skipping this term is what makes a 16:9 stream's focal wrong. R2's worked
  /// example turns on it: a 4:3 array with a 16:9 output letterboxes to
  /// `(0, 378, 4032, 2268)`, and only then does `fx` come out at 1416.7 with
  /// `cx`/`cy` landing exactly at image centre.
  static _StreamRect _aspectFitSubRect({
    required double sourceWidth,
    required double sourceHeight,
    required double outputAspect,
  }) {
    final sourceAspect = sourceWidth / sourceHeight;
    if (outputAspect > sourceAspect) {
      // Output is wider: keep full width, crop top and bottom.
      final height = sourceWidth / outputAspect;
      return _StreamRect(
        left: 0,
        top: (sourceHeight - height) / 2,
        width: sourceWidth,
        height: height,
        isCrop: (outputAspect - sourceAspect).abs() > _aspectTolerance,
      );
    }
    // Output is taller or equal: keep full height, crop left and right.
    final width = sourceHeight * outputAspect;
    return _StreamRect(
      left: (sourceWidth - width) / 2,
      top: 0,
      width: width,
      height: sourceHeight,
      isCrop: (outputAspect - sourceAspect).abs() > _aspectTolerance,
    );
  }

  static String _ratioLabel(double aspect) {
    if ((aspect - 4 / 3).abs() < _aspectTolerance) return '4:3';
    if ((aspect - 16 / 9).abs() < _aspectTolerance) return '16:9';
    if ((aspect - 3 / 2).abs() < _aspectTolerance) return '3:2';
    if ((aspect - 1.0).abs() < _aspectTolerance) return '1:1';
    return aspect.toStringAsFixed(3);
  }
}

/// The sub-rect of the crop region a stream of a given aspect actually reads.
class _StreamRect {
  const _StreamRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.isCrop,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  /// Whether this is a genuine crop rather than a pure scale, i.e. whether the
  /// output aspect differs from the source's.
  final bool isCrop;
}
