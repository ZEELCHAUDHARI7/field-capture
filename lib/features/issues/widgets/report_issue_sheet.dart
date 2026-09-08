import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/chip_selector.dart';
import '../../../shared/camera/camera_controller.dart';
import '../../../shared/camera/camera_session.dart';
import '../../plan/models/plan_marker.dart';
import '../models/issue_draft.dart';
import '../state/issue_report_controller.dart';

/// Prototype screen 18 — Report an issue.
///
/// "Raising an issue is a short sheet: title, category, severity, optional
/// photo and a pin. Everything else is inferred from context."
class ReportIssueSheet extends ConsumerStatefulWidget {
  const ReportIssueSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      barrierColor: AppColors.scrim,
      builder: (BuildContext context) => const ReportIssueSheet(),
    );
  }

  @override
  ConsumerState<ReportIssueSheet> createState() => _ReportIssueSheetState();
}

class _ReportIssueSheetState extends ConsumerState<ReportIssueSheet> {
  late final TextEditingController _title = TextEditingController(
    text: ref.read(issueReportProvider).draft?.title ?? '',
  );

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final IssueReportFlow flow = ref.watch(issueReportProvider);
    final IssueReportController controller =
        ref.read(issueReportProvider.notifier);
    final CameraSession camera = ref.watch(cameraSessionProvider);
    final IssueDraft? draft = flow.draft;

    if (draft == null) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSizes.xl,
            AppSizes.sm,
            AppSizes.xl,
            AppSizes.xl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('Report a site issue', style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSizes.lg),

              Row(
                children: <Widget>[
                  Expanded(
                    child: _PhotoButton(
                      icon: Icons.photo_camera_outlined,
                      label: 'Phone photo',
                      attached: draft.photo == IssuePhoto.phone,
                      onTap: () => draft.photo == IssuePhoto.phone
                          ? controller.removePhoto()
                          : controller.attachPhoto(IssuePhoto.phone),
                    ),
                  ),
                  const SizedBox(width: AppSizes.md),
                  Expanded(
                    child: _PhotoButton(
                      icon: Icons.language_outlined,
                      label: '360° camera still',
                      attached: draft.photo == IssuePhoto.camera360,
                      // A still comes from the camera, so this refuses while
                      // the camera is gone — the same rule the dock applies.
                      enabled: camera.isConnected,
                      disabledLabel: 'Camera offline',
                      onTap: () => draft.photo == IssuePhoto.camera360
                          ? controller.removePhoto()
                          : controller.attachPhoto(IssuePhoto.camera360),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSizes.lg),

              AppTextField(
                label: 'Title',
                controller: _title,
                hintText: 'e.g. Zone C access blocked',
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _next(controller, draft),
              ),
              const SizedBox(height: AppSizes.lg),

              Text(
                'Category',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.onSurfaceVariant),
              ),
              const SizedBox(height: AppSizes.sm),
              ChipSelector<IssueCategory>(
                values: IssueCategory.values,
                selected: draft.category,
                labelOf: (IssueCategory c) => c.label,
                onChanged: controller.setCategory,
              ),
              const SizedBox(height: AppSizes.lg),

              Text(
                'Severity',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.onSurfaceVariant),
              ),
              const SizedBox(height: AppSizes.sm),
              ChipSelector<IssueSeverity>(
                values: IssueSeverity.values,
                selected: draft.severity,
                labelOf: (IssueSeverity s) => s.label,
                tone: ChipSelectorTone.chrome,
                onChanged: controller.setSeverity,
              ),
              const SizedBox(height: AppSizes.xl),

              Row(
                children: <Widget>[
                  Expanded(
                    child: AppButton(
                      label: 'Cancel',
                      variant: AppButtonVariant.neutral,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: AppSizes.md),
                  Expanded(
                    flex: 2,
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _title,
                      builder: (BuildContext context, TextEditingValue value, _) {
                        return AppButton(
                          label: 'Next — pin location',
                          // Disabled until a title exists — the prototype draws
                          // it greyed with the field empty.
                          onPressed: value.text.trim().isEmpty
                              ? null
                              : () => _next(controller, draft),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _next(IssueReportController controller, IssueDraft draft) {
    if (_title.text.trim().isEmpty) return;
    controller
      ..setTitle(_title.text)
      ..confirmCompose();
    Navigator.of(context).pop();
  }
}

/// The dashed photo buttons. Dashed because nothing is attached yet — the
/// border goes solid and the label changes once one is.
class _PhotoButton extends StatelessWidget {
  const _PhotoButton({
    required this.icon,
    required this.label,
    required this.attached,
    required this.onTap,
    this.enabled = true,
    this.disabledLabel,
  });

  final IconData icon;
  final String label;
  final bool attached;
  final VoidCallback onTap;
  final bool enabled;

  /// Shown instead of [label] when the button is refused, so the reason is on
  /// the control rather than in a toast after the tap.
  final String? disabledLabel;

  @override
  Widget build(BuildContext context) {
    final Color foreground = !enabled
        ? AppColors.onSurfaceVariant
        : (attached ? AppColors.success : AppColors.onSurface);

    return Semantics(
      button: true,
      enabled: enabled,
      label: attached ? '$label, attached' : label,
      child: Material(
        color: switch ((enabled, attached)) {
          (false, _) => AppColors.neutralContainer,
          (true, true) => AppColors.successContainer,
          (true, false) => AppColors.surface,
        },
        borderRadius: BorderRadius.circular(AppSizes.radiusCard),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(AppSizes.radiusCard),
          child: CustomPaint(
            painter: attached ? null : const _DashedBorderPainter(),
            child: Container(
              height: 78,
              alignment: Alignment.center,
              decoration: attached
                  ? BoxDecoration(
                      borderRadius:
                          BorderRadius.circular(AppSizes.radiusCard),
                      border: Border.all(color: AppColors.success),
                    )
                  : null,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    attached ? Icons.check_circle_outline : icon,
                    size: 20,
                    color: attached
                        ? AppColors.success
                        : AppColors.onSurfaceVariant,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    !enabled
                        ? (disabledLabel ?? label)
                        : (attached ? 'Attached' : label),
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: foreground),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final RRect rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(AppSizes.radiusCard),
    );
    final Path path = Path()..addRRect(rect);
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = AppColors.outline;

    const double dash = 6;
    const double gap = 4;
    for (final PathMetric metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double end = distance + dash;
        canvas.drawPath(
          metric.extractPath(
            distance,
            end > metric.length ? metric.length : end,
          ),
          paint,
        );
        distance = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) => false;
}
