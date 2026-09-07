import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../plan/models/plan_space.dart';

/// A world point expressed relative to the camera.
///
/// `forward` is metres down the view axis, `right` is metres to the viewer's
/// right. Splitting this out of [PerspectiveCamera.project] is what makes near
/// plane clipping possible — and testable — without touching pixels.
@immutable
class CameraPoint {
  const CameraPoint(this.forward, this.right);

  final double forward;
  final double right;

  bool get isBehind => forward <= 0;
}

/// A pinhole camera standing on the plan at eye height.
///
/// The prototype constrains movement hard: "This is not free roam" and "Scrub
/// bar plus yaw control: two axes, no free-flight camera to get lost in." So
/// there is no pitch and no roll here — position comes from the trajectory,
/// and yaw is the only thing the user controls.
@immutable
class PerspectiveCamera {
  const PerspectiveCamera({
    required this.position,
    required this.yaw,
    required this.viewport,
    this.eyeHeight = 1.6,
    this.horizontalFovDegrees = 70,
    this.nearPlane = 0.2,
  });

  /// Where the camera stands, in plan metres.
  final PlanPoint position;

  /// Radians. 0 looks along +x; the plan's y axis runs south, so a viewer
  /// facing +x has +y on their right.
  final double yaw;

  final Size viewport;

  /// Standing eye height. Not specified by the prototype — ASSUMPTIONS.md §I2.
  final double eyeHeight;

  final double horizontalFovDegrees;

  /// Geometry closer than this is clipped rather than projected, which is what
  /// stops walls from inverting as the viewer walks through a doorway.
  final double nearPlane;

  double get _halfFov => horizontalFovDegrees * math.pi / 360;

  /// Pixels per unit of (right / forward).
  double get focalLength => (viewport.width / 2) / math.tan(_halfFov);

  Offset get principalPoint =>
      Offset(viewport.width / 2, viewport.height / 2);

  /// Plan metres → camera space.
  CameraPoint toCamera(PlanPoint point) {
    final double dx = point.x - position.x;
    final double dy = point.y - position.y;
    final double c = math.cos(yaw);
    final double s = math.sin(yaw);
    return CameraPoint(dx * c + dy * s, -dx * s + dy * c);
  }

  /// Camera space + a height above the slab → screen pixels.
  ///
  /// Null when the point is nearer than the near plane.
  ///
  /// Strictly nearer: [clipToNearPlane] lands points exactly ON the plane, and
  /// those must still project or every wall the viewer stands beside vanishes.
  Offset? projectCamera(CameraPoint point, double heightMetres) {
    if (point.forward < nearPlane) return null;
    final double scale = focalLength / point.forward;
    return Offset(
      principalPoint.dx + point.right * scale,
      principalPoint.dy - (heightMetres - eyeHeight) * scale,
    );
  }

  Offset? project(PlanPoint point, double heightMetres) =>
      projectCamera(toCamera(point), heightMetres);

  /// Clips a segment to the near plane.
  ///
  /// Returns null when the whole segment is behind the camera; otherwise the
  /// pair with any behind-camera end pulled forward onto the plane, so a wall
  /// the viewer is standing beside still draws instead of vanishing.
  (CameraPoint, CameraPoint)? clipToNearPlane(CameraPoint a, CameraPoint b) {
    final bool aVisible = a.forward > nearPlane;
    final bool bVisible = b.forward > nearPlane;

    if (!aVisible && !bVisible) return null;
    if (aVisible && bVisible) return (a, b);

    final double t = (nearPlane - a.forward) / (b.forward - a.forward);
    final CameraPoint clipped = CameraPoint(
      nearPlane,
      a.right + (b.right - a.right) * t,
    );

    return aVisible ? (a, clipped) : (clipped, b);
  }

  /// The horizon, where eye-height geometry converges. Used to fade the far
  /// distance rather than letting the floor grid run to a hard line.
  double get horizonY => principalPoint.dy;

  PerspectiveCamera copyWith({
    PlanPoint? position,
    double? yaw,
    Size? viewport,
  }) {
    return PerspectiveCamera(
      position: position ?? this.position,
      yaw: yaw ?? this.yaw,
      viewport: viewport ?? this.viewport,
      eyeHeight: eyeHeight,
      horizontalFovDegrees: horizontalFovDegrees,
      nearPlane: nearPlane,
    );
  }
}
