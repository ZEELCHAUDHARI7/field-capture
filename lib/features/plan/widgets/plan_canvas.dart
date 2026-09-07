import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../models/plan_document.dart';
import '../models/plan_marker.dart';
import '../models/plan_space.dart';
import '../models/trajectory.dart';
import 'map_pin.dart';
import 'plan_painter.dart';
import 'plan_view_controller.dart';

/// The calibrated 2D plan: pan, zoom, and everything pinned on it.
///
/// Two layers, deliberately:
///   1. the plan itself, painted inside an [InteractiveViewer] so pan and zoom
///      are native pointer handlers — "the plan stays responsive under gloves";
///   2. the pins, positioned in an overlay by transforming their plan-space
///      coordinates through the viewer's current matrix, so they hold a
///      constant size and a full 48px touch target at any zoom.
class PlanCanvas extends StatefulWidget {
  const PlanCanvas({
    super.key,
    required this.controller,
    required this.document,
    required this.captures,
    required this.issues,
    required this.trajectories,
    required this.showCoverage,
    required this.mutedIds,
    this.onIssueTap,
    this.onCaptureTap,
    this.onPlanTap,
    this.provisionalPin,
    this.liveTrajectory,
  });

  final PlanViewController controller;
  final PlanDocument document;
  final List<CaptureMarker> captures;
  final List<IssueMarker> issues;
  final List<Trajectory> trajectories;
  final bool showCoverage;

  /// Ids drawn faded — earlier visits, when the filter is All.
  final Set<String> mutedIds;

  final void Function(IssueMarker)? onIssueTap;
  final void Function(CaptureMarker)? onCaptureTap;

  /// Set during a pin mode. Receives plan-space metres, never pixels.
  final void Function(PlanPoint)? onPlanTap;

  /// The crosshair the user has tapped but not confirmed.
  final PlanPoint? provisionalPin;

  /// The walk being recorded right now, drawn in the live-capture blue so it
  /// reads apart from walks already saved.
  final Trajectory? liveTrajectory;

  @override
  State<PlanCanvas> createState() => _PlanCanvasState();
}

