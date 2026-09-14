import 'package:flutter/material.dart';

import 'app_theme.dart';

enum StatusTone { success, neutral, warning, error, info }

/// A noninteractive status indicator with a label as well as color and an icon.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    required this.icon,
    required this.tone,
  });

  final String label;
  final IconData icon;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (foreground, background) = switch (tone) {
      StatusTone.success => (AppTheme.success, AppTheme.successSurface),
      StatusTone.neutral => (AppTheme.muted, AppTheme.neutralSurface),
      StatusTone.warning => (AppTheme.warning, AppTheme.warningSurface),
      StatusTone.error => (
        theme.colorScheme.onErrorContainer,
        theme.colorScheme.errorContainer,
      ),
      StatusTone.info => (AppTheme.info, AppTheme.infoSurface),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 16, color: foreground)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
