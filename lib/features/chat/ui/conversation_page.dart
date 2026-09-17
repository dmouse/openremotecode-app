import 'package:flutter/material.dart';

import '../conversation_view_model.dart';
import '../domain/chat_models.dart';
import 'conversation_view.dart';
import 'message_tick_bar.dart';
import 'permission_banner.dart';
import 'question_banner.dart';
import 'todo_banner.dart';

/// The conversation page's body: the message list with its floating task
/// tab, tick bar, jump-to-latest button, a read-only footer for subtask
/// views, and the permission banner.
class ConversationPage extends StatefulWidget {
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
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  GlobalKey<ConversationViewState>? _conversationKey;
  String? _conversationKeyFor;

  /// A plain [GlobalKey], not a [GlobalObjectKey]: the latter compares equal
  /// by `identical()` on its wrapped value, so a fresh one built from
  /// `model.composerKey` every `build()` would never match the previous
  /// build's key -- forcing [ConversationView] to remount on every rebuild
  /// rather than only when the conversation identity actually changes. Kept
  /// across rebuilds here instead, and only replaced when [composerKey]
  /// changes (a chat switch, or a draft becoming a real chat), which is
  /// exactly when a full remount is wanted: it lets the tick bar and the
  /// jump-to-latest button -- both siblings of [ConversationView] in the
  /// [Stack] below -- reach into its state to trigger and observe scrolling.
  GlobalKey<ConversationViewState> _keyFor(ConversationViewModel model) {
    if (_conversationKeyFor != model.composerKey || _conversationKey == null) {
      _conversationKeyFor = model.composerKey;
      _conversationKey = GlobalKey<ConversationViewState>();
    }
    return _conversationKey!;
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final conversationKey = _keyFor(model);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            children: [
              ConversationView(
                key: conversationKey,
                model: model,
                onOpenSubtask: widget.onOpenSubtask,
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
                  child: TodoTab(model: model, onTap: widget.onOpenTodoBanner),
                ),
              ),
              Positioned(
                top: 44,
                bottom: 12,
                right: 6,
                child: MessageTickBar(
                  model: model,
                  conversationKey: conversationKey,
                ),
              ),
              Positioned(
                right: 16,
                bottom: 16,
                child: JumpToLatestButton(conversationKey: conversationKey),
              ),
            ],
          ),
        ),
        if (widget.isSubtask)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Subtask conversation · View only',
              textAlign: TextAlign.center,
            ),
          ),
        if (!widget.isSubtask) PermissionBanner(model: model),
        if (!widget.isSubtask)
          QuestionBanner(model: model, onTypeOwnAnswer: widget.onTypeOwnAnswer),
      ],
    );
  }
}
