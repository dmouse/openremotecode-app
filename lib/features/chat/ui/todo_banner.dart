import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../conversation_view_model.dart';
import '../domain/chat_models.dart';

/// The task tab: an inverted tab -- dark ink filled, a lime checklist glyph, a
/// light "Tasks" label and a lime "2/5" count -- for the chat's own task list.
/// It hangs *down* from the middle of the conversation header, flat across the
/// top so it continues the bar's own edge and rounded only on the two corners
/// that drop into the chat, tight around its one line of text, and it floats
/// over the conversation rather than sitting in a strip of its own: the
/// messages keep their full height and scroll underneath it. Absent entirely
/// while the chat has no task list, or once the user hides a finished one
/// from [TodoBanner].
///
/// Tapping it raises [TodoBanner]. The tab itself never changes the list:
/// OpenCode's agent writes it, this app counts it. See CHAT-TODOS.md.
class TodoTab extends StatelessWidget {
  const TodoTab({super.key, required this.model, required this.onTap});
  final ConversationViewModel model;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final total = model.todosTotal;
    if (total == 0 || model.todosHidden) return const SizedBox.shrink();
    final done = model.todosDone;
    final text = Theme.of(context).textTheme;
    return MergeSemantics(
      child: Semantics(
        button: true,
        // The count is read as words, never as "two slash five", and the
        // live region announces a task ticking over while the chat is open.
        label: 'Tasks, $done of $total done',
        hint: 'Open the task list',
        liveRegion: true,
        child: Tooltip(
          message: 'Tasks · $done of $total done',
          excludeFromSemantics: true,
          child: Material(
            color: AppTheme.ink,
            // Curved at both ends of the header line it grows out of, and
            // rounded on the two corners that hang in the conversation.
            shape: const _HangingTab(),
            // It sits above the messages, so it casts over them instead of
            // being read as another flat band of chrome.
            elevation: 3,
            shadowColor: AppTheme.ink.withValues(alpha: 0.4),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('todo-tab'),
              onTap: onTap,
              child: Padding(
                // The label sets the tab's height: it hugs its one line rather
                // than padding itself out to a full tap target, which would
                // leave dead ink between the header's edge and the words. The
                // visible tab is the whole target -- nothing invisible hangs
                // below it to swallow taps meant for a message.
                //
                // Width is the one dimension it spends freely: the side padding
                // is wide so the tab reads as a tab across the header rather
                // than a chip, and widening it costs the conversation nothing,
                // since the tab hangs over the messages instead of displacing
                // them.
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.checklist, size: 14, color: AppTheme.lime),
                    const SizedBox(width: 6),
                    // The tab has room the header never did, so it names what
                    // it counts instead of leaving a bare ratio to be guessed
                    // at.
                    Text(
                      'Tasks',
                      style: text.bodySmall?.copyWith(
                        color: AppTheme.background,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$done/$total',
                      style: text.bodySmall?.copyWith(
                        color: AppTheme.lime,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [TodoTab]'s outline: a tab that grows out of the header rather than being
/// stuck onto it. Where it starts and ends -- the two top corners sitting on
/// the header's hairline -- the ink flares sideways past the tab's own box and
/// curves back in, a concave [shoulder] on each side that fillets the join the
/// way a branch meets a trunk. The two corners hanging in the conversation
/// round the ordinary way, by [corner].
///
/// The shoulders are drawn outside the tab's box on purpose: they belong to the
/// header's edge, not to the label, so widening them never moves the text and
/// never grows the tap target sideways into the conversation.
class _HangingTab extends OutlinedBorder {
  const _HangingTab({this.shoulder = 10, this.corner = 14});
  final double shoulder, corner;

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    // Both radii are clamped to the tab's own box, so a scaled-up or unusually
    // short tab bends less rather than folding its outline inside out.
    final flare = math.min(shoulder, rect.height / 2);
    final round = math.min(
      math.min(corner, rect.height - flare),
      rect.width / 2,
    );
    return Path()
      // Out on the header line, left of the tab, curving down into its side.
      ..moveTo(rect.left - flare, rect.top)
      ..arcTo(
        Rect.fromCircle(
          center: Offset(rect.left - flare, rect.top + flare),
          radius: flare,
        ),
        -math.pi / 2,
        math.pi / 2,
        false,
      )
      ..lineTo(rect.left, rect.bottom - round)
      ..arcTo(
        Rect.fromCircle(
          center: Offset(rect.left + round, rect.bottom - round),
          radius: round,
        ),
        math.pi,
        -math.pi / 2,
        false,
      )
      ..lineTo(rect.right - round, rect.bottom)
      ..arcTo(
        Rect.fromCircle(
          center: Offset(rect.right - round, rect.bottom - round),
          radius: round,
        ),
        math.pi / 2,
        -math.pi / 2,
        false,
      )
      ..lineTo(rect.right, rect.top + flare)
      ..arcTo(
        Rect.fromCircle(
          center: Offset(rect.right + flare, rect.top + flare),
          radius: flare,
        ),
        math.pi,
        math.pi / 2,
        false,
      )
      // Closing runs straight back along the header line it started on.
      ..close();
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  // Nothing outlines the tab: it is a filled shape, so there is no side to
  // paint.
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  OutlinedBorder copyWith({BorderSide? side}) =>
      _HangingTab(shoulder: shoulder, corner: corner);

  @override
  ShapeBorder scale(double t) =>
      _HangingTab(shoulder: shoulder * t, corner: corner * t);
}

/// The task list itself: a bottom sheet raised by [TodoTab],
/// listing OpenCode's own tasks for this chat in its order, each with an icon
/// and its state in words. Read-only -- there is nothing to tap in a row.
///
/// A cancelled task keeps its place in the list and in the tab's denominator:
/// the count reports the plan as the agent wrote it, and the row says the task
/// was dropped rather than the total quietly shrinking underneath it.
///
/// A finished list can be dismissed from here, which hides the tab and so the
/// only way back into this sheet -- so the sheet offers that only where the
/// undo lives, in the main chat's Chat options menu. A subtask conversation
/// has no such menu, and therefore no Hide.
class TodoBanner extends StatelessWidget {
  const TodoBanner({super.key, required this.model});
  final ConversationViewModel model;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final todos = model.todos;
    final done = model.todosDone;
    final total = model.todosTotal;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MergeSemantics(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Tasks',
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.ink,
                        ),
                      ),
                    ),
                    Text(
                      total == 0 ? 'None' : '$done of $total done',
                      style: text.bodySmall?.copyWith(color: AppTheme.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              if (total > 0)
                // Decorative: the count above already says "1 of 5 done" in
                // words, and a progress bar repeating it as a percentage only
                // adds a second thing to read.
                ExcludeSemantics(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: done / total,
                      minHeight: 6,
                      // A brand fill, not a success signal: the row icons and
                      // labels say which tasks are actually done.
                      color: AppTheme.lime,
                      backgroundColor: AppTheme.neutralSurface,
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              Flexible(
                child: todos.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'This chat has no task list yet.',
                          style: text.bodyMedium,
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(top: 8),
                        itemCount: todos.length,
                        itemBuilder: (context, index) =>
                            _TodoRow(todo: todos[index]),
                      ),
              ),
              // Only once every task is done: hiding a list still in progress
              // would drop the one place its status is visible. And only in
              // the main chat, where Chat options can bring it back -- a
              // subtask has no menu to undo it from.
              if (total > 0 && done == total && !model.isSubtask)
                Align(
                  alignment: Alignment.centerRight,
                  // The hint says what the label cannot: the list itself
                  // survives being hidden, and where to ask for it back.
                  child: MergeSemantics(
                    child: Semantics(
                      hint: 'The list is kept. Show it again from Chat options',
                      child: TextButton.icon(
                        key: const ValueKey('todo-hide'),
                        onPressed: () {
                          model.hideTodos();
                          Navigator.of(context).maybePop();
                        },
                        icon: const Icon(Icons.visibility_off, size: 18),
                        label: const Text('Hide task list'),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One task: its state icon, its text, and that state in words underneath.
/// State never rests on color or an icon alone.
class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.todo});
  final ChatTodo todo;

  (IconData, Color) get _mark => switch (todo.status) {
    'completed' => (Icons.check_circle, AppTheme.success),
    'in_progress' => (Icons.radio_button_checked, AppTheme.ink),
    'cancelled' => (Icons.cancel_outlined, AppTheme.muted),
    _ => (Icons.radio_button_unchecked, AppTheme.muted),
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final (icon, color) = _mark;
    final spent = todo.done || todo.cancelled;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Excluded from semantics: the row's own label already says the
            // state in words, so the icon would only repeat it.
            ExcludeSemantics(child: Icon(icon, size: 20, color: color)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // Plain text, never Markdown: a task's words are the
                    // agent's, and nothing here renders as markup.
                    todo.content,
                    style: text.bodyLarge?.copyWith(
                      color: spent ? AppTheme.muted : AppTheme.ink,
                      fontWeight: todo.running
                          ? FontWeight.w600
                          : FontWeight.w400,
                      decoration: todo.cancelled
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  Text(
                    todo.label,
                    style: text.bodySmall?.copyWith(color: AppTheme.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
