import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../api/models/camera_intrinsics.dart';
import '../api/models/device_pose.dart';
import '../api/models/image_size.dart';
import '../api/models/json_codec.dart';
import '../api/models/sphere_capture_config.dart';
import '../plan/capture_plan.dart';
import '../utils/quaternion_utils.dart';
import '../utils/spherical_conventions.dart';

/// What to tell the user to do next, in the vocabulary the UI speaks.
///
/// An enum rather than a string so the copy lives in one place and can be
/// localised, and so the UI can pick an arrow direction without parsing prose.
enum GuidanceHint {
  /// Rotate right — yaw must decrease.
  turnRight,

  /// Rotate left — yaw must increase.
  turnLeft,

  /// Tilt up.
  tiltUp,

  /// Tilt down.
  tiltDown,

  /// Aim is good but the device is moving too fast to shoot.
  holdSteady,

  /// Aim and steadiness both satisfied; the dwell timer is running.
  onTarget,

  /// Pointing the right way, but rolled the wrong way about the optical axis.
  ///
  /// Only ever produced at the poles, and only for the second polar frame. The
  /// two zenith shots aim at the same direction and differ by a 90° roll
  /// (Math §8), so without this the shutter would fire twice on one view and
  /// the redundancy those two frames exist to provide would not exist.
  rollDevice,
}

/// Everything the capture UI needs to draw one frame, computed from one pose.
///
/// A value type, recomputed per pose sample rather than mutated, so the UI can
/// be a pure function of it and a widget test can drive any state directly.
class GuidanceState {
  /// Creates a guidance state.
  const GuidanceState({
    required this.angularErrorRadians,
    required this.targetScreenOffsetX,
    required this.targetScreenOffsetY,
    required this.hint,
    required this.withinAimTolerance,
    required this.steady,
    required this.dwellProgress,
    this.edgeArrowRadians,
    this.rollErrorRadians = 0,
    this.rollWithinTolerance = true,
  });

  /// Great-circle angle between where the camera points and the target.
  ///
  /// The angle between two **directions**, never a yaw error plus a pitch
  /// error. §7 pitfall 3: at the poles the yaw component of that decomposition
  /// is degenerate — every yaw names the same direction — so a decomposed error
  /// blows up exactly where the zenith and nadir shots live.
  final double angularErrorRadians;

  /// Where to draw the helper dot, x, in fractions of the preview's half-width
  /// from centre — `−1` is the left edge, `+1` the right. Kept as plain numbers
  /// rather than a `dart:ui` `Offset` so the guidance layer stays usable from
  /// the pure-Dart replay tooling.
  ///
  /// **`null` when the target is behind the camera**, where there is no
  /// projection and any number here would be a fabrication. That is the whole
  /// point: a dot clamped to the screen edge implies "nearly there" when the
  /// user has to turn 150°, which is the single most confusing thing a guided
  /// capture can show. Draw [edgeArrowRadians] instead.
  final double? targetScreenOffsetX;

  /// Where to draw the helper dot, y, in fractions of the preview's half-height
  /// from centre — `−1` is the top edge, `+1` the bottom. `null` under the same
  /// condition as [targetScreenOffsetX].
  final double? targetScreenOffsetY;

  /// The instruction to show.
  final GuidanceHint hint;

  /// Whether [angularErrorRadians] is inside
  /// [SphereCaptureConfig.aimToleranceRadians] — or inside whatever relaxed
  /// tolerance the caller passed to [GuidanceEngine.evaluate].
  ///
  /// Direction only. Roll is [rollWithinTolerance], because they fail for
  /// different reasons and the shutter gate treats them differently.
  final bool withinAimTolerance;

  /// Whether angular speed is under
  /// [SphereCaptureConfig.steadinessThresholdRadPerSec].
  final bool steady;

  /// How far through the dwell the user is, `0..1`. Drives the reticle fill,
  /// which is what makes the auto-shutter feel deliberate rather than random.
  final double dwellProgress;

  /// Where to draw the edge arrow, as a screen-space angle in radians: `0`
  /// points right, `+π/2` points **down** (screen y grows downward), `−π/2`
  /// points up.
  ///
  /// Non-null exactly when the target is off screen — behind the camera, or in
  /// front but outside the frame. `null` means the dot is on screen and there
  /// is nothing to point at.
  final double? edgeArrowRadians;

