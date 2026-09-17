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
  State<ConversationView> createState() => ConversationViewState();
}

class ConversationViewState extends State<ConversationView> {
  final _scroll = ScrollController();
  bool _checkScheduled = false;
  late int _revision;
  final _expandedShells = <(String, String)>{};
  late int _shellRevision;
  ChatMessage? _renderedLatest;
  bool _renderedTyping = false;
  final _messageAnchors = <String, GlobalKey>{};
  (String, double)? _readingAnchor;
  String? _pendingScrollTarget;
  int _pendingScrollAttempts = 0;
  double? _pendingScrollLow;
  double? _pendingScrollHigh;
  static const _maxScrollRefineAttempts = 8;

  /// The user message currently nearest the top of the viewport, for
  /// [MessageTickBar] to highlight. Only reassigned while at least one
  /// user-message anchor is actually attached -- see [_updateNavigationState]
  /// -- so it never flickers to null while scrolling past long assistant
  /// replies with no user-message anchor nearby.
  final currentUserMessageId = ValueNotifier<String?>(null);

  /// Whether the list has scrolled away from the newest message, for a
  /// jump-to-latest affordance to show itself.
  final isScrolledFromLatest = ValueNotifier<bool>(false);

  /// The message a tick-bar jump just landed on, briefly, so a tap has a
  /// visible answer to "which one did that just pick" once the scroll
  /// settles -- see [_refinePendingScroll] and [_highlightMessage].
  final highlightedMessageId = ValueNotifier<String?>(null);
  Timer? _highlightTimer;

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
        _clearPendingScroll();
        currentUserMessageId.value = null;
        _highlightTimer?.cancel();
        highlightedMessageId.value = null;
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
      _refinePendingScroll();
      _updateNavigationState();
      // The list grows from the bottom: extentAfter is the distance to older
      // history. Prepending messages leaves existing rows at the same offset.
      // Suppressed while a scrollToMessage jump is in flight: its target is
      // already loaded (a tick only exists for a rendered message), and
      // pagination prepending more history mid-jump would shift the total
      // scroll extent out from under the estimate.
      if (_scroll.position.extentAfter <= 240 &&
          !_scroll.position.outOfRange &&
          model.canLoadEarlierMessages &&
          model.error == null &&
          model.earlierMessagesError == null &&
          _pendingScrollTarget == null) {
        unawaited(model.olderMessages());
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    model.removeListener(_scheduleCheck);
    _scroll.dispose();
    currentUserMessageId.dispose();
    isScrolledFromLatest.dispose();
    _highlightTimer?.cancel();
    highlightedMessageId.dispose();
    super.dispose();
  }

