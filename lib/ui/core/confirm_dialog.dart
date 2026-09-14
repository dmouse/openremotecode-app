import 'package:flutter/material.dart';

/// Shared "are you sure?" dialog: a title, content, and Cancel/confirm
/// actions. Cancel always pops with `false`. Confirm pops with `true` unless
/// [onConfirm] is given, for a caller that needs to re-check live state (e.g.
/// a resource that may have changed while the dialog was open) before
/// deciding whether — and with what result — to pop.
class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    required this.confirmLabel,
    this.cancelLabel = 'Cancel',
    this.destructive = false,
    this.confirmEnabled = true,
    this.onConfirm,
    this.scrollable = false,
  });

  final String title;
  final Widget content;
  final String confirmLabel;
  final String cancelLabel;

  /// Styles the confirm action as a destructive (error-colored text) action
  /// instead of a filled primary action.
  final bool destructive;
  final bool confirmEnabled;
  final VoidCallback? onConfirm;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final confirm = onConfirm ?? () => Navigator.pop(context, true);
    return AlertDialog(
      scrollable: scrollable,
      title: Text(title),
      content: content,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        destructive
            ? TextButton(
                onPressed: confirmEnabled ? confirm : null,
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                child: Text(confirmLabel),
              )
            : FilledButton(
                onPressed: confirmEnabled ? confirm : null,
                child: Text(confirmLabel),
              ),
      ],
    );
  }
}