  /// Signed roll error about the optical axis: how far the top of the screen is
  /// from where this target wants it, positive anticlockwise as seen by the
  /// user looking at the scene.
  ///
  /// Reported for every target — Phase 09 shows "Level the tablet" past ~12° —
  /// but only *gated* at the poles, where it is the only thing distinguishing
  /// one frame from the other.
  final double rollErrorRadians;

  /// Whether [rollErrorRadians] is small enough to fire. Always `true` away
  /// from the poles, where roll is a quality nudge rather than a gate: a rolled
  /// frame is still stitchable, bundle adjustment handles it, and refusing to
  /// fire over it would stall the capture for no geometric gain.
  final bool rollWithinTolerance;

  /// Whether the target is behind the camera, i.e. there is no projection.
  bool get targetBehind => targetScreenOffsetX == null;

  /// Whether the dot cannot be drawn inside the preview.
  bool get targetOffScreen => edgeArrowRadians != null;

  /// Serialises, so a session can be replayed and its guidance decisions
  /// audited after the fact.
  Map<String, Object?> toJson() => {
    'angular_error_radians': angularErrorRadians,
    'target_screen_offset_x': targetScreenOffsetX,
    'target_screen_offset_y': targetScreenOffsetY,
    'hint': hint.name,
    'within_aim_tolerance': withinAimTolerance,
    'steady': steady,
    'dwell_progress': dwellProgress,
    'edge_arrow_radians': edgeArrowRadians,
    'roll_error_radians': rollErrorRadians,
    'roll_within_tolerance': rollWithinTolerance,
  };

  /// Inverse of [toJson].
  factory GuidanceState.fromJson(Map<String, Object?> json) {
    const ctx = 'GuidanceState';
    return GuidanceState(
      angularErrorRadians: jsonDouble(
        json,
        'angular_error_radians',
        context: ctx,
      ),
      targetScreenOffsetX: jsonDoubleOrNull(
        json,
        'target_screen_offset_x',
        context: ctx,
      ),
      targetScreenOffsetY: jsonDoubleOrNull(
        json,
        'target_screen_offset_y',
        context: ctx,
      ),
      hint: jsonEnum(json, 'hint', GuidanceHint.values, context: ctx),
      withinAimTolerance: jsonBool(json, 'within_aim_tolerance', context: ctx),
      steady: jsonBool(json, 'steady', context: ctx),
      dwellProgress: jsonDouble(json, 'dwell_progress', context: ctx),
      edgeArrowRadians: jsonDoubleOrNull(
        json,
        'edge_arrow_radians',
        context: ctx,
      ),
      rollErrorRadians: json.containsKey('roll_error_radians')
          ? jsonDouble(json, 'roll_error_radians', context: ctx)
          : 0.0,
      rollWithinTolerance: json.containsKey('roll_within_tolerance')
          ? jsonBool(json, 'roll_within_tolerance', context: ctx)
          : true,
    );
  }

  /// Returns a copy with selected fields replaced.
  ///
  /// Exists for one caller: the session recomputes [dwellProgress] *after*
  /// feeding the state to the shutter gate, because the gate is what owns the
  /// dwell clock. Threading it the other way would report a progress value one
  /// sample stale, which at 100 Hz is visible as a reticle that finishes
  /// filling after the shutter has already fired.
  GuidanceState copyWith({double? dwellProgress, GuidanceHint? hint}) =>
      GuidanceState(
        angularErrorRadians: angularErrorRadians,
        targetScreenOffsetX: targetScreenOffsetX,
        targetScreenOffsetY: targetScreenOffsetY,
        hint: hint ?? this.hint,
        withinAimTolerance: withinAimTolerance,
        steady: steady,
        dwellProgress: dwellProgress ?? this.dwellProgress,
        edgeArrowRadians: edgeArrowRadians,
        rollErrorRadians: rollErrorRadians,
        rollWithinTolerance: rollWithinTolerance,
      );

  @override
  bool operator ==(Object other) =>
      other is GuidanceState &&
      other.angularErrorRadians == angularErrorRadians &&
      other.targetScreenOffsetX == targetScreenOffsetX &&
      other.targetScreenOffsetY == targetScreenOffsetY &&
      other.hint == hint &&
      other.withinAimTolerance == withinAimTolerance &&
      other.steady == steady &&
      other.dwellProgress == dwellProgress &&
      other.edgeArrowRadians == edgeArrowRadians &&
      other.rollErrorRadians == rollErrorRadians &&
      other.rollWithinTolerance == rollWithinTolerance;

