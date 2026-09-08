import '../api/models/image_size.dart';
import 'camera_platform.dart';

/// Discovers the best intrinsics a device can give, and says which rung of the
/// ladder it had to settle for.
///
/// Exists because R2 turned "get the intrinsics" into a **fallback chain with a
/// quality gradient**, not a lookup. Full `AVCameraCalibrationData` needs a
/// multi-camera device, which excludes the base iPad, Air and mini outright;
/// Android's `LENS_INTRINSIC_CALIBRATION` is documented as "may be null" with
/// no capability flag and is reported null even on Pixel hardware. So deriving
/// from physics is the *primary* path and the platform's own calibration is an
/// optional override — the reverse of the usual instinct, and what the evidence
/// supports (Math §4.1). The rung reached is recorded in
/// [CameraIntrinsics.source] and [CameraOpenResult.intrinsicsBranch], and
/// carried into `StitchReport`.
///
/// The derivation itself is not here: it is in `intrinsics_resolver.dart`, so
/// it can be unit-tested against synthetic capability sets without a device.
/// This class is the part that needs a camera — selection and opening.
class CameraProbe {
  /// Creates a probe over [platform].
  CameraProbe(this.platform);

  /// The platform channel to interrogate.
  final SphereCameraPlatform platform;

  /// Two aspect ratios closer than this count as the same aspect. Matches the
  /// tolerance the Spike B probe already uses to recognise 4:3.
  static const double aspectTolerance = 0.02;

  /// A focal length within this ratio of the shortest counts as *being* the
  /// shortest, i.e. as the ultra-wide. Ultra-wides are typically 0.5× the main
  /// lens, so 1.15 separates them comfortably without splitting hairs over two
  /// nominally-identical lenses reported to different precisions.
  static const double ultraWideRatio = 1.15;

  /// Picks the camera to capture with — the main rear one, since that is all
  /// most tablets in the fleet have.
  ///
  /// §2.1: filter to rear-facing, then exclude the ultra-wide, which is the one
  /// whose focal length is the shortest. The user's decision is main-camera
  /// only; the exclusion is still *logged* on the descriptor, because a future
  /// config may want it and a silently-dropped camera is hard to notice.
  Future<CameraSelection> selectCaptureCamera() async {
    final all = await platform.listCameras();
    if (all.isEmpty) {
      throw StateError('the platform reported no cameras at all');
    }

    final rejected = <String>[];
    final rear = <CameraDescriptor>[];
    for (final c in all) {
      if (c.facing != CameraFacing.back) {
        rejected.add('${c.id}: ${c.facing.name}-facing');
        continue;
      }
      if (c.availableSizes.isEmpty) {
        rejected.add('${c.id}: no still-capture sizes');
        continue;
      }
      if (c.excludedReason != null) {
        rejected.add('${c.id}: ${c.excludedReason}');
        continue;
      }
      rear.add(c);
    }
    if (rear.isEmpty) {
      throw StateError(
        'no usable rear camera. Considered:\n  ${rejected.join('\n  ')}',
      );
    }

    // Exclude the ultra-wide by focal length. A camera that reports no focal
    // length at all cannot be classified, so it stays in the running rather
    // than being dropped on a guess.
    final focals = <double>[
      for (final c in rear)
        if (c.focalLengthsMm.isNotEmpty) c.focalLengthsMm.reduce(_min),
    ];
    final candidates = <CameraDescriptor>[];
    if (focals.length > 1) {
      final shortest = focals.reduce(_min);
      for (final c in rear) {
        if (c.focalLengthsMm.isEmpty) {
          candidates.add(c);
          continue;
        }
        final focal = c.focalLengthsMm.reduce(_min);
        if (focal < shortest * ultraWideRatio && rear.length > 1) {
          rejected.add(
            '${c.id}: shortest focal (${focal.toStringAsFixed(2)} mm vs '
            '${shortest.toStringAsFixed(2)} mm) — the ultra-wide, excluded by '
            'the main-camera-only decision',
          );
          continue;
        }
        candidates.add(c);
      }
    } else {
      candidates.addAll(rear);
    }
    if (candidates.isEmpty) candidates.addAll(rear);

    // Among what is left, prefer the one offering the largest 4:3 still: 4:3
    // matches the sensor's full active array, so no crop factor enters the
    // intrinsics, and it gives the largest vertical FOV, which directly
    // reduces the number of rings.
    candidates.sort((a, b) {
      final areaA = _bestSize(a)?.area ?? 0;
      final areaB = _bestSize(b)?.area ?? 0;
      return areaB.compareTo(areaA);
    });

    return CameraSelection(
      camera: candidates.first,
      considered: all,
      rejected: rejected,
    );
  }

