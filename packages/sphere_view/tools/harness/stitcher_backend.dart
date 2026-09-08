import 'dart:typed_data';

import 'package:sphere_view/src/api/models/camera_intrinsics.dart';
import 'package:sphere_view/src/api/models/capture_bundle.dart';
import 'package:vector_math/vector_math_64.dart';

import 'camera_model.dart';
import 'float_image.dart';

/// What a stitcher is handed. Exactly a bundle and a canvas size — no ground
/// truth, by construction rather than by discipline.
class StitchJob {
  /// Creates a job.
  const StitchJob({required this.bundle, required this.canvas});

  /// The capture to stitch, loaded from disk.
  final CaptureBundle bundle;

  /// Output canvas. The replay tool sizes this from the tier, or matches it to
  /// the ground truth so S6 compares like with like.
  final EquirectCanvas canvas;
}

/// What a stitcher has to hand back for the metrics to be computable.
///
/// More than a panorama, and each extra field is there because one of the eight
/// metrics cannot be computed without it:
///
/// - [labels] gives S3 its seam paths. Deriving seams from label boundaries
///   rather than asking the stitcher for a seam list means the metric works
///   identically for a graph-cut pipeline and for a feather that never
///   consciously drew a seam at all — which is the only way to compare them.
/// - [counts] gives S5 its coverage, measured on the output rather than
///   re-derived from the plan, so a frame the stitcher silently dropped shows
///   up as missing coverage instead of being invisible.
/// - [estimatedDeviceToWorld] gives S1, S2 and residual tilt. A stitcher that
///   will not say where it thinks the cameras were cannot be scored on
///   geometry, only on appearance, and appearance is the metric that lies.
/// - [estimatedIntrinsics] is how a refined focal gets compared against the
///   truth, which is the direct test of criterion S2's real cause.
class StitchOutcome {
  /// Creates an outcome.
  const StitchOutcome({
    required this.equirect,
    required this.labels,
    required this.counts,
    required this.estimatedDeviceToWorld,
    required this.estimatedIntrinsics,
    required this.stageMilliseconds,
    this.warnings = const [],
    this.diagnostics = const {},
  });

  /// Sentinel in [labels] for a pixel no frame reached.
  static const int uncovered = -1;

  /// Sentinel in [labels] for a pixel invented by the pole fill. §4 of the
  /// phase doc is explicit that these must be excluded from SSIM, because the
  /// fill's smooth blur inflates it.
  static const int poleFilled = -2;

  /// The stitched panorama, display-referred.
  final FloatImage equirect;

  /// Per output pixel, the index into `CaptureBundle.positions` that won it, or
  /// one of the two sentinels above.
  final Int32List labels;

  /// Per output pixel, how many frames contributed, saturating at 255.
  final Uint8List counts;

  /// Where the stitcher believes each position's camera was pointing, as a
  /// device→world rotation in the same convention `DevicePose` uses.
  final List<Matrix3> estimatedDeviceToWorld;

  /// The intrinsics the stitcher actually used, after any refinement.
  final CameraIntrinsics estimatedIntrinsics;

  /// Wall-clock per pipeline stage, for the timings line of the report.
  final Map<String, int> stageMilliseconds;

  /// Every compromise the stitcher made, in plain language. Architecture §8's
  /// "never silently degrade", carried through the harness.
  final List<String> warnings;

  /// Whatever else the stitcher wants to say about how it got here — for the
  /// native backend, the compositing block of `StitchReport`: the seam scale, the
  /// strip count, the wrap-duplicate tile count, the intra-frame gain spread.
  ///
  /// Printed rather than scored. These are not metrics: none of them is right or
  /// wrong on its own, and none is measured against ground truth. They are what
  /// turns a failing metric into a diagnosis — "S3 was 2.4" says nothing about
  /// which of the four stages to look at, and "the seam ran at 0.19 scale over 8
  /// strips" does. Two of them do get promoted to assertions in §8, and those go
  /// through [MetricsEngine] like anything else that can fail.
  final Map<String, Object?> diagnostics;
}

/// A thing that turns a bundle into a panorama.
///
/// The interface exists so the harness can be built and *proven* before the
/// real stitcher does — the phase doc's sequencing note is emphatic that a
/// harness which has never printed FAIL has not been tested, and the only way
/// to make it print FAIL on demand is to be able to plug in something known to
/// be bad.
abstract class StitcherBackend {
  /// Short identifier, used on the command line and in the report header.
  String get name;

  /// One line on what this backend is and what to expect from it.
  String get description;

  /// Stitches [job].
  Future<StitchOutcome> stitch(StitchJob job);
}
