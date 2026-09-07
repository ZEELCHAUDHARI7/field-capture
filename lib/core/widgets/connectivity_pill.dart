import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/connectivity/connectivity_controller.dart';
import '../../shared/connectivity/connectivity_status.dart';
import '../constants/app_sizes.dart';
import '../theme/app_colors.dart';

/// The connectivity pill that sits on dark chrome: a coloured dot plus a label.
///
/// Appears on 8 of the prototype's 21 states, which is why it lives in core.
/// Tapping it cycles the mock state so QA can exercise every screen's
/// online / syncing / offline treatment without a real network. That tap
/// handler goes away in Phase 4 when connectivity becomes real.
class ConnectivityPill extends ConsumerWidget {
  const ConnectivityPill({super.key, this.compact = false});

  /// Compact shows the dot and a one-word label — used where space is tight.
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ConnectivityStatus status = ref.watch(connectivityControllerProvider);
    final Color dotColor = switch (status) {
      ConnectivityStatus.online => AppColors.liveDot,
      ConnectivityStatus.syncing => AppColors.liveDot,
      ConnectivityStatus.offline => AppColors.warning,
    };
    final String label = compact
        ? (status.isOffline ? 'Offline' : 'Online')
        : status.label;

    return Semantics(
      label: 'Connection status: ${status.label}',
      child: Material(
        color: AppColors.chromeElevated,
        borderRadius: BorderRadius.circular(AppSizes.radiusPill),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppSizes.radiusPill),
          onTap: () => ref.read(connectivityControllerProvider.notifier).cycle(),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSizes.md,
              vertical: 7,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _Dot(color: dotColor, pulsing: status.isSyncing),
                const SizedBox(width: AppSizes.sm),
                Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: AppColors.onChrome),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  const _Dot({required this.color, required this.pulsing});

  final Color color;
  final bool pulsing;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _Dot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  /// Honours the platform "reduce motion" setting — the dot simply stays lit.
  void _sync() {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (widget.pulsing && !reduceMotion) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 1;
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
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_controller),
      child: Container(
        height: 8,
        width: 8,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