  @override
  int get hashCode => Object.hash(
    angularErrorRadians,
    targetScreenOffsetX,
    targetScreenOffsetY,
    hint,
    withinAimTolerance,
    steady,
    dwellProgress,
    edgeArrowRadians,
    rollErrorRadians,
    rollWithinTolerance,
  );

  @override
  String toString() =>
      'GuidanceState(${hint.name}, error: $angularErrorRadians rad, '
      'dwell: $dwellProgress)';
}

/// Turns "where you are versus where you should be" into an instruction.
///
/// Kept separate from the UI and from the shutter because the aim tolerance it
/// enforces is now 4° rather than the previous 10°. That tightening is only
/// tolerable if the *guidance* is good enough to get a handheld tablet inside
/// 4° without frustration — so this is the piece that has to earn the tighter
/// gate, and it needs to be testable on its own to prove it does.
///
/// A pure function with no state and no side effects. Every number it produces
/// comes from one pose, one target and the **measured** intrinsics; nothing is
/// smoothed, remembered or guessed. That is why the dot is geometrically
/// truthful: it sits where the target actually is in the preview, so "put the
/// dot in the ring" is a statement about the world rather than a metaphor. With
/// a guessed focal it would drift against the scene as the user turns, and the
/// interaction would feel broken in a way nobody can articulate — which is why
/// Phase 06 had to come first.
class GuidanceEngine {
  /// Creates a guidance engine.
  const GuidanceEngine();

  /// How far the tablet may be rolled at a polar target and still fire.
  ///
  /// Deliberately loose. The two polar frames are 90° apart, and the point of
  /// the second one is that the matcher sees a genuinely different view rather
  /// than a duplicate — not that the roll is precise. 25° separates the two
  /// unambiguously while leaving a handheld tablet plenty of room.
  static const double polarRollToleranceRadians = 25 * math.pi / 180;

