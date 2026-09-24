import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui/core/app_theme.dart';
import '../../../ui/core/confirm_dialog.dart';
import '../conversation_view_model.dart';

/// The conversation's draft input row: the message field, its model/effort
/// suffix button, and the primary button, which is the send button
/// (long-press to change Build/Plan mode) or, while a response is in flight
/// with nothing typed, a Stop button to abort it.
/// Typing a message while the agent works turns the button back into the
/// send button so the prompt can be queued under the current Build/Plan mode.
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

  /// Asks before aborting, since stopping the agent discards in-flight work,
  /// then aborts only if the session is still live and still working when the
  /// user confirms -- the chat may have finished while the dialog was up.
  Future<void> _confirmStop(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const ConfirmDialog(
        title: 'Stop the agent?',
        content: Text(
          'Stop the current response before it finishes? Anything the agent already wrote stays in the chat.',
        ),
        confirmLabel: 'Stop agent',
        destructive: true,
      ),
    );
    if (confirmed == true &&
        context.mounted &&
        model.online() &&
        (model.status == 'busy' || model.status == 'retry')) {
      await model.abort();
    }
  }

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
            ValueListenableBuilder(
              valueListenable: draft,
              builder: (context, value, _) {
                final mode = model.promptMode;
                // The primary button doubles as the Stop control: while the
                // agent works, an empty draft shows Stop, and typing turns it
                // back into the send button so the prompt can be queued under
                // the selected Build/Plan mode. A pending custom-question
                // answer keeps the Answer button instead, and the in-flight
                // "Sending" spinner is never replaced by a Stop.
                final working =
                    model.status == 'busy' || model.status == 'retry';
                final showStop =
                    working &&
                    value.text.trim().isEmpty &&
                    !model.isSending &&
                    !answeringQuestion;
                final label = showStop
                    ? 'Stop response'
                    : model.isSending
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
                    message: showStop
                        ? label
                        : '$label. Long press to change mode',
                    triggerMode: TooltipTriggerMode.manual,
                    excludeFromSemantics: true,
                    child: MergeSemantics(
                      child: Semantics(
                        label: label,
                        hint: showStop ? null : 'Long press to change mode',
                        liveRegion: model.isSending,
                        child: FilledButton(
                          key: const ValueKey('chat-send'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            maximumSize: const Size(48, 48),
                            padding: EdgeInsets.zero,
                            shape: const CircleBorder(),
                            backgroundColor: showStop
                                ? Theme.of(context).colorScheme.error
                                : mode == PromptMode.plan
                                ? AppTheme.info
                                : null,
                            foregroundColor: showStop
                                ? Theme.of(context).colorScheme.onError
                                : mode == PromptMode.plan
                                ? Colors.white
                                : null,
                          ),
                          onLongPress: showStop || !model.canChangePromptMode
                              ? null
                              : onChoosePromptMode,
                          onPressed: showStop
                              ? online && !busy
                                    ? () => unawaited(_confirmStop(context))
                                    : null
                              : model.canSend && value.text.trim().isNotEmpty
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
                            child: !showStop && model.isSending
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    showStop
                                        ? Icons.stop
                                        : mode == PromptMode.plan
                                        ? Icons.edit_note
                                        : Icons.arrow_forward,
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
