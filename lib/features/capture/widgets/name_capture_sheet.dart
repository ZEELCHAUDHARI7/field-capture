import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_text_field.dart';
import '../models/capture_draft.dart';
import '../models/capture_naming.dart';
import '../state/capture_flow_controller.dart';

/// Prototype screen 06 — Name the capture.
///
/// "Every capture is named before it starts, pre-filled from level, mode, date
/// and sequence so the default is already correct and the crew can just
/// confirm." The sheet keeps the plan visible behind it — context is never lost.
class NameCaptureSheet extends ConsumerStatefulWidget {
  const NameCaptureSheet({super.key, required this.draft});

  final CaptureDraft draft;

  /// Opens the sheet and resolves when it closes. Dismissing it by any route —
  /// the button, the scrim, the Android back gesture — discards the draft, so
  /// a half-named capture can never survive.
  static Future<void> show(BuildContext context, CaptureDraft draft) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      barrierColor: AppColors.scrim,
      builder: (BuildContext context) => NameCaptureSheet(draft: draft),
    );
  }

  @override
  ConsumerState<NameCaptureSheet> createState() => _NameCaptureSheetState();
}

class _NameCaptureSheetState extends ConsumerState<NameCaptureSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.draft.name);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _controller.text.trim();
    final String? error = CaptureNaming.validate(name);
    if (error != null) {
      setState(() => _error = error);
      return;
    }

    final CaptureFlowController flow =
        ref.read(captureFlowProvider.notifier);
    flow
      ..rename(name)
      ..confirmName();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSizes.xl,
            AppSizes.sm,
            AppSizes.xl,
            AppSizes.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Name this capture', style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSizes.xs),
              Text(
                CaptureNaming.hintFor(widget.draft.mode),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.onSurfaceVariant),
              ),
              const SizedBox(height: AppSizes.lg),
              AppTextField(
                label: '',
                controller: _controller,
                monospace: true,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: AppSizes.sm),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.onDangerContainer),
                ),
              ],
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
                    child: AppButton(
                      label: 'Next — pin location',
                      onPressed: _submit,
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
}
