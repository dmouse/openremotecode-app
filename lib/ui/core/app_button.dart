import 'package:flutter/material.dart';

/// Shared action button. Colors, shape, and touch targets come from AppTheme.
/// The caller owns async work; loading disables activation and announces progress.
class AppButton extends StatelessWidget {
  const AppButton.primary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.iconAlignment = IconAlignment.start,
    this.isLoading = false,
    this.loadingLabel,
  }) : _outlined = false;

  const AppButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.iconAlignment = IconAlignment.start,
    this.isLoading = false,
    this.loadingLabel,
  }) : _outlined = true;

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final IconAlignment iconAlignment;
  final bool isLoading;
  final String? loadingLabel;
  final bool _outlined;

  @override
  Widget build(BuildContext context) {
    final indicator = isLoading
        ? const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : icon == null
        ? null
        : Icon(icon, size: 20);
    final child = Semantics(
      liveRegion: isLoading,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (indicator != null && iconAlignment == IconAlignment.start) ...[
            ExcludeSemantics(child: indicator),
            const SizedBox(width: 12),
          ],
          Flexible(
            child: Text(
              isLoading ? loadingLabel ?? label : label,
              textAlign: TextAlign.center,
            ),
          ),
          if (indicator != null && iconAlignment == IconAlignment.end) ...[
            const SizedBox(width: 12),
            ExcludeSemantics(child: indicator),
          ],
        ],
      ),
    );
    return _outlined
        ? OutlinedButton(onPressed: isLoading ? null : onPressed, child: child)
        : FilledButton(onPressed: isLoading ? null : onPressed, child: child);
  }
}
