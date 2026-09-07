import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../state/upload_queue_controller.dart';

/// The upload-queue action with its red outstanding-count badge.
///
/// Sits in the app bar on 9 of the prototype's states — "reachable from
/// anywhere" is explicit in the documentation.
class UploadQueueButton extends ConsumerWidget {
  const UploadQueueButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int count = ref.watch(pendingUploadCountProvider);

    return Semantics(
      button: true,
      label: count == 0
          ? 'Upload queue, empty'
          : 'Upload queue, $count outstanding',
      child: SizedBox(
        height: AppSizes.minTouchTarget,
        width: AppSizes.minTouchTarget,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: <Widget>[
            IconButton(
              onPressed: onPressed,
              iconSize: 22,
              color: AppColors.onChrome,
              icon: const Icon(Icons.cloud_upload_outlined),
              tooltip: 'Upload queue',
            ),
            if (count > 0)
              Positioned(
                top: 4,
                right: 2,
                child: IgnorePointer(
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.recording,
                      borderRadius: BorderRadius.circular(AppSizes.radiusPill),
                    ),
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: AppColors.onPrimary,
                            fontSize: 10,
                          ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
