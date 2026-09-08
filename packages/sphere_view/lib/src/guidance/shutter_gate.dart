import 'dart:math' as math;

import '../api/models/sphere_capture_config.dart';
import 'guidance_engine.dart';

/// Decides the single question the capture loop asks 60 times a second: fire
/// now, or not yet?
///
/// It is `aim ∧ steady ∧ dwell`, and it is a separate object from the guidance
/// engine because the three conditions have different failure consequences and
/// the gate is where they are traded off. Aim protects the coverage proof;
/// steadiness protects against rolling-shutter skew, which registration cannot
/// undo; dwell protects against firing during a wobble that happens to pass
/// through the target. Firing early is not a small error — it produces a frame
/// that looks fine and registers badly.
///
/// All three are much tighter than the previous implementation's (4° against
/// 10°, 0.12 rad/s against 0.25). Those old values were not a considered choice:
/// the old pipeline had no way to fix residual error, so a rejected frame was
/// pure cost and loose gates were the only way to make progress at all. The new
/// pipeline wants good bundle-adjustment seeds and sharp frames, and can afford
/// to ask for them.
///
/// ### Which gate may be relaxed, and which may never be
///
/// Aim may (§4). A seed that is 7° out is a worse seed than one 4° out, and
/// bundle adjustment absorbs the difference; a gate the user physically cannot
/// satisfy is worse than a slightly worse seed, and a stuck capture flow is the
/// fastest way to lose their trust in the feature.
///
/// Steadiness and sharpness may **not**, ever. They do not degrade a frame,
/// they destroy it: motion blur removes detail no operator can put back, and
/// rolling-shutter skew is a per-row geometric distortion that no single
/// rotation can undo. A frame that fails either damages the stitch rather than
/// merely weakening it, so relaxing them would trade a stalled capture for a
/// ruined one.
class ShutterGate {
  /// Creates a gate for [config].
  ShutterGate(
    this.config, {
    this.relaxAfter = defaultRelaxAfter,
    this.relaxStep = defaultRelaxStep,
    this.relaxedAimToleranceDegrees = defaultRelaxedAimToleranceDegrees,
  });

  /// How long a single target may resist before the aim tolerance starts to
  /// widen (§4's "~8 s").
  static const Duration defaultRelaxAfter = Duration(seconds: 8);

  /// How long each further step of relaxation takes. Three steps of one degree
  /// every two seconds reach the ceiling at 12 s — slow enough that a user who
  /// is nearly there gets no help they did not need, fast enough that a user
  /// who is stuck is not left there.
  static const Duration defaultRelaxStep = Duration(seconds: 2);

  /// The ceiling the aim tolerance relaxes toward, never past (§4's 7°).
  static const double defaultRelaxedAimToleranceDegrees = 7.0;

  /// The thresholds and dwell duration in force.
  final SphereCaptureConfig config;

  /// Delay before the first relaxation step.
  final Duration relaxAfter;

  /// Interval between relaxation steps.
  final Duration relaxStep;

  /// The relaxed ceiling in degrees.
  final double relaxedAimToleranceDegrees;

  /// How many steps the tolerance widens in.
  static const int relaxSteps = 3;

  int? _armedAtUs;
  int? _satisfiedSinceUs;
  int? _lastUs;
  bool _fired = false;
  bool _firedRelaxed = false;

  /// The aim tolerance in force at [nowUs], in radians.
  ///
  /// Equal to [SphereCaptureConfig.aimToleranceRadians] until the current
  /// target has resisted for [relaxAfter], then widening one step at a time
  /// toward [relaxedAimToleranceDegrees]. The clock starts at the first
  /// [update] after a [reset], i.e. when the target became the one being aimed
  /// at — not at session start, so a slow first target does not spend the
  /// allowance of every target after it.
  double aimToleranceRadiansAt(int nowUs) {
    final armed = _armedAtUs;
    final base = config.aimToleranceDegrees;
    final ceiling = math.max(base, relaxedAimToleranceDegrees);
    if (armed == null || ceiling <= base) return base * math.pi / 180;
    final elapsedUs = nowUs - armed;
    if (elapsedUs < relaxAfter.inMicroseconds) return base * math.pi / 180;
    final stepUs = math.max(1, relaxStep.inMicroseconds);
    final steps = math.min(
      relaxSteps,
      1 + (elapsedUs - relaxAfter.inMicroseconds) ~/ stepUs,
    );
    final degrees = base + (ceiling - base) * steps / relaxSteps;
    return degrees * math.pi / 180;
  }

  /// Whether the tolerance at [nowUs] has been widened past the configured one.
  bool isRelaxedAt(int nowUs) =>
      aimToleranceRadiansAt(nowUs) > config.aimToleranceRadians + 1e-12;

  /// Whether the shot this gate last allowed was taken under a relaxed
  /// tolerance — the "close enough — capturing" case the user is told about.
  ///
  /// §4 asks for it to be *said*, not just done. A capture that silently
  /// accepts a worse aim is a compromise, and architecture §8's rule is that no
  /// compromise is silent.
  bool get firedUnderRelaxedAim => _firedRelaxed;

  /// Fraction of the dwell elapsed, `0..1`, for the reticle fill.
  double get dwellProgress {
    final since = _satisfiedSinceUs;
    final now = _lastUs;
    if (since == null || now == null) return 0;
    final dwellUs = config.dwell.inMicroseconds;
    if (dwellUs <= 0) return 1;
    return ((now - since) / dwellUs).clamp(0.0, 1.0);
  }

  /// Whether the dwell timer is running, i.e. aim and steadiness both hold.
  bool get isDwelling => _satisfiedSinceUs != null;

  /// Feeds one guidance sample in at [nowUs] and returns whether the shutter
  /// should fire.
  ///
  /// Stateful by necessity: dwell is a duration, so the gate has to remember
  /// when the conditions were first satisfied, and has to reset the moment
  /// either stops holding.
  ///
  /// Returns `true` exactly once per target — on the sample that completes the
  /// dwell — and then stays `false` until [reset]. A gate that kept returning
  /// `true` while the user held still would fire a second bracket into the
  /// same position while the first was still being written.
  ///
  /// The aim condition is re-tested here against [aimToleranceRadiansAt] rather
  /// than taken from [GuidanceState.withinAimTolerance], so the relaxation
  /// holds even when the caller evaluated guidance at the strict tolerance.
  /// Steadiness and roll are taken as given: the gate has no way to recompute
  /// them and no business relaxing them.
  bool update(GuidanceState state, int nowUs) {
    _lastUs = nowUs;
    _armedAtUs ??= nowUs;
    if (_fired) return false;

    final aimed = state.angularErrorRadians <= aimToleranceRadiansAt(nowUs);
    if (!aimed || !state.steady || !state.rollWithinTolerance) {
      _satisfiedSinceUs = null;
      return false;
    }

    final since = _satisfiedSinceUs ??= nowUs;
    if (nowUs - since < config.dwell.inMicroseconds) return false;

    _fired = true;
    _firedRelaxed = isRelaxedAt(nowUs);
    return true;
  }

  /// Clears the dwell timer and the relaxation clock, e.g. after firing or on
  /// moving to a new target.
  void reset() {
    _armedAtUs = null;
    _satisfiedSinceUs = null;
    _lastUs = null;
    _fired = false;
    _firedRelaxed = false;
  }

  @override
  String toString() =>
      'ShutterGate(dwell ${(dwellProgress * 100).round()}%'
      '${_fired ? ', fired' : ''})';
}
