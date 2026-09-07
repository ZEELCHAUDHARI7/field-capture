import 'package:flutter/material.dart';

/// Owns the plan's pan/zoom matrix so the map controls, which sit outside the
/// canvas in the layout, can drive it.
///
/// Zoom is applied about the centre of the viewport rather than the origin, so
/// tapping `+` magnifies what the crew is already looking at.
class PlanViewController {
  PlanViewController();

  final TransformationController transformation = TransformationController();

  static const double minScale = 1;
  static const double maxScale = 6;

  Size _viewport = Size.zero;

  /// Called by the canvas on layout. Zooming before this is a no-op.
  // ignore: use_setters_to_change_properties
  void setViewport(Size size) => _viewport = size;

  double get scale => transformation.value.getMaxScaleOnAxis();

  bool get canZoomIn => scale < maxScale - 0.001;
  bool get canZoomOut => scale > minScale + 0.001;
  bool get isFitted => scale <= minScale + 0.001;

  void zoomIn() => _zoomBy(1.5);

  void zoomOut() => _zoomBy(1 / 1.5);

  /// Back to the fitted view. The prototype's third control is a frame icon,
  /// which reads as "show me the whole level again".
  void fit() => transformation.value = Matrix4.identity();

  void _zoomBy(double factor) {
    if (_viewport.isEmpty) return;

    final Matrix4 current = transformation.value;
    final double currentScale = current.getMaxScaleOnAxis();
    final double target = (currentScale * factor).clamp(minScale, maxScale);
    final double applied = target / currentScale;
    if ((applied - 1).abs() < 0.001) return;

    final double cx = _viewport.width / 2;
    final double cy = _viewport.height / 2;

    // Scale about (cx, cy), written out rather than composed with translate()
    // — vector_math's translate() overloads have shifted across releases and
    // this is version-proof.
    final Matrix4 about = Matrix4.identity()
      ..setEntry(0, 0, applied)
      ..setEntry(1, 1, applied)
      ..setEntry(0, 3, cx * (1 - applied))
      ..setEntry(1, 3, cy * (1 - applied));

    transformation.value = about.multiplied(current);
  }

  void dispose() => transformation.dispose();
}
