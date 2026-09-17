import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui/core/app_theme.dart';
import '../conversation_view_model.dart';

/// The conversation's draft input row: the message field, its model/effort
/// suffix button, a stop button while a response is in flight, and the send
/// button (long-press to change Build/Plan mode).
class ChatComposerBar extends StatelessWidget {
  const ChatComposerBar({
    super.key,
    required this.model,
    required this.draft,
    required this.composerFocus,
    required this.busy,
    required this.online,
    required this.onOpenModelBanner,
    required this.onChoosePromptMode,
  });

  final ConversationViewModel model;
  final TextEditingController draft;
  final FocusNode composerFocus;
  final bool busy;
  final bool online;
  final VoidCallback onOpenModelBanner;
  final VoidCallback onChoosePromptMode;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: ListenableBuilder(
      listenable: Listenable.merge([draft, composerFocus]),
      builder: (context, _) {
        final focused = composerFocus.hasFocus;
        final showModelButton = draft.text.isEmpty || !focused;
        final answeringQuestion = model.answeringCustomQuestion;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              // The surface, radius and enabled/focused borders all come
              // from the app theme's input decoration; re-drawing them
              // around the field would fork the one definition every other
              // input shares.
              child: Semantics(
                label: 'Message',
                child: TextField(
                  key: const ValueKey('chat-composer'),
                  controller: draft,
                  focusNode: composerFocus,
                  minLines: 1,
                  maxLines: 5,
                  maxLength: 32000,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    hintText: answeringQuestion ? 'Type your answer...' : null,
                    counterText: '',
                    // Only reserved when shown, so it never adds space of
                    // its own -- and it hides while the user is actively
                    // typing.
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 0,
                      minHeight: 0,
                    ),
                    suffixIcon: showModelButton
                        ? _ModelButton(
                            enabled: model.canChangeModel,
                            onTap: onOpenModelBanner,
                          )
                        : null,
                  ),
                  enabled: !model.busyGate.mutating,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (model.status == 'busy' || model.status == 'retry')
              IconButton(
                tooltip: 'Stop response',
                onPressed: online && !busy ? model.abort : null,
                icon: const Icon(Icons.stop_circle_outlined),
              ),
            const SizedBox(width: 8),
            ValueListenableBuilder(
              valueListenable: draft,
              builder: (context, value, _) {
                final mode = model.promptMode;
                final label = model.isSending
                    ? 'Sending'
                    : answeringQuestion
                    ? 'Answer'
                    : switch (mode) {
                        PromptMode.build => 'Send · Build',
                        PromptMode.plan => 'Send · Plan',
                        null => 'Send',
                      };
                return CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.f10, shift: true):
                        onChoosePromptMode,
                  },
                  child: Tooltip(
                    message: '$label. Long press to change mode',
                    triggerMode: TooltipTriggerMode.manual,
                    excludeFromSemantics: true,
                    child: MergeSemantics(
                      child: Semantics(
                        label: label,
                        hint: 'Long press to change mode',
                        liveRegion: model.isSending,
                        child: FilledButton(
                          key: const ValueKey('chat-send'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            maximumSize: const Size(48, 48),
                            padding: EdgeInsets.zero,
                            shape: const CircleBorder(),
                            backgroundColor: mode == PromptMode.plan
                                ? AppTheme.info
                                : null,
                            foregroundColor: mode == PromptMode.plan
                                ? Colors.white
                                : null,
                          ),
                          onLongPress: model.canChangePromptMode
                              ? onChoosePromptMode
                              : null,
                          onPressed:
                              model.canSend && value.text.trim().isNotEmpty
                              ? () async {
                                  final text = draft.text;
                                  final accepted = answeringQuestion
                                      ? await model.answerQuestionAtWithText(
                                          model.answeringQuestionIndex!,
                                          text,
                                        )
                                      : await model.send(text);
                                  if (accepted &&
                                      context.mounted &&
                                      draft.text == text) {
                                    draft.clear();
                                  }
                                }
                              : null,
                          child: ExcludeSemantics(
                            child: model.isSending
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    mode == PromptMode.plan
                                        ? Icons.edit_note
                                        : Icons.arrow_upward,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    ),
  );
}

/// The composer's model button: an icon-only tap target that raises the
/// model/effort banner. The model's name lives in the banner and the chat
/// header, so it isn't repeated here.
class _ModelButton extends StatelessWidget {
  const _ModelButton({required this.enabled, required this.onTap});
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The tooltip belongs to the button itself, not a wrapper: only then does
    // its message merge into the button's own semantics node and give this
    // icon-only target the label screen readers need.
    return IconButton(
      onPressed: enabled ? onTap : null,
      tooltip: 'Model and effort',
      icon: const Icon(Icons.auto_awesome, size: 18),
      style: IconButton.styleFrom(
        foregroundColor: AppTheme.ink,
        disabledForegroundColor: AppTheme.muted,
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const CircleBorder(),
      ),
    );
  }
}
