import 'dart:ffi';

import '../api/models/stitch_progress.dart';
import 'native_stitcher.dart';

/// Turns the shared-memory `(stage, permille)` pair into the single monotone
/// fraction a progress bar needs.
///
/// The two halves of the ABI deliberately answer different questions.
/// `SvProgress.permille` is progress *within* a stage, because that is the only
/// thing C++ can state honestly — it knows it is warping frame 12 of 34, not
/// what share of the remaining minute that is. `StitchProgress.fraction` is
/// overall, because a bar that restarts at zero eleven times is not a progress
/// bar. This class is where the one becomes the other, and it lives in Dart
/// because the weights are a product judgement that will be re-measured, not a
/// property of the pipeline.
///
/// Two properties are guaranteed and both are tested:
///
/// * **Monotone.** The fraction never decreases, whatever the poller reads.
/// * **Reaches 1.0.** The last stage's weight is spent by the time encoding
///   reports 1000, so a completed stitch does not stop at 97%.
class StitchProgressMapper {
  /// Creates a mapper. One per stitch — it carries the high-water mark.
  StitchProgressMapper();

  /// Per-stage share of the total, in thousandths, summing to exactly 1000.
  ///
  /// Measured rather than guessed, from two runs on `nominal`:
  ///
  /// * the desktop host at `high` tier gives the non-fusion split — warp 3977
  ///   ms, blend 2724, adjust 2402, match 2332, features 769, poles 670, seam
  ///   624, encode 153, undistort 33, compensate 15;
  /// * `testFusionMeetsItsBudgetAtCaptureResolution` gives fusion at capture
  ///   resolution, which the synthetic bundles are far too small to show: 841
  ///   ms per 12 MP position, ~24 s for 29, against S8's 60 s budget.
  ///
  /// So fusion is ~40% of a real stitch and the desktop proportions carry the
  /// other 60%. The numbers are approximate on purpose — they decide how fast a
  /// bar moves, not what it reports — but they are approximations of something
  /// measured, which is why a stitch does not sit at 8% for half a minute.
  static const Map<StitchStage, int> stageWeightsPermille = {
    StitchStage.fusing: 400,
    StitchStage.undistorting: 2,
    StitchStage.findingFeatures: 34,
    StitchStage.matching: 102,
    StitchStage.adjusting: 105,
    StitchStage.warping: 174,
    StitchStage.compensating: 2,
    StitchStage.seaming: 27,
    StitchStage.blending: 119,
    StitchStage.fillingPoles: 29,
    StitchStage.encoding: 6,
  };

  /// What each stage is doing, in words a construction manager can read.
  ///
  /// The stage enum exists because "47%" is indistinguishable from a hung
  /// process; these sentences are what make that distinction visible to
  /// somebody who does not know what a bundle adjustment is.
  static const Map<StitchStage, String> stageMessages = {
    StitchStage.fusing: 'Combining the bracketed exposures',
    StitchStage.undistorting: 'Correcting the lens',
    StitchStage.findingFeatures: 'Finding detail to match on',
    StitchStage.matching: 'Matching overlapping frames',
    StitchStage.adjusting: 'Solving the camera orientations',
    StitchStage.warping: 'Projecting onto the sphere',
    StitchStage.compensating: 'Evening out the brightness',
    StitchStage.seaming: 'Routing the seams',
    StitchStage.blending: 'Blending',
    StitchStage.fillingPoles: 'Filling the top and bottom',
    StitchStage.encoding: 'Saving the panorama',
  };

  /// Cumulative weight of every stage *before* the keyed one, in thousandths.
  static final Map<StitchStage, int> _offsets = _buildOffsets();

  static Map<StitchStage, int> _buildOffsets() {
    final offsets = <StitchStage, int>{};
    var running = 0;
    for (final stage in StitchStage.values) {
      offsets[stage] = running;
      running += stageWeightsPermille[stage] ?? 0;
    }
    assert(
      running == 1000,
      'stage weights must sum to 1000, they sum to $running',
    );
    return offsets;
  }

  int _highWaterPermille = 0;

  /// The overall fraction for `(stage, permille)`, never below the last one
  /// returned.
  ///
  /// Clamped rather than trusted because the poller reads two `int32`s that
  /// C++ writes independently: it can catch a new stage paired with the
  /// previous stage's `permille`. Forward over-reads are bounded by one stage's
  /// weight and correct themselves within 100 ms; a *backwards* jump is the one
  /// a user would notice, so it simply cannot happen here.
  double fractionFor(StitchStage stage, int permille) {
    final offset = _offsets[stage] ?? 0;
    final weight = stageWeightsPermille[stage] ?? 0;
    final clamped = permille.clamp(0, 1000);
    final overall = offset + (weight * clamped) ~/ 1000;
    if (overall > _highWaterPermille) _highWaterPermille = overall;
    return _highWaterPermille / 1000.0;
  }

  /// Reads [pointer] and builds the tick to hand the UI.
  ///
  /// The two loads are checked against each other on purpose. `stage` and
  /// `permille` are written by C++ as separate stores with nothing ordering
  /// them, so reading them naively can pair a new stage with the old stage's
  /// count — at a stage boundary that is `permille = 1000`, which would show a
  /// stage as finished the instant it began. Re-reading `stage` afterwards and
  /// treating a change as "this stage has just started" costs one load and
  /// removes the artefact entirely.
  StitchProgress read(Pointer<SvProgress> pointer) {
    final first = pointer.ref.stage;
    final permille = pointer.ref.permille;
    final second = pointer.ref.stage;
    final stage = _stageFor(second);
    return StitchProgress(
      stage: stage,
      fraction: fractionFor(stage, first == second ? permille : 0),
      message: stageMessages[stage],
    );
  }

  /// The tick that says the stitch is finished.
  ///
  /// Emitted by the stitcher after the native call returns rather than read out
  /// of shared memory, because the last thing C++ writes is `encoding` at 1000
  /// and there is no twelfth stage to move to. Without this a successful stitch
  /// would leave the bar a hair short of full, which reads as a failure.
  StitchProgress get completed {
    _highWaterPermille = 1000;
    return const StitchProgress(
      stage: StitchStage.encoding,
      fraction: 1.0,
      message: 'Done',
    );
  }

  /// Maps a raw ordinal, defensively.
  ///
  /// An out-of-range value means the native build and this one disagree about
  /// the stage list — the ABI hazard the enum's doc comment warns about. It
  /// clamps rather than throws: a progress tick is not worth failing a stitch
  /// that is otherwise working, and the mismatch will show up loudly in the
  /// report's `sv_version` instead.
  static StitchStage _stageFor(int ordinal) =>
      StitchStage.values[ordinal.clamp(0, StitchStage.values.length - 1)];
}
