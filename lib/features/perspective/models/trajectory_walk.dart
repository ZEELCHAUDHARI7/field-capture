import 'dart:math' as math;

import '../../plan/models/plan_space.dart';
import '../../plan/models/trajectory.dart';

/// Turns a recorded trajectory into something you can stand on.
///
/// Scrubbing is expressed as a **fraction** of the walk rather than metres,
/// because the two figures the prototype shows disagree on purpose: the deck's
/// walk is "23 m" long, but its three pins are only about 13 m apart in
/// straight lines. A real walk is not straight between waypoints, so the
/// recorded track is longer than the polyline through its pins.
///
/// So: the fraction drives position along the polyline, and the same fraction
/// times [Trajectory.lengthMetres] is what the user is shown — "8 m of 23 m".
/// ASSUMPTIONS.md §I3.
class TrajectoryWalk {
  TrajectoryWalk(this.trajectory)
      : _points = trajectory.path,
        _cumulative = <double>[] {
    double running = 0;
    _cumulative.add(0);
    for (int i = 0; i < _points.length - 1; i++) {
      running += _distance(_points[i], _points[i + 1]);
      _cumulative.add(running);
    }
    polylineLength = running;
  }

  final Trajectory trajectory;
  final List<PlanPoint> _points;
  final List<double> _cumulative;

  /// Straight-line length through the pins, in metres.
  late final double polylineLength;

  /// The length the walk was recorded as — what the UI counts against.
  double get recordedLength => trajectory.lengthMetres;

  bool get isWalkable => _points.length >= 2 && polylineLength > 0;

  /// Where the viewer stands at [fraction] (0 = start pin, 1 = end pin).
  PlanPoint positionAt(double fraction) {
    if (_points.isEmpty) return const PlanPoint(0, 0);
    if (!isWalkable) return _points.first;

    final double target = fraction.clamp(0.0, 1.0) * polylineLength;

    for (int i = 0; i < _cumulative.length - 1; i++) {
      final double from = _cumulative[i];
      final double to = _cumulative[i + 1];
      if (target <= to || i == _cumulative.length - 2) {
        final double span = to - from;
        final double t = span == 0 ? 0 : (target - from) / span;
        return PlanPoint(
          _points[i].x + (_points[i + 1].x - _points[i].x) * t,
          _points[i].y + (_points[i + 1].y - _points[i].y) * t,
        );
      }
    }
    return _points.last;
  }

  /// The direction of travel at [fraction], in radians — the natural facing
  /// when the viewer has not dragged to look elsewhere.
  double bearingAt(double fraction) {
    if (!isWalkable) return 0;

    final double target = fraction.clamp(0.0, 1.0) * polylineLength;
    for (int i = 0; i < _cumulative.length - 1; i++) {
      if (target <= _cumulative[i + 1] || i == _cumulative.length - 2) {
        return math.atan2(
          _points[i + 1].y - _points[i].y,
          _points[i + 1].x - _points[i].x,
        );
      }
    }
    return 0;
  }

  /// "8 m of 23 m" — the left-hand figure.
  double travelledMetres(double fraction) =>
      fraction.clamp(0.0, 1.0) * recordedLength;

  static double _distance(PlanPoint a, PlanPoint b) {
    final double dx = b.x - a.x;
    final double dy = b.y - a.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}
