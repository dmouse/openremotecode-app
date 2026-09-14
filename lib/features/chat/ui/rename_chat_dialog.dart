import 'package:flutter/material.dart';

import '../../../ui/core/rename_dialog.dart';
import '../conversation_view_model.dart';

class RenameChatDialog extends StatefulWidget {
  const RenameChatDialog({super.key, required this.title, required this.model});
  final String title;
  final ConversationViewModel model;

  @override
  State<RenameChatDialog> createState() => _RenameChatDialogState();
}

class _RenameChatDialogState extends State<RenameChatDialog> {
  late final String? _source;

  @override
  void initState() {
    super.initState();
    _source = widget.model.composerKey;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) => RenameDialog(
      title: 'Rename chat',
      label: 'Chat name',
      initialValue: widget.title,
      validator: ConversationViewModel.validateChatTitle,
      canSave: widget.model.canRename,
      watch: widget.model,
      shouldClose: () =>
          widget.model.trustLost() || widget.model.composerKey != _source,
      onSave: (text) async {
        final saved = await widget.model.renameChat(text);
        return saved ? null : widget.model.error;
      },
    ),
  );
}
