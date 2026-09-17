import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../conversation_view_model.dart';
import '../domain/tool_run.dart';
import 'conversation_view.dart';

/// A slim, always-visible strip of tick marks along the trailing edge of the
/// conversation, one per user-sent prompt, so a long chat stays navigable at
/// a glance. Tapping a tick jumps to that prompt via
/// [ConversationViewState.scrollToMessage]. Absent below two prompts --
/// with only one, there's nowhere else to jump.
class MessageTickBar extends StatelessWidget {
  const MessageTickBar({
    super.key,
    required this.model,
    required this.conversationKey,
  });

  final ConversationViewModel model;
  final GlobalKey<ConversationViewState> conversationKey;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final ids = userMessageIds(model.messages);
      final state = conversationKey.currentState;
      if (ids.length < 2 || state == null) return const SizedBox.shrink();
      return ValueListenableBuilder<String?>(
        valueListenable: state.currentUserMessageId,
        builder: (context, currentId, _) => _TickColumn(
          ids: ids,
          currentId: currentId,
          onTap: (id) => conversationKey.currentState?.scrollToMessage(id),
        ),
      );
    },
  );
}

/// The tick marks themselves: a faint pill drawn at a fixed visual width
/// behind a wider invisible tap column, since the height available per tick
/// shrinks with a long conversation long before its width needs to.
class _TickColumn extends StatelessWidget {
  const _TickColumn({
    required this.ids,
    required this.currentId,
    required this.onTap,
  });

  final List<String> ids;
  final String? currentId;
  final ValueChanged<String> onTap;

  static const _preferredSlot = 14.0;
  static const _minSlot = 6.0;
  static const _tapWidth = 32.0;
  static const _trackWidth = 16.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxHeight;
      final n = ids.length;
      final slot = (available / n).clamp(_minSlot, _preferredSlot);
      final trackHeight = slot * n;
      final stack = SizedBox(
        width: _tapWidth,
        height: trackHeight,
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            Container(
              width: _trackWidth,
              height: trackHeight,
              decoration: BoxDecoration(
                color: AppTheme.softBorder.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(_trackWidth / 2),
              ),
            ),
            Column(
              children: [
                for (var i = 0; i < n; i++)
                  _Tick(
                    index: i,
                    total: n,
                    slot: slot,
                    current: ids[i] == currentId,
                    onTap: () => onTap(ids[i]),
                  ),
              ],
            ),
          ],
        ),
      );
      if (trackHeight <= available) {
        return SizedBox(
          height: available,
          child: Center(child: stack),
        );
      }
      // More prompts than fit even at the minimum pitch: the strip scrolls
      // on its own, independent of the conversation's own scroll controller,
      // rather than compressing ticks past a tappable size.
      return SizedBox(
        height: available,
        child: SingleChildScrollView(child: stack),
      );
    },
  );
}

/// One tick. Its own tap target stays a fixed, comfortable width even when
/// the slot's height is squeezed by a long conversation. The current tick
/// is both larger and darker than the rest -- never color alone -- matching
/// the same rule the task list's own rows follow.
class _Tick extends StatelessWidget {
  const _Tick({
    required this.index,
    required this.total,
    required this.slot,
    required this.current,
    required this.onTap,
  });

  final int index;
  final int total;
  final double slot;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      button: true,
      selected: current,
      label: 'Jump to your message ${index + 1} of $total',
      child: SizedBox(
        height: slot,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: current ? 5 : 3,
                height: current ? 10 : 6,
                decoration: BoxDecoration(
                  color: current ? AppTheme.ink : AppTheme.muted,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A small round button that appears once the conversation has scrolled away
/// from its newest message, so getting back to the live edge never requires
/// scrolling all the way down by hand. The newest message always sits at
/// exactly scroll offset zero in the reversed list, so
/// [ConversationViewState.scrollToLatest] needs no estimate the way
/// [ConversationViewState.scrollToMessage] does.
class JumpToLatestButton extends StatelessWidget {
  const JumpToLatestButton({super.key, required this.conversationKey});

  final GlobalKey<ConversationViewState> conversationKey;

  @override
  Widget build(BuildContext context) {
    final state = conversationKey.currentState;
    if (state == null) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: state.isScrolledFromLatest,
      builder: (context, visible, child) => IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: visible ? 1 : 0,
          child: child,
        ),
      ),
      child: Semantics(
        button: true,
        label: 'Jump to latest message',
        child: Material(
          color: AppTheme.ink,
          shape: const CircleBorder(),
          elevation: 3,
          shadowColor: AppTheme.ink.withValues(alpha: 0.4),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => conversationKey.currentState?.scrollToLatest(),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Icon(Icons.arrow_downward, size: 20, color: AppTheme.lime),
            ),
          ),
        ),
      ),
    );
  }
}