class _PlanCanvasState extends State<PlanCanvas> {
  @override
  Widget build(BuildContext context) {
    // Pin glyphs are chrome, not content — they must not grow with the
    // system text scale or they cover the plan.
    final double textScale =
        MediaQuery.textScalerOf(context).scale(10) / 10;

    return ColoredBox(
      color: AppColors.planBackdrop,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size viewport =
              Size(constraints.maxWidth, constraints.maxHeight);
          widget.controller.setViewport(viewport);

          final PlanTransform transform = PlanTransform.fit(
            viewport: viewport,
            planSize: widget.document.size,
          );

          return ClipRect(
            child: Stack(
              children: <Widget>[
                InteractiveViewer(
                  transformationController: widget.controller.transformation,
                  minScale: PlanViewController.minScale,
                  maxScale: PlanViewController.maxScale,
                  boundaryMargin: const EdgeInsets.all(64),
                  clipBehavior: Clip.none,
                  child: SizedBox(
                    width: viewport.width,
                    height: viewport.height,
                    // The detector sits INSIDE the viewer, so a tap arrives
                    // already in un-transformed canvas space — no matrix
                    // inversion, and pan still wins over tap.
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: widget.onPlanTap == null
                          ? null
                          : (TapUpDetails details) => widget.onPlanTap!(
                                transform.toPlan(details.localPosition),
                              ),
                      child: CustomPaint(
                        painter: PlanPainter(
                          document: widget.document,
                          transform: transform,
                          trajectories: widget.trajectories,
                          captures: widget.captures,
                          showCoverage: widget.showCoverage,
                          mutedIds: widget.mutedIds,
                          textScale: textScale,
                          liveTrajectory: widget.liveTrajectory,
                        ),
                      ),
                    ),
                  ),
                ),
                _PinOverlay(
                  controller: widget.controller,
                  transform: transform,
                  viewport: viewport,
                  captures: widget.captures,
                  issues: widget.issues,
                  trajectories: widget.trajectories,
                  mutedIds: widget.mutedIds,
                  onCaptureTap: widget.onCaptureTap,
                  onIssueTap: widget.onIssueTap,
                  provisionalPin: widget.provisionalPin,
                  liveTrajectory: widget.liveTrajectory,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PinOverlay extends StatelessWidget {
  const _PinOverlay({
    required this.controller,
    required this.transform,
    required this.viewport,
    required this.captures,
    required this.issues,
    required this.trajectories,
    required this.mutedIds,
    this.onCaptureTap,
    this.onIssueTap,
    this.provisionalPin,
    this.liveTrajectory,
  });

  final PlanViewController controller;
  final PlanTransform transform;
  final Size viewport;
  final List<CaptureMarker> captures;
  final List<IssueMarker> issues;
  final List<Trajectory> trajectories;
  final Set<String> mutedIds;
  final void Function(CaptureMarker)? onCaptureTap;
  final void Function(IssueMarker)? onIssueTap;
  final PlanPoint? provisionalPin;
  final Trajectory? liveTrajectory;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller.transformation,
      builder: (BuildContext context, _) {
        final Matrix4 matrix = controller.transformation.value;

        final List<Widget> pins = <Widget>[];

        // Trails first, then captures, then issues — issues sit on top because
        // they are the thing someone is looking for.
        for (final Trajectory trajectory in trajectories) {
          final bool muted = mutedIds.contains(trajectory.id);
          for (final TrajectoryNode node in trajectory.nodes) {
            pins.add(_positioned(
              matrix: matrix,
              point: node.at,
              anchor: _Anchor.centre,
              child: TrajectoryPin(node: node, muted: muted),
            ));
          }
        }

        for (final CaptureMarker capture in captures) {
          pins.add(_positioned(
            matrix: matrix,
            point: capture.at,
            anchor: _Anchor.bottom,
            child: CapturePin(
              marker: capture,
              muted: mutedIds.contains(capture.id),
              onTap: onCaptureTap == null
                  ? null
                  : () => onCaptureTap!(capture),
            ),
          ));
        }

        final Trajectory? live = liveTrajectory;
        if (live != null) {
          for (final TrajectoryNode node in live.nodes) {
            pins.add(_positioned(
              matrix: matrix,
              point: node.at,
              anchor: _Anchor.centre,
              child: TrajectoryPin(node: node, active: true),
            ));
          }
        }

        for (final IssueMarker issue in issues) {
          pins.add(_positioned(
            matrix: matrix,
            point: issue.at,
            anchor: _Anchor.centre,
            child: IssuePin(
              marker: issue,
              onTap: onIssueTap == null ? null : () => onIssueTap!(issue),
            ),
          ));
        }

        final PlanPoint? crosshair = provisionalPin;
        if (crosshair != null) {
          pins.add(_positioned(
            matrix: matrix,
            point: crosshair,
            anchor: _Anchor.centre,
            child: const ProvisionalPin(),
          ));
        }

        return Stack(children: pins);
      },
    );
  }

  /// Places one pin by pushing its plan-space point through the viewer matrix.
  Widget _positioned({
    required Matrix4 matrix,
    required PlanPoint point,
    required _Anchor anchor,
    required Widget child,
  }) {
    final Offset onCanvas = transform.toCanvas(point);
    final Offset onScreen = MatrixUtils.transformPoint(matrix, onCanvas);

    // The tap target is square and centred on the pin; a bottom-anchored pin
    // (the capture teardrop) is lifted so its tip lands on the point.
    const double half = PinMetrics.hitArea / 2;
    final double lift = anchor == _Anchor.bottom
        ? CapturePin.totalHeight / 2 - CapturePin.pointerHeight
        : 0;

    // Skip pins that have been panned well outside the viewport.
    if (onScreen.dx < -PinMetrics.hitArea ||
        onScreen.dy < -PinMetrics.hitArea ||
        onScreen.dx > viewport.width + PinMetrics.hitArea ||
        onScreen.dy > viewport.height + PinMetrics.hitArea) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: onScreen.dx - half,
      top: onScreen.dy - half - lift,
      child: child,
    );
  }
}

enum _Anchor { centre, bottom }
