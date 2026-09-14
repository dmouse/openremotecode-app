import 'package:flutter/material.dart';

import 'app_button.dart';
import 'inline_notice.dart';

/// Shared "rename" dialog: a single validated text field with Cancel/Save.
///
/// Two modes, chosen by whether [onSave] is provided:
/// - Omitted: a valid Save pops the dialog immediately with the entered text.
/// - Provided: Save calls [onSave] with the validated text and shows a
///   loading state on the Save button while it runs. Return `null` to close
///   the dialog with `true`; return an error message to display inline and
///   keep the dialog open.
class RenameDialog extends StatefulWidget {
  const RenameDialog({
    super.key,
    required this.title,
    required this.label,
    required this.initialValue,
    required this.validator,
    this.canSave = true,
    this.onSave,
    this.watch,
    this.shouldClose,
  });

  final String title;
  final String label;
  final String initialValue;
  final String? Function(String?) validator;

  /// Whether Save may currently run, independent of the in-progress local
  /// saving state. Re-evaluated on every rebuild, so a caller can gate this
  /// on live state (e.g. a connector going offline mid-edit).
  final bool canSave;

  final Future<String?> Function(String value)? onSave;

  /// Together with [shouldClose], lets a caller invalidate a stale edit in
  /// response to external state changes (e.g. the underlying resource being
  /// renamed elsewhere, or trust being revoked) without owning the text
  /// field itself. Listened to directly — not through a rebuild — so the
  /// field is cleared synchronously with the change, before any frame runs.
  final Listenable? watch;

  /// Checked on every [watch] notification; when it returns true the field
  /// is cleared and the dialog pops itself (if still the current route).
  final bool Function()? shouldClose;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  final _form = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initialValue);
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.watch?.addListener(_checkClose);
  }

  @override
  void didUpdateWidget(covariant RenameDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.watch != oldWidget.watch) {
      oldWidget.watch?.removeListener(_checkClose);
      widget.watch?.addListener(_checkClose);
    }
  }

  void _checkClose() {
    if (widget.shouldClose?.call() ?? false) {
      _controller.clear();
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context);
      }
    }
  }

  Future<void> _save() async {
    if (_saving || !widget.canSave || !_form.currentState!.validate()) return;
    final onSave = widget.onSave;
    if (onSave == null) {
      Navigator.pop(context, _controller.text);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await onSave(_controller.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  @override
  void dispose() {
    widget.watch?.removeListener(_checkClose);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title),
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: _controller,
            enabled: !_saving,
            autofocus: true,
            validator: widget.validator,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _save(),
            decoration: InputDecoration(labelText: widget.label),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 12),
            InlineNotice(message: error, isError: true),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      AppButton.primary(
        label: 'Save',
        isLoading: _saving,
        loadingLabel: 'Saving',
        onPressed: widget.canSave && !_saving ? _save : null,
      ),
    ],
  );
}
