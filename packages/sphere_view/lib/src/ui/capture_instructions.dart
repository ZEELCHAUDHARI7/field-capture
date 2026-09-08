import 'dart:math' as math;

import '../api/sphere_capture_session.dart';
import '../guidance/guidance_engine.dart';
import '../plan/capture_plan.dart';

/// The one line of text the capture screen is allowed to show, chosen from the
/// session state.
///
/// A pure function, deliberately, and deliberately *outside* the widget: Phase
/// 09 §5 says `SphereCaptureView` makes no decisions, and "which sentence is on
/// screen" is the only judgement the screen would otherwise be tempted to make
/// in a build method. Here it is a value the widget renders and a test can
/// enumerate.
///
/// It answers with **one** line or none. Two instructions at once is the failure
/// this whole phase is arranged against: the user is holding a tablet at arm's
/// length in the sun with their attention on a live site, and a second line
/// costs more than the information in it is worth.
class CaptureInstructions {
  const CaptureInstructions._();

  /// Roll past which the tablet is worth levelling, in degrees (§2).
  ///
  /// A nudge, never a gate — bundle adjustment handles a rolled frame perfectly
  /// well. What a roll costs is *coverage margin*: the plan's ring spacing is
  /// `v·(1−ω)` for a frame held upright, and a frame rolled by `θ` presents only
  /// `v·cos θ + h·|sin θ|` of usable vertical extent against the ring above it.
  /// At 12° on a 50°×69° frame that is about 2° of margin gone, which is the
  /// point at which saying something is worth the interruption.
  static const double levelHintThresholdDegrees = 12;

  /// Text for each directional hint. Two words, imperative, no punctuation —
  /// read at a glance from arm's length rather than parsed.
  static const Map<GuidanceHint, String> hintText = {
    GuidanceHint.turnRight: 'Turn right',
    GuidanceHint.turnLeft: 'Turn left',
    GuidanceHint.tiltUp: 'Tilt up',
    GuidanceHint.tiltDown: 'Tilt down',
    GuidanceHint.holdSteady: 'Hold steady',
    // Nothing at all: the ring is filling, and that *is* the feedback (§2).
    GuidanceHint.onTarget: '',
    // The second polar frame is the same direction rolled 90° (Math §8), so
    // there is no direction to give — only a quarter turn of the tablet itself.
    GuidanceHint.rollDevice: 'Turn the tablet sideways',
  };

  /// Shown when the tablet is rolled past [levelHintThresholdDegrees].
  static const String levelText = 'Level the tablet';

  /// Shown entering a new ring, where the user has to be told the row moved
  /// rather than just which way to lean.
  static const String nowTiltUpText = 'Now tilt up';

  /// See [nowTiltUpText].
  static const String nowTiltDownText = 'Now tilt down';

  /// Shown while the metering pre-sweep runs (§3.2).
  static const String meteringText = 'Turn slowly all the way around once';

  /// The line to display for [state], or `null` to show nothing.
  ///
  /// [plan] is needed only to recognise a ring transition: a target that opens a
  /// ring is the first target whose row differs from the one before it in
  /// shooting order, and that is a fact about the plan rather than about the
  /// pose.
  ///
  /// ### The order of precedence, and why it is this one
  ///
  /// 1. **[SessionState.message]** — a rejection, a relaxed-tolerance capture, a
  ///    thermal pause, a camera error. These are already plain language from
  ///    Phase 08 (`FrameRejection.message` is literally "Too blurry — hold
  ///    still"), they are transient, and each one describes something that has
  ///    *just gone wrong*. Nothing about where to aim outranks that.
  /// 2. **A ring transition**, when the user is not yet on target. "Now tilt up"
  ///    says the row moved; "Tilt up" alone reads as a small correction, and at
  ///    a ring boundary it is not one.
  /// 3. **The directional hint**, whose axis the guidance engine already chose
  ///    from what the user sees on screen rather than from yaw and pitch — which
  ///    is what keeps it sane at the poles.
  /// 4. **The roll nudge**, only once aiming is otherwise satisfied. While the
  ///    user is still turning 90° the roll is noise; the moment they arrive it
  ///    is the one thing left to fix.
  /// 5. **Hold steady**, then silence.
  static String? forState(SessionState state, {CapturePlan? plan}) {
    final message = state.message;
    if (message != null && message.isNotEmpty) return message;

    if (state.phase == SessionPhase.metering) return meteringText;

    final guidance = state.guidance;
    if (guidance == null) return null;

    if (!guidance.withinAimTolerance) {
      final transition = _ringTransition(state.currentTarget, plan);
      if (transition != null &&
          (guidance.hint == GuidanceHint.tiltUp ||
              guidance.hint == GuidanceHint.tiltDown)) {
        return transition;
      }
      return hintText[guidance.hint];
    }

    if (guidance.hint == GuidanceHint.rollDevice) {
      return hintText[GuidanceHint.rollDevice];
    }
    if (guidance.rollErrorRadians.abs() >
        levelHintThresholdDegrees * math.pi / 180) {
      return levelText;
    }

    final text = hintText[guidance.hint];
    return (text == null || text.isEmpty) ? null : text;
  }

  /// "Now tilt up" / "Now tilt down" when [target] opens a new ring, else
  /// `null`.
  ///
  /// The direction comes from the *previous target in shooting order*, not from
  /// the ring index: Phase 08's order climbs to the zenith and then comes back
  /// down through the lower rings, so ring index alone would tell half the
  /// session to tilt the wrong way.
  static String? _ringTransition(CaptureTarget? target, CapturePlan? plan) {
    if (target == null || plan == null) return null;
    if (target.indexInRing != 0 || target.index <= 0) return null;
    if (target.index >= plan.targets.length) return null;
    final previous = plan.targets[target.index - 1];
    if (previous.ringIndex == target.ringIndex) return null;
    if (target.pitch == previous.pitch) return null;
    return target.pitch > previous.pitch ? nowTiltUpText : nowTiltDownText;
  }
}
