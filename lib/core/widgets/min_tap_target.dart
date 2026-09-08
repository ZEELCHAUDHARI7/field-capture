import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../constants/app_sizes.dart';

/// Grows a control's touch area to [AppSizes.minTouchTarget] without changing
/// what is drawn.
///
/// The prototype states the floor — "touch targets never below 48px" — but it
/// also draws chrome that is deliberately smaller than that: the Today/All
/// filter is 36px tall, the coverage pill 36, the camera chip 38, the
/// connectivity pill about 31. Growing those to 48 would break the drawn
/// design; leaving them at their drawn size breaks the stated rule.
///
/// This resolves both the way Material resolves it for IconButton and the
/// button family: the child paints at its own size, and the render object
/// reports a larger size to hit testing, so the space around the control is
/// tappable but never inked.
///
/// Pass a zero dimension in [minSize] to grow on one axis only — a segmented
/// control needs height but must keep its natural width.
class MinTapTarget extends SingleChildRenderObjectWidget {
  const MinTapTarget({
    super.key,
    required Widget super.child,
    this.minSize = const Size.square(AppSizes.minTouchTarget),
  });

  /// Height-only growth, for controls laid out in a row that must not widen.
  const MinTapTarget.vertical({super.key, required Widget super.child})
      : minSize = const Size(0, AppSizes.minTouchTarget);

  final Size minSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMinTapTarget(minSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMinTapTarget renderObject,
  ) {
    renderObject.minSize = minSize;
  }
}

class _RenderMinTapTarget extends RenderShiftedBox {
  _RenderMinTapTarget(this._minSize) : super(null);

  Size _minSize;
  Size get minSize => _minSize;
  set minSize(Size value) {
    if (_minSize == value) return;
    _minSize = value;
    markNeedsLayout();
  }

  Size _expand(Size childSize) => Size(
        math.max(childSize.width, _minSize.width),
        math.max(childSize.height, _minSize.height),
      );

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final RenderBox? child = this.child;
    if (child == null) return constraints.constrain(_minSize);
    return constraints
        .constrain(_expand(child.getDryLayout(constraints.loosen())));
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.constrain(_minSize);
      return;
    }
    child.layout(constraints.loosen(), parentUsesSize: true);
    size = constraints.constrain(_expand(child.size));
    (child.parentData! as BoxParentData).offset =
        Alignment.center.alongOffset(size - child.size as Offset);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;

    // A touch that already lands on the painted child resolves normally, so
    // the ripple appears under the finger.
    if (super.hitTest(result, position: position)) return true;

    // A touch in the grown margin is pulled to the nearest point on the child
    // — nearest, not centre. A segmented control puts several children in a
    // row, and centre would send every near-miss to the middle segment.
    final RenderBox child = this.child!;
    final Offset childOffset = (child.parentData! as BoxParentData).offset;
    final Offset nearest = Offset(
      (position.dx - childOffset.dx).clamp(0.0, child.size.width),
      (position.dy - childOffset.dy).clamp(0.0, child.size.height),
    );
    return result.addWithRawTransform(
      transform: MatrixUtils.forceToPoint(nearest),
      position: nearest,
      hitTest: (BoxHitTestResult result, Offset position) {
        assert(position == nearest);
        return child.hitTest(result, position: nearest);
      },
    );
  }
}
