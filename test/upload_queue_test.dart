import 'package:field_capture/core/utils/formatters.dart';
import 'package:field_capture/features/plan/models/plan_marker.dart';
import 'package:field_capture/features/uploads/models/upload_item.dart';
import 'package:field_capture/features/uploads/state/upload_queue_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The upload queue's summary figures are derived, not stored — and the
/// prototype prints all four of them on page 19 from the same four items.
/// That makes the deck itself the expected output.
void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  UploadQueueController queue() =>
      container.read(uploadQueueProvider.notifier);
  List<UploadItem> items() => container.read(uploadQueueProvider);
  UploadSummary summary() => container.read(uploadSummaryProvider);

  group('the summary reproduces the prototype', () {
    test('"Uploading 2 of 4"', () {
      expect(summary().position, 2);
      expect(summary().total, 4);
    });

    test('"49%"', () {
      expect(Formatters.percent(summary().progress), '49%');
    });

    test('"444 MB remaining"', () {
      expect(Formatters.bytes(summary().remainingBytes), '444 MB');
    });

    test('the header badge reads 3', () {
      expect(container.read(pendingUploadCountProvider), 3);
    });
  });

  group('item actions', () {
    test('pausing an uploading item stops it counting as in flight', () {
      queue().pause('up-1');
      expect(
        items().firstWhere((UploadItem i) => i.id == 'up-1').status,
        UploadStatus.paused,
      );
    });

    test('pause then resume returns the item to the queue', () {
      queue()
        ..pause('up-2')
        ..resume('up-2');
      expect(
        items().firstWhere((UploadItem i) => i.id == 'up-2').status,
        UploadStatus.waiting,
      );
    });

    test('an uploaded item cannot be paused', () {
      queue().pause('up-4');
      expect(
        items().firstWhere((UploadItem i) => i.id == 'up-4').status,
        UploadStatus.uploaded,
      );
    });

    test('retry resumes from the last good offset, it does not restart', () {
      final UploadItem before =
          items().firstWhere((UploadItem i) => i.id == 'up-3');
      expect(before.status, UploadStatus.failed);
      expect(before.progress, 0.62);

      queue().retry('up-3');

      final UploadItem after =
          items().firstWhere((UploadItem i) => i.id == 'up-3');
      expect(after.status, UploadStatus.uploading);
      expect(after.progress, 0.62, reason: 'bytes are kept');
      expect(after.failureReason, isNull);
      expect(after.retryInSeconds, isNull);
    });

    test('retry does nothing to an item that has not failed', () {
      queue().retry('up-2');
      expect(
        items().firstWhere((UploadItem i) => i.id == 'up-2').status,
        UploadStatus.waiting,
      );
    });
  });

  group('enqueue', () {
    test('a saved capture joins the front of the queue as waiting', () {
      queue().enqueue(
        name: 'L03_Walk_2026-09-07_14',
        calibrationId: 'prj-4821-l03',
        mode: CaptureMode.video,
        sizeBytes: 120 * 1000 * 1000,
        duration: const Duration(minutes: 3, seconds: 20),
      );

      expect(items(), hasLength(5));
      expect(items().first.name, 'L03_Walk_2026-09-07_14');
      expect(items().first.status, UploadStatus.waiting);
      expect(container.read(pendingUploadCountProvider), 4);
    });

    test('the summary follows the new item', () {
      queue().enqueue(
        name: 'L03_Img_2026-09-07_14',
        calibrationId: 'prj-4821-l03',
        mode: CaptureMode.image,
        sizeBytes: 28 * 1000 * 1000,
      );

      expect(summary().total, 5);
      expect(summary().completed, 1);
      // 444 MB was outstanding; a 28 MB still adds to it in full.
      expect(Formatters.bytes(summary().remainingBytes), '472 MB');
    });
  });
}
