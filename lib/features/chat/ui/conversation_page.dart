import 'package:flutter/material.dart';

import '../conversation_view_model.dart';
import '../domain/chat_models.dart';
import 'conversation_view.dart';
import 'permission_banner.dart';
import 'question_banner.dart';
import 'todo_banner.dart';

/// The conversation page's body: the message list with its floating task
/// tab, a read-only footer for subtask views, and the permission banner.
class ConversationPage extends StatelessWidget {
  const ConversationPage({
    super.key,
    required this.model,
    required this.isSubtask,
    required this.onOpenSubtask,
    required this.onOpenTodoBanner,
    this.onTypeOwnAnswer,
  });

  final ConversationViewModel model;
  final bool isSubtask;
  final ValueChanged<ChatSubtask>? onOpenSubtask;
  final VoidCallback onOpenTodoBanner;

  /// Raised when the question banner switches into free-text drafting, so the
  /// composer can be focused. See [QuestionBanner.onTypeOwnAnswer].
  final VoidCallback? onTypeOwnAnswer;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: Stack(
          children: [
            ConversationView(
              key: ValueKey(model.composerKey),
              model: model,
              onOpenSubtask: onOpenSubtask,
            ),
            // The task tab hangs from the middle of the header's hairline
            // and floats over the messages: it takes none of the list's
            // height and the list keeps scrolling under it.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Align(
                alignment: Alignment.topCenter,
                child: TodoTab(model: model, onTap: onOpenTodoBanner),
              ),
            ),
          ],
        ),
      ),
      if (isSubtask)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Subtask conversation · View only',
            textAlign: TextAlign.center,
          ),
        ),
      if (!isSubtask) PermissionBanner(model: model),
      if (!isSubtask) QuestionBanner(model: model, onTypeOwnAnswer: onTypeOwnAnswer),
    ],
  );
}
