import 'package:flutter/material.dart';

import '../../../core/constants/app_sizes.dart';
import '../../../core/theme/app_colors.dart';
import '../state/workspace_controller.dart';

/// Capture | Site Issues (n).
///
/// Built by hand rather than with TabBar because the indicator, the count in
/// the label and the navy ground all differ from the Material default, and
/// because TabBar's theme class was renamed across recent Flutter releases.
class WorkspaceTabs extends StatelessWidget {
  const WorkspaceTabs({
    super.key,
    required this.selected,
    required this.issueCount,
    required this.onChanged,
  });

  final WorkspaceTab selected;
  final int issueCount;
  final ValueChanged<WorkspaceTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.chrome,
      child: Row(
        children: <Widget>[
          Expanded(
            child: _Tab(
              label: 'Capture',
              isSelected: selected == WorkspaceTab.capture,
              onTap: () => onChanged(WorkspaceTab.capture),
            ),
          ),
          Expanded(
            child: _Tab(
              label: 'Site Issues ($issueCount)',
              isSelected: selected == WorkspaceTab.issues,
              onTap: () => onChanged(WorkspaceTab.issues),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isSelected,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: AppSizes.minTouchTarget,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? AppColors.onChrome : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: isSelected
                      ? AppColors.onChrome
                      : AppColors.onChromeMuted,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ),
    );
  }
}
