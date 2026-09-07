import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants/app_sizes.dart';
import '../theme/app_colors.dart';

/// The dark two-line app bar used on every screen after sign-in.
///
/// The prototype pairs a bold title with a muted subtitle (level name over
/// project name, or project name over "Calibrations · plans for offline
/// capture"), with actions on the right and an optional status strip beneath.
class FieldAppBar extends StatelessWidget implements PreferredSizeWidget {
  const FieldAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const <Widget>[],
    this.trailing,
    this.bottom,
    this.titleIcon,
  });

  final String title;
  final String? subtitle;

  /// Overrides the automatic back button.
  final Widget? leading;

  /// Icon actions on the right, before [trailing].
  final List<Widget> actions;

  /// A pill or chip pinned to the right of the title row.
  final Widget? trailing;

  /// A status strip rendered under the title row, inside the dark chrome.
  final Widget? bottom;

  /// Small mark shown before the title — used for the app logo on Projects.
  final Widget? titleIcon;

  static const double _bottomHeight = AppSizes.statusStripHeight;

  @override
  Size get preferredSize => Size.fromHeight(
        AppSizes.appBarHeight + (bottom == null ? 0 : _bottomHeight),
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool canPop = ModalRoute.of(context)?.canPop ?? false;
    final Widget? resolvedLeading = leading ??
        (canPop
            ? IconButton(
                icon: const Icon(Icons.chevron_left, size: 28),
                color: AppColors.onChrome,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
      child: Material(
        color: AppColors.chrome,
        child: SafeArea(
          bottom: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                height: AppSizes.appBarHeight,
                child: Row(
                  children: <Widget>[
                    if (resolvedLeading != null)
                      resolvedLeading
                    else
                      const SizedBox(width: AppSizes.lg),
                    if (titleIcon != null) ...<Widget>[
                      titleIcon!,
                      const SizedBox(width: AppSizes.md),
                    ],
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleLarge
                                ?.copyWith(color: AppColors.onChrome),
                          ),
                          if (subtitle != null)
                            Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: AppColors.onChromeMuted),
                            ),
                        ],
                      ),
                    ),
                    if (trailing != null) ...<Widget>[
                      trailing!,
                      const SizedBox(width: AppSizes.md),
                    ],
                    ...actions,
                    const SizedBox(width: AppSizes.sm),
                  ],
                ),
              ),
              if (bottom != null)
                SizedBox(height: _bottomHeight, child: bottom),
            ],
          ),
        ),
      ),
    );
  }
}
