import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the viewer is doing inside one trajectory.
///
/// Two axes only. "Scrub bar plus yaw control: two axes, no free-flight camera
/// to get lost in."
@immutable
class PerspectiveState {
  const PerspectiveState({
    this.fraction = 0,
    this.yawOffset = 0,
    this.compare = false,
    this.wipe = 0.5,
  });

  /// 0 = start pin, 1 = end pin.
  final double fraction;

  /// Radians the viewer has turned away from the direction of travel. Facing
  /// follows the walk until they drag, then holds.
  final double yawOffset;

  /// "Compare is a mode, not a separate screen — the viewpoint is preserved",
  /// which is exactly why this lives beside the scrub rather than on a route.
  final bool compare;

  /// Where the wipe handle sits, 0 (all captured imagery) to 1 (all model).
  final double wipe;

  PerspectiveState copyWith({
    double? fraction,
    double? yawOffset,
    bool? compare,
    double? wipe,
  }) {
    return PerspectiveState(
      fraction: fraction ?? this.fraction,
      yawOffset: yawOffset ?? this.yawOffset,
      compare: compare ?? this.compare,
      wipe: wipe ?? this.wipe,
    );
  }
}

class PerspectiveController
    extends FamilyNotifier<PerspectiveState, String> {
  @override
  PerspectiveState build(String arg) => const PerspectiveState();

  void scrubTo(double fraction) =>
      state = state.copyWith(fraction: fraction.clamp(0.0, 1.0));

  /// Horizontal drag across the render. The prototype's hint says "Rotate the
  /// phone to look — drag to simulate", so drag is the fallback path and the
  /// gyroscope one is not wired up. ASSUMPTIONS.md §I4.
  void turnBy(double radians) =>
      state = state.copyWith(yawOffset: state.yawOffset + radians);

  void toggleCompare() => state = state.copyWith(compare: !state.compare);

  void setWipe(double value) =>
      state = state.copyWith(wipe: value.clamp(0.0, 1.0));
}

final perspectiveProvider =
    NotifierProvider.family<PerspectiveController, PerspectiveState, String>(
  PerspectiveController.new,
);
