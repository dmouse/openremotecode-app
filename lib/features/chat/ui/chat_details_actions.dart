import 'package:flutter/material.dart';

import '../../../ui/core/confirm_dialog.dart';
import '../../../ui/core/inline_notice.dart';
import '../conversation_view_model.dart';

/// Actions remain bound to the conversation that opened this details route.
class ChatDetailsActions extends StatefulWidget {
  const ChatDetailsActions({super.key, required this.model});
  final ConversationViewModel model;

  @override
  State<ChatDetailsActions> createState() => _ChatDetailsActionsState();
}

class _ChatDetailsActionsState extends State<ChatDetailsActions>
    with WidgetsBindingObserver {
  late final String? _source, _projectPath;
  bool _confirming = false, _foreground = true;

  bool get _current =>
      mounted &&
      _foreground &&
      !widget.model.trustLost() &&
      widget.model.composerKey == _source &&
      widget.model.project()?.path == _projectPath &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    _source = widget.model.composerKey;
    _projectPath = widget.model.project()?.path;
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    setState(() => _foreground = state == AppLifecycleState.resumed);
  }

  Future<void> _fork() async {
    if (!_current || _confirming || !widget.model.canFork) return;
    // A confirmed fork changes composerKey; the details route then dismisses
    // itself. An unconditional pop here could dismiss the destination instead.
    await widget.model.forkChat();
  }

  Future<void> _delete() async {
    if (!_current || _confirming || !widget.model.canDeleteCurrentChat) return;
    setState(() => _confirming = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _DeleteChatDialog(model: widget.model),
      );
      if (confirmed == true && _current && widget.model.canDeleteCurrentChat) {
        await widget.model.deleteCurrentChat();
      }
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final model = widget.model;
      final enabled = _current && !_confirming;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (model.error != null) ...[
            InlineNotice(message: model.error!, isError: true),
            const SizedBox(height: 12),
          ],
          if (model.busyGate.mutating) ...[
            LinearProgressIndicator(semanticsLabel: model.progressLabel),
            const SizedBox(height: 12),
          ],
          TextButton.icon(
            onPressed: enabled && model.canFork ? _fork : null,
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
            icon: const Icon(Icons.call_split),
            label: const Text('Fork chat'),
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: enabled && model.canDeleteCurrentChat ? _delete : null,
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete chat'),
          ),
        ],
      );
    },
  );
}

class _DeleteChatDialog extends StatefulWidget {
  const _DeleteChatDialog({required this.model});
  final ConversationViewModel model;

  @override
  State<_DeleteChatDialog> createState() => _DeleteChatDialogState();
}

class _DeleteChatDialogState extends State<_DeleteChatDialog>
    with WidgetsBindingObserver {
  late final String? _source, _projectPath;
  late final String _title;
  bool _foreground = true;

  bool get _valid =>
      !widget.model.trustLost() &&
      widget.model.repository.chatTrusted(widget.model.connectorId) &&
      widget.model.composerKey == _source &&
      widget.model.project()?.path == _projectPath;

  @override
  void initState() {
    super.initState();
    _source = widget.model.composerKey;
    _projectPath = widget.model.project()?.path;
    _title = widget.model.chat!.title;
    widget.model.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  void _changed() {
    if ((!_valid || !_foreground) &&
        mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context, false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _changed();
  }

  void _confirm() {
    if (!mounted ||
        !_foreground ||
        !_valid ||
        !widget.model.canDeleteCurrentChat ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.model.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) => ConfirmDialog(
      scrollable: true,
      title: 'Delete chat?',
      content: _valid && _foreground
          ? Text(
              'Permanently delete “$_title” and its sub-agent conversations from OpenCode? This cannot be undone.',
            )
          : const SizedBox.shrink(),
      confirmLabel: 'Delete',
      destructive: true,
      confirmEnabled:
          _valid && _foreground && widget.model.canDeleteCurrentChat,
      onConfirm: _confirm,
    ),
  );
}
