import 'package:flutter/foundation.dart';

import '../../plan/models/plan_marker.dart';

/// Item states. Four are drawn on the upload queue; `paused` is the state the
/// drawn pause button must lead to — ASSUMPTIONS.md §H4.
enum UploadStatus { uploading, waiting, paused, failed, uploaded }

/// One capture waiting to reach Asite.
///
/// "Everything captured sits here until it lands. Each item shows size,
/// duration, progress and — when it fails — why, with a retry countdown rather
/// than a dead end."
@immutable
class UploadItem {
  const UploadItem({
    required this.id,
    required this.name,
    required this.calibrationId,
    required this.mode,
    required this.sizeBytes,
    required this.status,
    this.duration,
    this.progress = 0,
    this.failureReason,
    this.retryInSeconds,
  });

  final String id;

  /// `L03_Walk_2026-07-02_03` — why captures are named before they start.
  final String name;

  final String calibrationId;
  final CaptureMode mode;
  final int sizeBytes;
  final UploadStatus status;

  /// Video walks show "11:24" beside their size.
  final Duration? duration;

  /// 0.0–1.0.
  final double progress;

  /// "Connection dropped at 62%".
  final String? failureReason;

  /// "Auto-retry in 18s".
  final int? retryInSeconds;

  bool get isOutstanding => status != UploadStatus.uploaded;

  UploadItem copyWith({
    UploadStatus? status,
    double? progress,
    String? failureReason,
    int? retryInSeconds,
    bool clearFailure = false,
  }) {
    return UploadItem(
      id: id,
      name: name,
      calibrationId: calibrationId,
      mode: mode,
      sizeBytes: sizeBytes,
      status: status ?? this.status,
      duration: duration,
      progress: progress ?? this.progress,
      failureReason: clearFailure ? null : (failureReason ?? this.failureReason),
      retryInSeconds:
          clearFailure ? null : (retryInSeconds ?? this.retryInSeconds),
    );
  }
}
