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

/// The Image capture step — not a prototype screen.
///
/// The deck names Image on its own capture dock but draws no shooting step for
/// it, so the mode used to go straight from the pin to saved: a tap on a dock
/// tile, a pin, and then nothing to look at. ASSUMPTIONS.md §G9.
///
/// This is the smallest step that makes the mode real without inventing
/// anything the deck contradicts: the framing preview it already draws for the
/// other two modes, the capture's name, and a shutter. A 360° still needs the
/// camera, so — like the dock — it refuses politely when the camera is gone.
class ImageCaptureScreen extends ConsumerStatefulWidget {
  const ImageCaptureScreen({super.key});

  @override
  ConsumerState<ImageCaptureScreen> createState() => _ImageCaptureScreenState();
}

class _ImageCaptureScreenState extends ConsumerState<ImageCaptureScreen> {
  bool _exposing = false;

  Future<void> _shoot(CaptureFlowController controller) async {
    if (_exposing) return;
    setState(() => _exposing = true);
    // Long enough to read as a shutter, short enough not to be a wait.
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;
    setState(() => _exposing = false);
    controller.captureStill();
  }

  @override
  Widget build(BuildContext context) {
    final CaptureFlow flow = ref.watch(captureFlowProvider);
    final CaptureFlowController controller =
        ref.read(captureFlowProvider.notifier);
    final CameraSession camera = ref.watch(cameraSessionProvider);

    ref.listen<CaptureFlow>(captureFlowProvider,
        (CaptureFlow? previous, CaptureFlow next) {
      if (next.phase != CapturePhase.shooting &&
          Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });

    final CaptureDraft? draft = flow.draft;
    if (draft == null || flow.phase != CapturePhase.shooting) {
      return const _NotShooting(
        title: 'No capture in progress',
        message: 'Start one from Image on the capture dock.',
      );
    }

    if (camera is! CameraConnected) {
      return const _NotShooting(
        title: '360° camera not connected',
        message: 'A 360° still comes from the camera, not the phone. '
            'Reconnect it, or use Mobile Capture instead.',
      );
    }

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
                          CapturePill(
                            label: '${camera.model} · ${camera.serial}',
                            icon: Icons.camera_outlined,
                          ),
                          CapturePill(
                            label: '${camera.batteryPercent}%',
                            icon: Icons.battery_std_outlined,
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSizes.sm),
                      CapturePill(
                        label:
                            '${Formatters.bytes(camera.storageFreeBytes)} free',
                        icon: Icons.sd_storage_outlined,
                      ),
                      const Spacer(),
                      Center(
                        child: Text(
                          'Frame the space, then shoot',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(color: AppColors.onChrome),
                        ),
                      ),
                      const SizedBox(height: AppSizes.sm),
                      Center(
                        child: Text(
                          'One 360° still is captured at the pin you placed.',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppColors.alpha(
                                      AppColors.onChrome,
                                      0.7,
                                    ),
                                  ),
                        ),
                      ),
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
                          _ShutterButton(
                            busy: _exposing,
                            onPressed: () => _shoot(controller),
                          ),
                          const SizedBox(width: AppSizes.md),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // The shutter flash. Ignores pointers so it can never swallow
              // the tap that started it.
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _exposing ? 1 : 0,
                    duration: const Duration(milliseconds: 90),
                    child: const ColoredBox(color: Colors.white),
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

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Shoot the 360° still',
      child: GestureDetector(
        onTap: busy ? null : onPressed,
        child: Container(
          height: 76,
          width: 76,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.onChrome, width: 3),
          ),
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: busy
                    ? AppColors.alpha(AppColors.onChrome, 0.5)
                    : AppColors.onChrome,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reached only if the route is opened without a capture in flight, or the
/// camera goes while the screen is up.
class _NotShooting extends StatelessWidget {
  const _NotShooting({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.captureBackdrop,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSizes.xxl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(color: AppColors.onChrome),
              ),
              const SizedBox(height: AppSizes.sm),
              Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.alpha(AppColors.onChrome, 0.75),
                    ),
              ),
              const SizedBox(height: AppSizes.xl),
              AppButton(
                label: 'Back to the plan',
                variant: AppButtonVariant.neutral,
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
