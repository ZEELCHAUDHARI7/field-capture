import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../plan/models/plan_marker.dart';
import '../models/upload_item.dart';

/// The upload queue.
///
/// Phase 3 needs this because a saved capture has to land somewhere and the
/// header badge has to be truthful. The queue *screen* is Phase 4 — this is
/// the store behind it, seeded with the four items the prototype draws on
/// page 20, which is also why the badge reads 3: three of the four are still
/// outstanding.
class UploadQueueController extends Notifier<List<UploadItem>> {
  @override
  List<UploadItem> build() => _seed;

  static const List<UploadItem> _seed = <UploadItem>[
    UploadItem(
      id: 'up-1',
      name: 'L03_Walk_2026-07-02_03',
      calibrationId: 'prj-4821-l03',
      mode: CaptureMode.video,
      sizeBytes: 412 * 1000 * 1000,
      duration: Duration(minutes: 11, seconds: 24),
      status: UploadStatus.uploading,
      progress: 0.34,
    ),
    UploadItem(
      id: 'up-2',
      name: 'L03_Img_2026-07-02_11',
      calibrationId: 'prj-4821-l03',
      mode: CaptureMode.image,
      sizeBytes: 28 * 1000 * 1000,
      status: UploadStatus.waiting,
    ),
    UploadItem(
      id: 'up-3',
      name: 'B1_Walk_2026-07-01_02',
      calibrationId: 'prj-4821-b1',
      mode: CaptureMode.video,
      sizeBytes: 380 * 1000 * 1000,
      duration: Duration(minutes: 9, seconds: 41),
      status: UploadStatus.failed,
      progress: 0.62,
      failureReason: 'Connection dropped at 62%',
      retryInSeconds: 18,
    ),
    UploadItem(
      id: 'up-4',
      name: 'L03_Mobile_2026-07-01_05',
      calibrationId: 'prj-4821-l03',
      mode: CaptureMode.mobile,
      sizeBytes: 46 * 1000 * 1000,
      status: UploadStatus.uploaded,
      progress: 1,
    ),
  ];

  /// Pause an item that is uploading or waiting.
  void pause(String id) => _patch(id, (UploadItem i) {
        if (i.status == UploadStatus.uploading ||
            i.status == UploadStatus.waiting) {
          return i.copyWith(status: UploadStatus.paused);
        }
        return i;
      });

  void resume(String id) => _patch(id, (UploadItem i) =>
      i.status == UploadStatus.paused
          ? i.copyWith(status: UploadStatus.waiting)
          : i);

  /// "Retry now" on a failed item. "Failed items keep their bytes and resume
  /// from the last good offset" — so progress is preserved, not reset.
  void retry(String id) => _patch(id, (UploadItem i) =>
      i.status == UploadStatus.failed
          ? i.copyWith(status: UploadStatus.uploading, clearFailure: true)
          : i);

  /// Demo hook — drops whichever item is in flight, so the failed row with its
  /// reason and retry countdown can be reached on demand instead of only from
  /// the seed. Removed when real uploads land.
  void simulateFailure() {
    for (final UploadItem item in state) {
      if (item.status == UploadStatus.uploading ||
          item.status == UploadStatus.waiting) {
        _patch(
          item.id,
          (UploadItem i) => i.copyWith(
            status: UploadStatus.failed,
            failureReason:
                'Connection dropped at ${(i.progress * 100).round()}%',
            retryInSeconds: 18,
          ),
        );
        return;
      }
    }
  }

  void _patch(String id, UploadItem Function(UploadItem) update) {
    state = <UploadItem>[
      for (final UploadItem item in state)
        if (item.id == id) update(item) else item,
    ];
  }

  /// Called the moment a capture is saved. New items join as `waiting`;
  /// nothing starts uploading until the queue reaches them, and the Wi-Fi-only
  /// policy is honoured in Phase 4.
  void enqueue({
    required String name,
    required String calibrationId,
    required CaptureMode mode,
    required int sizeBytes,
    Duration? duration,
  }) {
    state = <UploadItem>[
      UploadItem(
        id: 'up-${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        calibrationId: calibrationId,
        mode: mode,
        sizeBytes: sizeBytes,
        duration: duration,
        status: UploadStatus.waiting,
      ),
      ...state,
    ];
  }
}

final uploadQueueProvider =
    NotifierProvider<UploadQueueController, List<UploadItem>>(
  UploadQueueController.new,
);

/// The red count on the header button — everything not yet landed.
final pendingUploadCountProvider = Provider<int>((ref) {
  return ref
      .watch(uploadQueueProvider)
      .where((UploadItem item) => item.isOutstanding)
      .length;
});

/// The figures on the queue's summary card.
///
/// Every number here is derived, not stored, and each one reproduces what the
/// prototype prints on page 19 from the same four items — which is what
/// `test/upload_queue_test.dart` asserts.
@immutable
class UploadSummary {
  const UploadSummary({
    required this.completed,
    required this.total,
    required this.progress,
    required this.remainingBytes,
  });

  final int completed;
  final int total;

  /// 0.0-1.0 across all bytes in the queue.
  final double progress;

  final int remainingBytes;

  /// "Uploading 2 of 4" — the item being worked on, counting from the ones
  /// already done.
  int get position => completed >= total ? total : completed + 1;

  bool get isIdle => completed >= total;
}

final uploadSummaryProvider = Provider<UploadSummary>((ref) {
  final List<UploadItem> items = ref.watch(uploadQueueProvider);
  if (items.isEmpty) {
    return const UploadSummary(
      completed: 0,
      total: 0,
      progress: 0,
      remainingBytes: 0,
    );
  }

  int totalBytes = 0;
  int remaining = 0;
  int completed = 0;

  for (final UploadItem item in items) {
    totalBytes += item.sizeBytes;
    if (item.status == UploadStatus.uploaded) {
      completed++;
    } else {
      remaining += (item.sizeBytes * (1 - item.progress)).round();
    }
  }

  return UploadSummary(
    completed: completed,
    total: items.length,
    progress: totalBytes == 0 ? 0 : (totalBytes - remaining) / totalBytes,
    remainingBytes: remaining,
  );
});