  /// Picks the still-capture size for [camera].
  ///
  /// Prefers the largest 4:3, per §2.1 — and does **not** assume the largest
  /// size is 4:3 (§7 pitfall 5). Falls back to the largest of any aspect, in
  /// which case the intrinsics derivation picks up a crop term and
  /// [CameraOpenResult.captureAspectIsFourThree] says so.
  ImageSize selectCaptureSize(CameraDescriptor camera) {
    final size = _bestSize(camera);
    if (size == null) {
      throw StateError('camera ${camera.id} offers no still-capture sizes');
    }
    return size;
  }

  /// Selects a camera and size, opens it, and returns everything the plan
  /// needs — including which rung of the intrinsics chain was reached.
  Future<ProbedCamera> openBestCamera({
    CaptureFormatSpec format = const CaptureFormatSpec(),
  }) async {
    final selection = await selectCaptureCamera();
    final size = format.captureSize ?? selectCaptureSize(selection.camera);
    final opened = await platform.open(
      selection.camera.id,
      CaptureFormatSpec(
        captureSize: size,
        preferFourThree: format.preferFourThree,
        previewTargetWidth: format.previewTargetWidth,
        useDeferredJpegEncode: format.useDeferredJpegEncode,
        jpegQuality: format.jpegQuality,
        computeFrameStatistics: format.computeFrameStatistics,
      ),
    );
    return ProbedCamera(selection: selection, opened: opened);
  }

  /// The largest 4:3 still, or the largest of any aspect if none is 4:3.
  static ImageSize? _bestSize(CameraDescriptor camera) {
    if (camera.availableSizes.isEmpty) return null;
    ImageSize? bestFourThree;
    ImageSize? bestAny;
    for (final s in camera.availableSizes) {
      if (bestAny == null || s.area > bestAny.area) bestAny = s;
      final ratio = s.width >= s.height
          ? s.aspectRatio
          : (s.height == 0 ? 0 : s.height / s.width);
      if ((ratio - 4 / 3).abs() < aspectTolerance) {
        if (bestFourThree == null || s.area > bestFourThree.area) {
          bestFourThree = s;
        }
      }
    }
    return bestFourThree ?? bestAny;
  }

  static double _min(double a, double b) => a < b ? a : b;
}

/// Which camera was chosen, and what was passed over to get there.
class CameraSelection {
  /// Creates a selection record.
  const CameraSelection({
    required this.camera,
    required this.considered,
    required this.rejected,
  });

  /// The camera capture will use.
  final CameraDescriptor camera;

  /// Everything the platform reported.
  final List<CameraDescriptor> considered;

  /// One line per camera not chosen, saying why. §2.1 asks for this
  /// explicitly: the ultra-wide is excluded by a product decision, not by a
  /// technical impossibility, and a future config may want it back.
  final List<String> rejected;

  @override
  String toString() =>
      'CameraSelection(${camera.id} of ${considered.length}, '
      '${rejected.length} rejected)';
}

/// An opened camera plus the selection that led to it.
class ProbedCamera {
  /// Creates a probed camera.
  const ProbedCamera({required this.selection, required this.opened});

  /// Which camera, and why.
  final CameraSelection selection;

  /// What opening it produced.
  final CameraOpenResult opened;

  /// The `device_info` block for `bundle.json`. Everything here is the sort of
  /// fact that explains a bad panorama six months later.
  Map<String, Object?> toDeviceInfoJson() => {
    'camera_id': selection.camera.id,
    'camera_hardware_level': selection.camera.hardwareLevel,
    'camera_has_manual_sensor': selection.camera.hasManualSensor,
    'camera_supports_bracketing': selection.camera.supportsBracketing,
    'cameras_rejected': selection.rejected,
    ...opened.toProvenanceJson(),
  };

  @override
  String toString() => 'ProbedCamera(${selection.camera.id}, $opened)';
}