  /// Computes the state for one pose against one target.
  ///
  /// [intrinsics] must be the ones the *preview* is in — the device-frame,
  /// portrait ones the plan was built from — because the dot is placed in
  /// preview coordinates.
  ///
  /// [aimToleranceRadians] overrides [SphereCaptureConfig.aimToleranceRadians],
  /// so the shutter gate's adaptive relaxation (§4) can widen the tolerance
  /// without the hint and the gate disagreeing about whether the user has
  /// arrived. [dwellProgress] is passed straight through for the UI.
  GuidanceState evaluate({
    required DevicePose pose,
    required CaptureTarget target,
    required SphereCaptureConfig config,
    CameraIntrinsics? intrinsics,
    double? aimToleranceRadians,
    double dwellProgress = 0,
  }) {
    // World→device: for a unit quaternion the conjugate is the inverse, and
    // `QuaternionUtils.rotate` is the active rotation matching
    // `asRotationMatrix` — never `Quaternion.rotated`, which applies the
    // transpose and would mirror every hint (see that method's doc).
    final worldToDevice = pose.deviceToWorld.conjugated();
    final rayDevice = QuaternionUtils.rotate(worldToDevice, target.direction);
    final length = rayDevice.length;
    // A zero-length pose quaternion cannot be inverted meaningfully; report the
    // worst possible aim rather than a NaN that would silently poison the gate.
    if (!length.isFinite || length < 1e-12) {
      return GuidanceState(
        angularErrorRadians: math.pi,
        targetScreenOffsetX: null,
        targetScreenOffsetY: null,
        hint: GuidanceHint.turnRight,
        withinAimTolerance: false,
        steady: false,
        dwellProgress: 0,
        edgeArrowRadians: 0,
      );
    }

    // The camera looks along −Z_d (Math §1.2), so the aim error is the angle
    // between the target ray and that axis. One `acos`, no decomposition.
    final angularError = math.acos(
      (-rayDevice.z / length).clamp(-1.0, 1.0),
    );

    // Screen axes: x right, y **down**, which is the convention every canvas
    // uses. The device frame has +Y up the screen, hence the negation.
    final screenX = rayDevice.x;
    final screenY = -rayDevice.y;

    final k = intrinsics ?? _fallbackIntrinsics;
    // One copy of this mapping, in `SphericalConventions`, because the overlay
    // needs the same thing for every other dot and every pinned thumbnail — and
    // a second copy is how a dot ends up somewhere the hint disagrees with. It
    // also applies the lens distortion, which this used to skip: on a wide phone
    // lens that is several degrees of error exactly at the frame edge, which is
    // where the next target usually sits.
    final offset = SphericalConventions.previewOffsetForWorldDirection(
      k: k,
      worldToDevice: worldToDevice,
      direction: target.direction,
    );
    final offsetX = offset?.x;
    final offsetY = offset?.y;
    final onScreen =
        offsetX != null &&
        offsetY != null &&
        offsetX.abs() <= 1 &&
        offsetY.abs() <= 1;

    double? arrow;
    if (!onScreen) {
      // Exactly behind: every screen direction is equally correct, so pick one
      // and stay on it rather than letting rounding spin the arrow.
      arrow = (screenX.abs() < 1e-12 && screenY.abs() < 1e-12)
          ? 0.0
          : math.atan2(screenY, screenX);
    }

    final rollError = _rollError(pose, target);
    final rollWithinTolerance =
        !target.isPole || rollError.abs() <= polarRollToleranceRadians;

    final tolerance = aimToleranceRadians ?? config.aimToleranceRadians;
    final withinAim = angularError <= tolerance;
    final steady =
        pose.angularSpeedRadPerSec < config.steadinessThresholdRadPerSec;

    final GuidanceHint hint;
    if (!withinAim) {
      // Pick the axis by what the user sees, not by yaw and pitch. The screen
      // projection is well behaved at the poles, where a yaw comparison is not,
      // and it is also the axis they will actually move along.
      if (screenX.abs() >= screenY.abs()) {
        hint = screenX >= 0 ? GuidanceHint.turnRight : GuidanceHint.turnLeft;
      } else {
        hint = screenY < 0 ? GuidanceHint.tiltUp : GuidanceHint.tiltDown;
      }
    } else if (!rollWithinTolerance) {
      hint = GuidanceHint.rollDevice;
    } else if (!steady) {
      hint = GuidanceHint.holdSteady;
    } else {
      hint = GuidanceHint.onTarget;
    }

    return GuidanceState(
      angularErrorRadians: angularError,
      targetScreenOffsetX: offsetX,
      targetScreenOffsetY: offsetY,
      hint: hint,
      withinAimTolerance: withinAim,
      steady: steady,
      dwellProgress: dwellProgress,
      edgeArrowRadians: arrow,
      rollErrorRadians: rollError,
      rollWithinTolerance: rollWithinTolerance,
    );
  }

  /// Signed angle about the target direction from the target's screen-up to the
  /// device's, measured with the right-hand rule about the direction the camera
  /// points.
  ///
  /// Both vectors are projected perpendicular to the target direction first, so
  /// this is a genuine roll and not contaminated by the aim error. When the
  /// device is aimed so badly that its screen-up is parallel to the target
  /// direction the projection vanishes and the roll is undefined — reported as
  /// zero, because at that point the user is being told to turn round anyway.
  static double _rollError(DevicePose pose, CaptureTarget target) {
    final f = target.direction;
    // Perpendicular to `f` by construction — see `SphericalConventions
    // .aimingDeviceToWorld`, whose `u` column is world up with the component
    // along `f` removed, written in closed form so it survives the poles.
    final targetUp = target.screenUp;
    final deviceUp = QuaternionUtils.rotate(
      pose.deviceToWorld,
      Vector3(0, 1, 0),
    );
    final projected = deviceUp - f * f.dot(deviceUp);
    if (projected.length2 < 1e-18) return 0;
    return math.atan2(targetUp.cross(projected).dot(f), targetUp.dot(projected));
  }

  /// Used only when a caller supplies no intrinsics, so the dot degrades to a
  /// plausible 60° field rather than throwing.
  ///
  /// Nothing in the shipping path uses it — `SphereCaptureSession` always
  /// passes the measured intrinsics, and the whole argument for this class is
  /// that a guessed focal makes the dot drift against the scene. It exists so a
  /// test or a tool can evaluate hints without constructing a camera model.
  static final CameraIntrinsics _fallbackIntrinsics =
      CameraIntrinsics.fromHorizontalFov(
        hfovRadians: 60 * math.pi / 180,
        imageSize: const ImageSize(1000, 1000),
        source: IntrinsicsSource.exifFallback,
      );
}
