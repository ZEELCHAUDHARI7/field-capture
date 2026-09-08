/// Fixtures for the Phase 09 tests: a real plan, hand-built session states, and
/// a way to look at the pixels the painter actually produced.
///
/// The pixel reader is the interesting one. Most of what this phase claims is a
/// claim about what is *on screen* — the dot sits exactly where the guidance
/// says the target is, the ring fills clockwise, the arrow replaces the dot
/// rather than joining it — and a test that only inspected widget properties
/// would pass for a painter that drew nothing at all.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:sphere_view/sphere_view.dart';
import 'package:sphere_view/src/utils/spherical_conventions.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

import 'capture_fixtures.dart';

/// The plan the Math §8 worked example produces: 29 positions in five rings.
CapturePlan buildFixturePlan() =>
    const PlanBuilder().buildPlan(intrinsics: fovIntrinsics(50, 69));

/// A guidance sample, with every field defaulted to "aimed, steady, on target".
GuidanceState guidanceState({
  double? offsetX = 0,
  double? offsetY = 0,
  GuidanceHint hint = GuidanceHint.onTarget,
  double dwellProgress = 0,
  double? edgeArrowRadians,
  bool withinAimTolerance = true,
  bool steady = true,
  double rollErrorRadians = 0,
  bool rollWithinTolerance = true,
  double angularErrorRadians = 0,
}) => GuidanceState(
  angularErrorRadians: angularErrorRadians,
  targetScreenOffsetX: offsetX,
  targetScreenOffsetY: offsetY,
  hint: hint,
  withinAimTolerance: withinAimTolerance,
  steady: steady,
  dwellProgress: dwellProgress,
  edgeArrowRadians: edgeArrowRadians,
  rollErrorRadians: rollErrorRadians,
  rollWithinTolerance: rollWithinTolerance,
);

/// A pose looking along the world heading, level, still.
DevicePose levelPose({double yaw = 0, double pitch = 0}) => DevicePose(
  deviceToWorld: SphericalConventions.aimingOrientation(yaw, pitch),
  gravityWorld: Vector3(0, 1, 0),
  timestampUs: 0,
  angularSpeedRadPerSec: 0,
);

/// A session snapshot.
///
/// [pose] and the two mark lists are what make the overlay's world-locked
/// elements testable: with no pose there is nothing to project from, so the dots
/// and the pinned thumbnails are skipped and a test would silently be checking a
/// simpler screen than the one that ships.
SessionState sessionState({
  required CapturePlan plan,
  GuidanceState? guidance,
  int capturedCount = 0,
  SessionPhase phase = SessionPhase.capturing,
  String? message,
  CaptureTarget? currentTarget,
  DevicePose? pose,
  List<CaptureTarget>? remainingTargets,
}) => SessionState(
  phase: phase,
  capturedCount: capturedCount,
  totalCount: plan.length,
  currentTarget: currentTarget ?? plan.targets[capturedCount.clamp(0, plan.length - 1)],
  guidance: guidance,
  message: message,
  pose: pose,
  remainingTargets:
      remainingTargets ?? plan.targets.skip(capturedCount).toList(growable: false),
);

/// The pixels a painter produced, addressable by coordinate.
class RenderedPainter {
  const RenderedPainter._(this._bytes, this.width, this.height);

  final ByteData _bytes;

  /// Image width in pixels.
  final int width;

  /// Image height in pixels.
  final int height;

  /// Rasterises [painter] at [size], one canvas pixel per logical pixel.
  static Future<RenderedPainter> of(CustomPainter painter, Size size) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    painter.paint(canvas, size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.round(),
      size.height.round(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    picture.dispose();
    image.dispose();
    return RenderedPainter._(bytes!, size.width.round(), size.height.round());
  }

  int _offsetOf(int x, int y) => ((y * width) + x) * 4;

  /// Alpha at ([x], [y]), `0..255`. Zero means nothing was drawn there.
  int alphaAt(num x, num y) {
    final px = x.round().clamp(0, width - 1);
    final py = y.round().clamp(0, height - 1);
    return _bytes.getUint8(_offsetOf(px, py) + 3);
  }

  /// Red channel at ([x], [y]) — white elements read 255, the dark outline 0.
  int redAt(num x, num y) {
    final px = x.round().clamp(0, width - 1);
    final py = y.round().clamp(0, height - 1);
    return _bytes.getUint8(_offsetOf(px, py));
  }

  /// Whether anything opaque enough to see was drawn within [radius] of
  /// ([x], [y]).
  bool anythingNear(num x, num y, {double radius = 3, int minAlpha = 40}) {
    for (var dy = -radius.round(); dy <= radius.round(); dy++) {
      for (var dx = -radius.round(); dx <= radius.round(); dx++) {
        if (alphaAt(x + dx, y + dy) >= minAlpha) return true;
      }
    }
    return false;
  }

  /// How many pixels in the whole image were drawn at all.
  int get drawnPixelCount {
    var count = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (_bytes.getUint8(_offsetOf(x, y) + 3) > 0) count++;
      }
    }
    return count;
  }
}
