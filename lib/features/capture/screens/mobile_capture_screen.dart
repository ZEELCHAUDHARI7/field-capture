import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_button.dart';
import '../../../shared/camera/camera_controller.dart';
import '../../../shared/camera/camera_session.dart';
import '../models/capture_draft.dart';
import '../state/capture_flow_controller.dart';
import '../widgets/capture_chrome.dart';

/// Prototype screen 11 — Mobile Capture guide.
///
/// "The phone-native mode: a LiDAR-gated guided pano sweep with live progress.
/// Works with no 360° camera present, which makes it the fallback for any crew
/// member."
class MobileCaptureScreen extends ConsumerWidget {
  const MobileCaptureScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CaptureFlow flow = ref.watch(captureFlowProvider);
    final CaptureFlowController controller =
        ref.read(captureFlowProvider.notifier);
    final CameraSession camera = ref.watch(cameraSessionProvider);

    ref.listen<CaptureFlow>(captureFlowProvider,
        (CaptureFlow? previous, CaptureFlow next) {
      if (next.phase != CapturePhase.mobileSweep &&
          Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });

    final CaptureDraft? draft = flow.draft;
    if (draft == null || flow.phase != CapturePhase.mobileSweep) {
      return const _SweepPlaceholder(
        title: 'No sweep in progress',
        message: 'Start one from Mobile Capture on the capture dock.',
      );
    }

    if (!ref.watch(mobileCaptureSupportedProvider)) {
      return const _SweepPlaceholder(
        title: 'This phone cannot run Mobile Capture',
        message: 'Mobile Capture needs a depth sensor to stitch the sphere. '
            'Use the 360° camera on this level instead.',
      );
    }

    final int freeBytes =
        camera is CameraConnected ? camera.storageFreeBytes : 58 * 1000 * 1000 * 1000;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (!didPop) controller.discard();
        },
        child: Scaffold(
          backgroundColor: AppColors.captureBackdrop,
          body: Stack(
            children: <Widget>[
              const Positioned.fill(child: LivePreviewBackdrop()),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(AppSizes.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Wrap(
                        spacing: AppSizes.sm,
                        runSpacing: AppSizes.sm,
                        children: <Widget>[
                          const CapturePill(label: 'Phone camera · LiDAR assist'),
                          if (camera is CameraConnected)
                            CapturePill(
                              label: '${camera.batteryPercent}%',
                              icon: Icons.battery_std_outlined,
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSizes.sm),
                      CapturePill(
                        label: '${Formatters.bytes(freeBytes)} free',
                        icon: Icons.sd_storage_outlined,
                      ),
                      const Spacer(),
                      _SweepGuide(draft: draft),
                      const Spacer(flex: 2),
                      Text(
                        draft.name,
                        style: AppTypography.mono.copyWith(
                          fontSize: 12,
                          color: AppColors.alpha(AppColors.onChrome, 0.75),
                        ),
                      ),
                      const SizedBox(height: AppSizes.lg),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: AppButton(
                              label: 'Discard',
                              variant: AppButtonVariant.neutral,
                              onPressed: controller.discard,
                            ),
                          ),
                          const SizedBox(width: AppSizes.xl),
                          CaptureProgressRing(progress: draft.mobileProgress),
                          const SizedBox(width: AppSizes.md),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The reticle, the step title, the step dots and the sphere progress bar.
class _SweepGuide extends StatelessWidget {
  const _SweepGuide({required this.draft});

  final CaptureDraft draft;

  static const List<IconData> _arrows = <IconData>[
    Icons.arrow_upward_rounded,
    Icons.arrow_downward_rounded,
    Icons.arrow_back_rounded,
    Icons.arrow_forward_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int step = draft.mobileStep
        .clamp(0, CaptureFlowController.mobileSteps.length - 1);

    return Column(
      children: <Widget>[
        CustomPaint(
          painter: const _ReticlePainter(),
          child: SizedBox(
            height: 76,
            width: 76,
            child: Icon(
              _arrows[step],
              size: 28,
              color: AppColors.onChrome,
            ),
          ),
        ),
        const SizedBox(height: AppSizes.lg),
        Text(
          CaptureFlowController.mobileSteps[step],
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            color: AppColors.onChrome,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSizes.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            for (int i = 0;
                i < CaptureFlowController.mobileSteps.length;
                i++) ...<Widget>[
              Container(
                height: 7,
                width: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == step
                      ? AppColors.onChrome
                      : (i < step
                          ? AppColors.captureActive
                          : AppColors.capturePillBorder),
                ),
              ),
              if (i < CaptureFlowController.mobileSteps.length - 1)
                const SizedBox(width: 6),
            ],
          ],
        ),
        const SizedBox(height: AppSizes.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppSizes.radiusPill),
          child: LinearProgressIndicator(
            value: draft.mobileProgress,
            minHeight: 5,
            backgroundColor: AppColors.capturePillBorder,
            valueColor:
                const AlwaysStoppedAnimation<Color>(AppColors.captureActive),
          ),
        ),
        const SizedBox(height: AppSizes.md),
        Text(
          'Follow the arrow — the guides cover the full sphere automatically. '
          'LiDAR assists stitching.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppColors.onChromeMuted),
        ),
      ],
    );
  }
}

class _ReticlePainter extends CustomPainter {
  const _ReticlePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Offset centre = Offset(size.width / 2, size.height / 2);
    final double radius = size.width / 2 - 2;

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = AppColors.alpha(AppColors.onChrome, 0.45);

    // A dashed ring, drawn as arc segments.
    const int segments = 24;
    const double sweep = 6.2831853 / segments;
    for (int i = 0; i < segments; i += 2) {
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: radius),
        i * sweep,
        sweep,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ReticlePainter oldDelegate) => false;
}

class _SweepPlaceholder extends StatelessWidget {
  const _SweepPlaceholder({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.captureBackdrop,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: AppColors.onChrome),
              ),
              const SizedBox(height: AppSizes.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppColors.onChromeMuted),
              ),
              const SizedBox(height: AppSizes.xl),
              AppButton(
                label: 'Back to the plan',
                expanded: false,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
