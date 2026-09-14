import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../../../ui/core/inline_notice.dart';
import '../conversation_view_model.dart';
import '../domain/chat_models.dart';
import '../domain/tool_run.dart';
import 'image_message.dart';
import 'markdown_message.dart';
import 'subtask_view.dart';
import 'thought_view.dart';
import 'tool_run_view.dart';
import 'tool_view.dart';
import 'activity_animation.dart';
import 'typing_indicator.dart';

class ConversationView extends StatefulWidget {
  const ConversationView({super.key, required this.model, this.onOpenSubtask});
  final ConversationViewModel model;
  final ValueChanged<ChatSubtask>? onOpenSubtask;

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  final _scroll = ScrollController();
  bool _checkScheduled = false;
  late int _revision;
  final _expandedShells = <(String, String)>{};
  late int _shellRevision;
  ChatMessage? _renderedLatest;
  bool _renderedTyping = false;
  final _messageAnchors = <String, GlobalKey>{};
  (String, double)? _readingAnchor;
  ConversationViewModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    _revision = model.messageHistoryRevision;
    _shellRevision = model.messageHistoryRevision;
    model.addListener(_scheduleCheck);
    _scroll.addListener(_scheduleCheck);
    _scheduleCheck();
  }

  @override
  void didUpdateWidget(ConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != model) {
      oldWidget.model.removeListener(_scheduleCheck);
      model.addListener(_scheduleCheck);
      _revision = -1;
      _shellRevision = -1;
    }
    _scheduleCheck();
  }

  void _scheduleCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted ||
          !_scroll.hasClients ||
          !_scroll.position.hasContentDimensions) {
        return;
      }
      if (_revision != model.messageHistoryRevision) {
        _revision = model.messageHistoryRevision;
        _readingAnchor = null;
        _scroll.jumpTo(0);
        _scheduleCheck();
        return;
      }
      if (_readingAnchor case final anchor?) {
        _readingAnchor = null;
        final box = _messageAnchors[anchor.$1]?.currentContext
            ?.findRenderObject();
        if (box is RenderBox && box.attached && box.hasSize) {
          final position = _scroll.position;
          final shift = anchor.$2 - box.localToGlobal(Offset.zero).dy;
          final offset = (position.pixels + shift)
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();
          if ((offset - position.pixels).abs() > 0.5) _scroll.jumpTo(offset);
        }
      }
      // The list grows from the bottom: extentAfter is the distance to older
      // history. Prepending messages leaves existing rows at the same offset.
      if (_scroll.position.extentAfter <= 240 &&
          !_scroll.position.outOfRange &&
          model.canLoadEarlierMessages &&
          model.error == null &&
          model.earlierMessagesError == null) {
        unawaited(model.olderMessages());
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    model.removeListener(_scheduleCheck);
    _scroll.dispose();
    super.dispose();
  }

  /// Renders a single part exactly as before condensing was introduced; used
  /// for every part that [condenseToolRuns] left standing on its own (a
  /// subtask, a reasoning block, an image, prose, or a tool run too short to
  /// condense). Returns null for a part that renders nothing (blank text).
  Widget? _buildPart(ChatMessage message, ChatMessagePart part) {
    if (part.task case final task?) {
      return SubtaskView(
        key: ValueKey(part.id),
        task: task,
        online: model.activityLive,
        onOpen:
            task.sessionId != null &&
                model.online() &&
                widget.onOpenSubtask != null
            ? () => widget.onOpenSubtask!(task)
            : null,
      );
    }
    if (part.tool case final tool?) {
      return ToolView(
        key: ValueKey(part.id),
        tool: tool,
        activity: part.activity,
        expanded: _expandedShells.contains((message.id, part.id)),
        onToggle: () => setState(() {
          final id = (message.id, part.id);
          if (!_expandedShells.remove(id)) _expandedShells.add(id);
        }),
        online: model.online(),
        active:
            model.activityLive &&
            (part.activity != null || ['busy', 'retry'].contains(model.status)),
      );
    }
    if (part.isReasoning) {
      return ThoughtView(
        key: ValueKey(part.id),
        part: part,
        active:
            model.activityLive &&
            (part.activity != null || model.status == 'busy'),
      );
    }
    if (part.image case final image?) {
      return Padding(
        key: ValueKey(part.id),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ImageMessage(image: image),
      );
    }
    if (part.text.trim().isNotEmpty) {
      return Padding(
        key: ValueKey(part.id),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: message.role == 'assistant'
            ? _planRule(
                MarkdownMessage(text: part.text),
                id: part.id,
                plan: message.mode == 'plan',
              )
            : _UserBubble(text: part.text, plan: message.mode == 'plan'),
      );
    }
    return null;
  }

  /// Plan mode's mark on the agent's side: a rule down the left of what the
  /// agent itself says, which is what identifies planning at a glance while
  /// scrolling. It hugs the prose alone. Thought rows and tool runs keep their
  /// own gutters, icons and status lines, and a second rule beside those would
  /// only crowd them; the prompt that asked for the plan says so in its own
  /// corner instead -- see [_UserBubble].
  Widget _planRule(Widget child, {required String id, required bool plan}) =>
      plan
      ? Container(
          key: ValueKey('plan-rule-$id'),
          padding: const EdgeInsets.only(left: 10),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: AppTheme.info, width: 3)),
          ),
          child: child,
        )
      : child;

  @override
  Widget build(BuildContext context) {
    final latest = model.messages.lastOrNull;
    final showTyping = model.isSending || model.isWorking;
    if ((!identical(latest, _renderedLatest) ||
            showTyping != _renderedTyping) &&
        _revision == model.messageHistoryRevision &&
        _scroll.hasClients &&
        _scroll.position.hasContentDimensions &&
        _scroll.offset > 24) {
      // Anchor a visible message rather than the sliver's estimated total
      // extent, which changes its estimate when a small typing row is inserted.
      final viewport = context.findRenderObject();
      if (_readingAnchor == null && viewport is RenderBox && viewport.hasSize) {
        final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
        for (final entry in _messageAnchors.entries) {
          final box = entry.value.currentContext?.findRenderObject();
          if (box is RenderBox &&
              box.attached &&
              box.hasSize &&
              bounds.overlaps(box.localToGlobal(Offset.zero) & box.size)) {
            _readingAnchor = (entry.key, box.localToGlobal(Offset.zero).dy);
            break;
          }
        }
      }
    }
    _renderedLatest = latest;
    _renderedTyping = showTyping;
    final retainedIds = model.messages.map((m) => m.id).toSet();
    _messageAnchors.removeWhere((id, _) => !retainedIds.contains(id));
    if (_shellRevision != model.messageHistoryRevision) {
      _expandedShells.clear();
      _shellRevision = model.messageHistoryRevision;
    }
    // Empty projected records (including synthetic-only shell user messages) must not
    // introduce phantom gaps or break a run of activity rows.
    final messages = visibleMessages(model.messages);
    // OpenCode commonly emits one tool call per assistant turn rather than
    // batching several into one message's parts array, so a run of
    // consecutive tool-only messages must be merged into a single
    // cross-message ToolRun for condensing to have any real effect -- see
    // isPureToolMessage. mergedRuns maps each run's anchor (first) message
    // id to the merged run rendered there; suppressedMessageIds are the
    // rest of that run's messages, already covered by the anchor's row.
    final mergedRuns = <String, ToolRun>{};
    final suppressedMessageIds = <String>{};
    for (final (start, end) in pureToolMessageRuns(messages)) {
      mergedRuns[messages[start].id] = ToolRun(
        List.unmodifiable([
          for (var j = start; j <= end; j++) ...messages[j].parts!,
        ]),
      );
      for (var j = start + 1; j <= end; j++) {
        suppressedMessageIds.add(messages[j].id);
      }
    }
    // Retain only IDs from bounded, in-memory history, including off-screen
    // rows -- and only shell rows that still render inline; one absorbed
    // into a condensed ToolRun (same-message or, now, a merged cross-message
    // run) is only ever expandable inside its sheet, which keeps its own
    // separate, sheet-local expand state. Uses the cheaper
    // condensedShellPartIds (no ToolRun/plan allocation) since this runs
    // over every retained message, including off-screen ones, on every
    // rebuild -- not just whichever message is actually on screen.
    final shellIds = <(String, String)>{};
    for (final message in model.messages) {
      if (suppressedMessageIds.contains(message.id) ||
          mergedRuns.containsKey(message.id)) {
        continue;
      }
      final parts = message.parts;
      if (parts == null) continue;
      final absorbed = condensedShellPartIds(parts);
      for (final part in parts) {
        if (part.tool?.shell != null && !absorbed.contains(part.id)) {
          shellIds.add((message.id, part.id));
        }
      }
    }
    _expandedShells.removeWhere((id) => !shellIds.contains(id));
    return ActivityAnimations(
      enabled: model.activityLive || (model.isSending && model.online()),
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          _scheduleCheck();
          return false;
        },
        child: ListView.builder(
          controller: _scroll,
          reverse: true,
          padding: const EdgeInsets.all(20),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: messages.length + 1 + (showTyping ? 1 : 0),
          findChildIndexCallback: (key) {
            if (key == const ValueKey('typing-indicator')) {
              return showTyping ? 0 : null;
            }
            final index = messages.indexWhere(
              (message) => ValueKey('message-${message.id}') == key,
            );
            return index < 0
                ? null
                : messages.length - 1 - index + (showTyping ? 1 : 0);
          },
          itemBuilder: (context, index) {
            if (showTyping && index == 0) {
              return TypingIndicator(
                key: const ValueKey('typing-indicator'),
                sending: model.isSending,
                animate:
                    model.activityLive || (model.isSending && model.online()),
              );
            }
            if (showTyping) index--;
            if (index == messages.length) {
              return Column(
                children: [
                  if (model.earlierMessagesError case final message?) ...[
                    InlineNotice(message: message, isError: true),
                    TextButton.icon(
                      onPressed: model.canLoadEarlierMessages
                          ? model.olderMessages
                          : null,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry loading earlier messages'),
                    ),
                  ] else if (model.messageCursor != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: model.loadingEarlierMessages
                          ? Semantics(
                              liveRegion: true,
                              label: 'Loading earlier messages',
                              child: const ExcludeSemantics(
                                child: Center(
                                  child: SizedBox.square(
                                    dimension: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox(height: 24),
                    ),
                  if (model.messageHistoryNotice case final notice?)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(notice, textAlign: TextAlign.center),
                    ),
                  if (messages.isEmpty &&
                      !model.isSending &&
                      model.status != 'busy' &&
                      !model.busyGate.loading &&
                      model.error == null &&
                      model.earlierMessagesError == null &&
                      model.messageHistoryNotice == null &&
                      model.messageCursor == null)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Start this conversation with a message.'),
                    ),
                ],
              );
            }
            final message = messages[messages.length - 1 - index];
            if (suppressedMessageIds.contains(message.id)) {
              // Already rendered as part of an earlier message's merged
              // cross-message ToolRun (see mergedRuns above).
              return SizedBox.shrink(key: ValueKey('message-${message.id}'));
            }
            bool activityEdge(ChatMessage value, {required bool first}) {
              if (value.role != 'assistant') return false;
              final visible = value.parts?.where(
                (part) => part.type != 'text' || part.text.trim().isNotEmpty,
              );
              final edge = first ? visible?.firstOrNull : visible?.lastOrNull;
              return edge != null &&
                  (edge.tool != null || edge.isReasoning || edge.task != null);
            }

            // Keep keyed history rows intact, but don't insert a message-sized
            // gap in a continuous run of tools, thoughts and subtasks.
            final continuesActivity =
                index > 0 &&
                !message.truncated &&
                activityEdge(message, first: false) &&
                activityEdge(messages[messages.length - index], first: true);
            final planMode = message.mode == 'plan';
            return Padding(
              key: ValueKey('message-${message.id}'),
              padding: EdgeInsets.only(bottom: continuesActivity ? 0 : 12),
              child: Column(
                key: _messageAnchors.putIfAbsent(message.id, GlobalKey.new),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (mergedRuns[message.id] case final run?)
                    ToolRunView(
                      key: ValueKey('run-${run.parts.first.id}'),
                      run: run,
                      model: model,
                      messageId: message.id,
                      active:
                          model.activityLive &&
                          (run.parts.any((p) => p.activity != null) ||
                              ['busy', 'retry'].contains(model.status)),
                    )
                  else if (message.parts != null) ...[
                    for (final item in condenseToolRuns(message.parts!))
                      if (item is ToolRun)
                        ToolRunView(
                          key: ValueKey('run-${item.parts.first.id}'),
                          run: item,
                          model: model,
                          messageId: message.id,
                          active:
                              model.activityLive &&
                              (item.parts.any((p) => p.activity != null) ||
                                  ['busy', 'retry'].contains(model.status)),
                        )
                      else
                        ?_buildPart(message, item as ChatMessagePart),
                  ] else if (message.role == 'assistant')
                    _planRule(
                      MarkdownMessage(text: message.text),
                      id: message.id,
                      plan: planMode,
                    )
                  else
                    _UserBubble(text: message.text, plan: planMode),
                  if (message.truncated)
                    const Text('Long message shortened for display.'),
                  if (message.incomplete)
                    const Text(
                      'Waiting for the complete response from the agent.',
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A prompt the user sent: their own words on the code surface, the full width
/// of the conversation so every prompt starts and ends on the same edges as
/// the replies between them.
///
/// A prompt sent in Plan mode says so in its own bottom corner, quietly: muted
/// italic, small enough to stay out of the way of the words above it. That
/// reads to a screen reader as part of the message, which a colored rule down
/// the side never did.
class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, required this.plan});
  final String text;
  final bool plan;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    decoration: BoxDecoration(
      color: AppTheme.codeSurface,
      borderRadius: BorderRadius.circular(12),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText(
          text,
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: AppTheme.ink),
        ),
        if (plan)
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Plan',
              semanticsLabel: 'Sent in Plan mode',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 9,
                fontStyle: FontStyle.italic,
                color: AppTheme.muted,
              ),
            ),
          ),
      ],
    ),
  );
}
