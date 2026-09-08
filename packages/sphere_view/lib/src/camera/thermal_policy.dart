import 'camera_platform.dart';

/// What to do about the device getting hot.
///
/// Phase 06 §5 states the policy in one sentence — warn at `serious`, refuse a
/// stitch at `critical` — and architecture §8 states the principle it comes
/// from: **never silently degrade**. This file is where the policy lives so
/// that the capture UI, the stitch queue and the report all answer the question
/// the same way, and so that changing the answer is one edit rather than three.
///
/// The load is real and not hypothetical. An 87-frame bracketed capture
/// followed by a 60 s multi-band blend is sustained work on a tablet that may
/// be in direct sun on a site. Thermal throttling does not fail; it makes the
/// output quietly worse and the stitch quietly slower, which is exactly the
/// class of degradation the architecture refuses to ship.
enum ThermalAction {
  /// Carry on.
  proceed,

  /// Carry on, but tell the user. Nothing is refused at this level.
  warn,

  /// Do not start. Something already running may finish or pause; nothing new
  /// begins.
  refuse,
}

/// The decision for one thermal state, with the sentence to show for it.
class ThermalDecision {
  /// Creates a decision.
  const ThermalDecision({
    required this.state,
    required this.action,
    required this.message,
  });

  /// The state it was made for.
  final ThermalState state;

  /// What to do.
  final ThermalAction action;

  /// Plain-language explanation, written to be shown to a construction manager
  /// on a site rather than to a developer in a log.
  final String message;

  /// Whether this decision permits the activity.
  bool get allowed => action != ThermalAction.refuse;

  @override
  String toString() => 'ThermalDecision(${state.name} → ${action.name})';
}

/// The two decisions the pipeline needs, kept together so they cannot drift.
abstract final class ThermalPolicy {
  /// Whether to begin — or continue — a capture session.
  ///
  /// Capture is more permissive than stitching because it is short, because
  /// abandoning a half-captured sphere wastes the user's walk, and because the
  /// frames themselves are not degraded by throttling — only the frame rate
  /// is. At `critical` it still stops: the device is protecting itself and the
  /// next thing it does is throttle the camera, which shows up as motion blur.
  static ThermalDecision forCapture(ThermalState state) => switch (state) {
    ThermalState.nominal => const ThermalDecision(
      state: ThermalState.nominal,
      action: ThermalAction.proceed,
      message: 'Device temperature is normal.',
    ),
    ThermalState.fair => const ThermalDecision(
      state: ThermalState.fair,
      action: ThermalAction.proceed,
      message: 'The device is warm. Capture is unaffected.',
    ),
    ThermalState.serious => const ThermalDecision(
      state: ThermalState.serious,
      action: ThermalAction.warn,
      message:
          'The device is hot. Capture will still work, but stitching now '
          'would be slow — leave the panoramas to process later, or move out '
          'of direct sun.',
    ),
    ThermalState.critical => const ThermalDecision(
      state: ThermalState.critical,
      action: ThermalAction.refuse,
      message:
          'The device is too hot to capture. It has begun limiting the camera, '
          'which would blur the frames. Let it cool for a few minutes.',
    ),
  };

  /// Whether to begin a stitch **from the background queue**.
  ///
  /// Stricter again than [forStitch], and the difference is who is waiting.
  /// [forStitch] answers "the user asked for this one, now" — at `serious` it
  /// warns and proceeds, because refusing work somebody is standing there
  /// waiting for is worse than doing it slowly. The queue is the opposite
  /// case: nobody is waiting, the bundle is on disk and replayable, and the
  /// whole point of queueing was to run the work *when convenient*. A hot
  /// device is the definition of inconvenient, and starting anyway would push
  /// it toward `critical`, where capture itself gets refused — so the queue
  /// would be taking the camera away from the manager to process a panorama
  /// nobody needed yet.
  ///
  /// This is Phase 10 §5's "skip when `thermalState >= serious`", and it is
  /// deliberately a *different* function rather than a change to [forStitch],
  /// because both answers are right for their own caller.
  static ThermalDecision forBackgroundStitch(ThermalState state) =>
      switch (state) {
        ThermalState.nominal || ThermalState.fair => forStitch(state),
        ThermalState.serious => const ThermalDecision(
          state: ThermalState.serious,
          action: ThermalAction.refuse,
          message:
              'The device is hot, so queued panoramas are waiting rather than '
              'processing. They will finish on their own once it cools.',
        ),
        ThermalState.critical => forStitch(state),
      };

  /// Whether to begin a stitch the user asked for.
  ///
  /// Stricter than [forCapture]: a stitch is 60 s of sustained CPU and ~600 MB
  /// of allocation, it is the thing that will *cause* the next thermal step,
  /// and it can always be run later without losing anything — the bundle is on
  /// disk and replayable (architecture §6.6). There is no reason to start one
  /// on a hot device.
  static ThermalDecision forStitch(ThermalState state) => switch (state) {
    ThermalState.nominal => const ThermalDecision(
      state: ThermalState.nominal,
      action: ThermalAction.proceed,
      message: 'Device temperature is normal.',
    ),
    ThermalState.fair => const ThermalDecision(
      state: ThermalState.fair,
      action: ThermalAction.proceed,
      message: 'The device is warm. Stitching may take a little longer.',
    ),
    ThermalState.serious => const ThermalDecision(
      state: ThermalState.serious,
      action: ThermalAction.warn,
      message:
          'The device is hot, so this stitch will be slower than usual. '
          'Captured panoramas are saved and can be processed later.',
    ),
    ThermalState.critical => const ThermalDecision(
      state: ThermalState.critical,
      action: ThermalAction.refuse,
      message:
          'The device is too hot to stitch. Your captures are saved and will '
          'be processed once it cools down.',
    ),
  };
}
