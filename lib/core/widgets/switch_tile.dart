import 'package:flutter/material.dart';

import '../constants/app_sizes.dart';
import '../theme/app_colors.dart';
import 'app_card.dart';

/// Title, description, trailing switch — the shape used by "Upload on Wi-Fi
/// only" and "Auto-delete local files".
///
/// The same tile appears on both the upload queue and Settings, reading the
/// same state, which is why it lives in core.
class SwitchTile extends StatelessWidget {
  const SwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.description,
    this.destructive = false,
  });

  final String title;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// "Auto-delete after upload is off by default — destructive settings opt
  /// in." Marks the tile so it reads as a decision, not a convenience.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return AppCard(
      onTap: () => onChanged(!value),
      semanticLabel: '$title, ${value ? 'on' : 'off'}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(title, style: theme.textTheme.titleSmall),
                    ),
                    if (destructive) ...<Widget>[
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.warning_amber_rounded,
                        size: 15,
                        color: AppColors.onWarningContainer,
                      ),
                    ],
                  ],
                ),
                if (description != null) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    description!,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: AppColors.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSizes.md),
          ExcludeSemantics(
            child: Switch(value: value, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}