  /// Scrolls toward [messageId], starting from a proportional estimate and
  /// then narrowing in by bisection (see [_refinePendingScroll]) once its
  /// row is actually built. There is no exact index-to-pixel mapping
  /// available up front: item heights vary too much (tool runs, images,
  /// condensed activity) for `ListView.builder` to place an arbitrary,
  /// possibly-unbuilt message precisely on the first try. Silently gives up
  /// if [messageId] no longer exists (e.g. a history reset raced the tap
  /// that triggered this).
  void scrollToMessage(String messageId) {
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) return;
    final ids = [for (final m in visibleMessages(model.messages)) m.id];
    if (!ids.contains(messageId)) return;
    final position = _scroll.position;
    _pendingScrollTarget = messageId;
    _pendingScrollAttempts = 0;
    _pendingScrollLow = position.minScrollExtent;
    _pendingScrollHigh = position.maxScrollExtent;
    _scroll.jumpTo(_estimatedOffsetFor(messageId) ?? position.pixels);
    _scheduleCheck();
  }

  /// A proportional guess at [messageId]'s scroll offset, using its ordinal
  /// position among every currently loaded, rendered message against the
  /// list's current total extent. Only ever used as a *starting point* --
  /// accurate when message sizes are fairly uniform, but a long
  /// conversation routinely mixes short prompts with huge tool output, so
  /// [_refinePendingScroll] narrows in from here by bisection rather than
  /// trusting this estimate to be precise.
  double? _estimatedOffsetFor(String messageId) {
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) {
      return null;
    }
    final ids = [for (final m in visibleMessages(model.messages)) m.id];
    final index = ids.indexOf(messageId);
    if (index < 0) return null;
    final position = _scroll.position;
    final reversedIndex = ids.length - 1 - index;
    final proportion = ids.length <= 1 ? 0.0 : reversedIndex / (ids.length - 1);
    return (proportion * position.maxScrollExtent)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
  }

  /// Snaps back to the newest message. The list is reversed, so the newest
  /// message always sits at exactly offset zero -- unlike [scrollToMessage],
  /// this needs no estimate.
  void scrollToLatest() {
    if (!_scroll.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(0);
    } else {
      unawaited(
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  /// Aligns [_pendingScrollTarget] toward the top of the viewport once
  /// [scrollToMessage]'s estimated jump has let `ListView.builder` build its
  /// row, reusing the same shift-and-jump technique as the reading-anchor
  /// correction above.
  ///
  /// While the row still isn't built, narrows toward it by bisection rather
  /// than trusting the initial proportional estimate to already be close:
  /// whichever message row *is* currently built nearest the viewport says
  /// whether the target lies further toward the older end or the newer end,
  /// which halves the remaining search range every attempt regardless of
  /// how unevenly sized the conversation's messages are (a single tool dump
  /// can dwarf a dozen short prompts). [_pendingScrollLow]/[_pendingScrollHigh]
  /// hold that shrinking range; [scrollToMessage] seeds them to the whole
  /// scrollable extent. Gives up, capped at [_maxScrollRefineAttempts],
  /// rather than looping forever if the row is never built, or immediately
  /// if the target message stops existing altogether (e.g. a history reset
  /// raced the tap).
  void _refinePendingScroll() {
    final target = _pendingScrollTarget;
    if (target == null) return;
    final ids = [for (final m in visibleMessages(model.messages)) m.id];
    final targetIndex = ids.indexOf(target);
    if (targetIndex < 0) {
      _clearPendingScroll();
      return;
    }
    final viewport = context.findRenderObject();
    final box = _messageAnchors[target]?.currentContext?.findRenderObject();
    if (box is RenderBox &&
        box.attached &&
        box.hasSize &&
        viewport is RenderBox &&
        viewport.hasSize) {
      final position = _scroll.position;
      const clearance = 56.0;
      final desiredDy = viewport.localToGlobal(Offset.zero).dy + clearance;
      final shift = desiredDy - box.localToGlobal(Offset.zero).dy;
      final offset = (position.pixels + shift)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((offset - position.pixels).abs() > 0.5) _scroll.jumpTo(offset);
      _clearPendingScroll();
      _highlightMessage(target);
      return;
    }
    _pendingScrollAttempts++;
    if (_pendingScrollAttempts >= _maxScrollRefineAttempts) {
      _clearPendingScroll();
      return;
    }
    final position = _scroll.position;
    var low = _pendingScrollLow ?? position.minScrollExtent;
    var high = _pendingScrollHigh ?? position.maxScrollExtent;
    final referenceId = _nearestBuiltMessageId(viewport);
    final referenceIndex = referenceId == null ? -1 : ids.indexOf(referenceId);
    if (referenceIndex >= 0 && referenceIndex != targetIndex) {
      // ids is chronological (oldest first); a higher index is newer, which
      // this reversed list keeps at a *smaller* pixel offset. Whichever side
      // of pixels the reference row falls on says which half still needs
      // searching.
      if (referenceIndex > targetIndex) {
        low = position.pixels;
      } else {
        high = position.pixels;
      }
    }
    _pendingScrollLow = low;
    _pendingScrollHigh = high;
    _scroll.jumpTo(
      ((low + high) / 2)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
    );
    _scheduleCheck();
  }

  void _clearPendingScroll() {
    _pendingScrollTarget = null;
    _pendingScrollAttempts = 0;
    _pendingScrollLow = null;
    _pendingScrollHigh = null;
  }

  /// Briefly marks [messageId] as [highlightedMessageId], so a tick tap has
  /// a visible answer to "which message did that just land on" once the
  /// jump settles. Replaces any highlight already in flight rather than
  /// stacking timers.
  void _highlightMessage(String messageId) {
    _highlightTimer?.cancel();
    highlightedMessageId.value = messageId;
    _highlightTimer = Timer(const Duration(milliseconds: 1800), () {
      if (highlightedMessageId.value == messageId) {
        highlightedMessageId.value = null;
      }
    });
  }

  /// The id of whichever built, attached message row sits closest to the
  /// viewport's top edge, optionally restricted by [where] -- shared by
  /// [_updateNavigationState] (looking only at user messages, to highlight
  /// the current tick) and [_refinePendingScroll] (looking at any message,
  /// as a directional reference point while bisecting toward a target).
  String? _nearestBuiltMessageId(
    RenderObject? viewport, {
    bool Function(ChatMessage)? where,
  }) {
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final viewportTop = viewport.localToGlobal(Offset.zero).dy;
    final byId = where == null
        ? null
        : {for (final m in model.messages) m.id: m};
    String? closestId;
    double? closestDistance;
    for (final entry in _messageAnchors.entries) {
      if (where != null) {
        final message = byId![entry.key];
        if (message == null || !where(message)) continue;
      }
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final distance = (box.localToGlobal(Offset.zero).dy - viewportTop).abs();
      if (closestDistance == null || distance < closestDistance) {
        closestDistance = distance;
        closestId = entry.key;
      }
    }
    return closestId;
  }

  /// Recomputes which user message sits nearest the top of the viewport (for
  /// [MessageTickBar]'s highlight) and whether the list has scrolled away
  /// from the newest message (for a jump-to-latest affordance), reusing the
  /// same per-frame pass as the rest of [_scheduleCheck] rather than adding a
  /// second listener pipeline.
  void _updateNavigationState() {
    isScrolledFromLatest.value = _scroll.position.pixels > 280;
    final closestId = _nearestBuiltMessageId(
      context.findRenderObject(),
      where: (m) => m.role == 'user',
    );
    if (closestId != null) {
      currentUserMessageId.value = closestId;
    } else if (!model.messages.any((m) => m.role == 'user')) {
      // Only clear on an empty conversation: leave the last-known tick
      // highlighted rather than flickering to null while scrolled past a
      // long run of assistant content with no user-message anchor nearby.
      currentUserMessageId.value = null;
    }
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
    final credentialNotice = model.pendingCredentialNotice;
    final lead = (showTyping ? 1 : 0) + (credentialNotice == null ? 0 : 1);
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
          itemCount: messages.length + 1 + lead,
          findChildIndexCallback: (key) {
            if (key == const ValueKey('typing-indicator')) {
              return showTyping ? 0 : null;
            }
            if (key == const ValueKey('credential-notice')) {
              return credentialNotice == null ? null : (showTyping ? 1 : 0);
            }
            final index = messages.indexWhere(
              (message) => ValueKey('message-${message.id}') == key,
            );
            return index < 0 ? null : messages.length - 1 - index + lead;
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
            // The newest end of the reversed list, so a renewal appears where the latest
            // activity is rather than buried above older messages.
            if (credentialNotice != null && index == 0) {
              return Padding(
                key: const ValueKey('credential-notice'),
                padding: const EdgeInsets.only(bottom: 12),
                child: InlineNotice(message: credentialNotice),
              );
            }
            if (credentialNotice != null) index--;
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
              // Briefly tinted after a tick-bar jump lands here (see
              // highlightedMessageId), so the tap has a visible answer to
              // which message it actually picked. Painted *over* the row in
              // a Stack rather than behind it: every tick targets a user
              // message, and _UserBubble paints its own opaque background,
              // which would otherwise hide a highlight sitting behind it
              // almost entirely. Neither the overlay nor its Stack add a
              // Container, since _UserBubble's own Container is how tests
              // (and the plan-mode rule) tell "the message's own decoration"
              // apart from any wrapper around it.
              child: ValueListenableBuilder<String?>(
                valueListenable: highlightedMessageId,
                builder: (context, highlighted, child) =>
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                        end: highlighted == message.id ? 1 : 0,
                      ),
                      duration: Duration(
                        milliseconds: highlighted == message.id ? 150 : 700,
                      ),
                      curve: Curves.easeOut,
                      builder: (context, opacity, child) => Stack(
                        children: [
                          child!,
                          if (opacity > 0)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Opacity(
                                  opacity: opacity,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: AppTheme.lime.withValues(
                                        alpha: 0.45,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      child: child,
                    ),
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
