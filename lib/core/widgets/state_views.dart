import 'package:flutter/material.dart';

import '../constants/app_sizes.dart';
import '../theme/app_colors.dart';
import 'app_button.dart';
import 'app_card.dart';

/// Loading, empty and error views.
///
/// ASSUMED — the prototype draws none of these, on any screen. The visual
/// language here is invented and recorded in ASSUMPTIONS.md. It is deliberately
/// quiet: a construction crew opening the app on a bad connection should see
/// structure, not a spinner on a blank page.

/// Skeleton rows shaped like the card they are standing in for.
class LoadingListView extends StatelessWidget {
  const LoadingListView({super.key, this.rows = 3, this.rowHeight = 92});

  final int rows;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(AppSizes.screenPadding),
      itemCount: rows,
      separatorBuilder: (_, __) => const SizedBox(height: AppSizes.cardGap),
      itemBuilder: (BuildContext context, int index) => _Shimmer(
        child: Container(
          height: rowHeight,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppSizes.radiusCard),
            border: Border.all(color: AppColors.outline),
          ),
        ),
      ),
    );
  }
}

class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});
  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1).animate(_controller),
      child: widget.child,
    );
  }
}

/// Nothing to show, and that is not a failure.
class EmptyStateView extends StatelessWidget {
  const EmptyStateView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              height: 56,
              width: 56,
              decoration: const BoxDecoration(
                color: AppColors.outlineSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 26, color: AppColors.onSurfaceVariant),
            ),
            const SizedBox(height: AppSizes.lg),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSizes.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.onSurfaceVariant),
            ),
            if (actionLabel != null && onAction != null) ...<Widget>[
              const SizedBox(height: AppSizes.xl),
              AppButton(
                label: actionLabel!,
                onPressed: onAction,
                variant: AppButtonVariant.secondary,
                expanded: false,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Something failed. Say what, and offer the way out.
class ErrorStateView extends StatelessWidget {
  const ErrorStateView({
    super.key,
    required this.message,
    this.onRetry,
    this.title = 'Could not load',
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.xxl),
        child: AppCard(
          borderColor: AppColors.dangerContainer,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: AppColors.onDangerContainer,
                    size: 20,
                  ),
                  const SizedBox(width: AppSizes.sm),
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleMedium),
                  ),
                ],
              ),
              const SizedBox(height: AppSizes.sm),
              Text(
                message,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.onSurfaceVariant),
              ),
              if (onRetry != null) ...<Widget>[
                const SizedBox(height: AppSizes.lg),
                AppButton(
                  label: 'Try again',
                  onPressed: onRetry,
                  variant: AppButtonVariant.secondary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
