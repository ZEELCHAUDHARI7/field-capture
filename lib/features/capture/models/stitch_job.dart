import 'package:flutter/foundation.dart';
import 'package:sphere_view/sphere_view.dart';

/// One capture's progress through the stitch queue, as the UI needs to read it.
///
/// A projection of [StitchQueueEvent] rather than a wrapper: the queue reports
/// events, and a card over the plan needs the latest state per session. The
/// name is carried here because the queue only knows session ids, and
/// "L03_Mobile_2026-09-08_14" is what the crew called it.
@immutable
class StitchJob {
  const StitchJob({
    required this.sessionId,
    required this.captureName,
    required this.calibrationId,
    this.stage,
    this.fraction = 0,
    this.message,
    this.previewReady = false,
    this.done = false,
    this.error,
    this.pauseReason,
  });

  final String sessionId;
  final String captureName;
  final String calibrationId;

  /// Which pipeline stage is running.
  ///
  /// Shown rather than only the percentage because a 60-second stitch that says
  /// "47%" is indistinguishable from a hung one — the package's own reason for
  /// making this an enum.
  final StitchStage? stage;

  /// Overall completion, `0.0..1.0`. Monotone by construction: the package maps
  /// per-stage progress onto a single weighted total, so a bar driven by this
  /// never goes backwards.
  final double fraction;

  /// The package's plain-language line for [stage].
  final String? message;

  /// The 2048 px preview has landed. There is something to look at from here
  /// on, whatever happens to the full-resolution pass.
  final bool previewReady;

  final bool done;

  /// Set when the stitch failed after its attempt budget. The bundle is still
  /// on disk, so a retry is a real option rather than a hope.
  final String? error;

  /// Set while the queue is holding off — usually because the device is hot.
  final String? pauseReason;

  bool get isFailed => error != null;
  bool get isPaused => pauseReason != null;

  /// Still worth showing a card for.
  bool get isActive => !done;

  StitchJob copyWith({
    StitchStage? stage,
    double? fraction,
    String? message,
    bool? previewReady,
    bool? done,
    String? error,
    String? pauseReason,
    bool clearPauseReason = false,
    bool clearError = false,
  }) {
    return StitchJob(
      sessionId: sessionId,
      captureName: captureName,
      calibrationId: calibrationId,
      stage: stage ?? this.stage,
      fraction: fraction ?? this.fraction,
      message: message ?? this.message,
      previewReady: previewReady ?? this.previewReady,
      done: done ?? this.done,
      error: clearError ? null : (error ?? this.error),
      pauseReason:
          clearPauseReason ? null : (pauseReason ?? this.pauseReason),
    );
  }

  /// What the card says on its second line.
  String get statusLine {
    if (error != null) return 'Stitch failed — $error';
    if (pauseReason != null) return pauseReason!;
    if (message != null) return message!;
    return 'Queued';
  }
}
