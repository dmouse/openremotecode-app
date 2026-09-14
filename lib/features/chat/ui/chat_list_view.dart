import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../../../ui/core/inline_notice.dart';
import '../../../ui/core/search_field.dart';
import '../chat_view_model.dart';
import '../domain/chat_models.dart';

class ChatListView extends StatefulWidget {
  const ChatListView({super.key, required this.model, required this.search});

  final ChatViewModel model;
  final TextEditingController search;

  @override
  State<ChatListView> createState() => _ChatListViewState();
}

class _ChatListViewState extends State<ChatListView> {
  final _scroll = ScrollController();
  Timer? _searchDebounce;
  bool _checkScheduled = false;
  String _query = '';
  ChatViewModel get model => widget.model;
  TextEditingController get search => widget.search;

  @override
  void initState() {
    super.initState();
    _query = search.text.trim().toLowerCase();
    model.addListener(_scheduleCheck);
    search.addListener(_searchChanged);
    _scroll.addListener(_scheduleCheck);
    _scheduleCheck();
  }

  @override
  void didUpdateWidget(ChatListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != model) {
      oldWidget.model.removeListener(_scheduleCheck);
      model.addListener(_scheduleCheck);
    }
    if (oldWidget.search != search) {
      oldWidget.search.removeListener(_searchChanged);
      search.addListener(_searchChanged);
      _searchChanged();
    }
    _scheduleCheck();
  }

  void _searchChanged() {
    final query = search.text.trim().toLowerCase();
    if (query == _query) return;
    _query = query;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _scheduleCheck();
    });
  }

  void _scheduleCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    // Read final viewport dimensions after search, appended pages, or resizing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted ||
          _searchDebounce?.isActive == true ||
          !_scroll.hasClients ||
          !_scroll.position.hasContentDimensions ||
          _scroll.position.pixels < 0 ||
          _scroll.position.extentAfter > 320 ||
          model.page != ChatPage.chats ||
          !model.online ||
          model.loading ||
          model.mutating ||
          model.error != null ||
          model.chatList.moreChatsError != null ||
          model.chatList.chatCursor == null) {
        return;
      }
      unawaited(model.moreChats());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    model.removeListener(_scheduleCheck);
    search.removeListener(_searchChanged);
    _searchDebounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: search,
    builder: (context, value, _) {
      final query = value.text.trim().toLowerCase();
      final now = DateTime.now();
      final groups = <DateTime?, List<RemoteChat>>{};
      for (final chat in model.chatList.chats) {
        if (!chat.title.toLowerCase().contains(query)) continue;
        final local = chat.updatedAt.toLocal();
        final group = model.chatList.isPinned(chat)
            ? null
            : DateTime.utc(local.year, local.month, local.day);
        groups.putIfAbsent(group, () => []).add(chat);
      }
      final dates = groups.keys.toList()
        ..sort((a, b) {
          if (a == null) return b == null ? 0 : -1;
          if (b == null) return 1;
          return b.compareTo(a);
        });
      final entries = <Object?>[
        for (final date in dates) ...[date, ...groups[date]!],
      ];
      return NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          _scheduleCheck();
          return false;
        },
        child: RefreshIndicator(
          onRefresh: model.refresh,
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: SearchField(
                          controller: search,
                          hintText: model.chatList.chatCursor == null
                              ? 'Search chats'
                              : 'Search loaded chats',
                        ),
                      ),
                      const SizedBox(width: 12),
                      _NewChatButton(
                        onPressed:
                            model.online && !model.loading && !model.mutating
                            ? model.startNewChat
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  if (entry is RemoteChat) {
                    return Padding(
                      key: ValueKey('chat-${entry.id}'),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: _ChatRow(
                        chat: entry,
                        model: model,
                        now: now,
                        showDivider:
                            index + 1 < entries.length &&
                            entries[index + 1] is RemoteChat,
                      ),
                    );
                  }
                  return _SectionHeading(date: entry as DateTime?, now: now);
                },
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (groups.isEmpty &&
                          !model.loading &&
                          model.error == null &&
                          model.chatList.moreChatsError == null)
                        _EmptyChats(
                          searching: query.isNotEmpty,
                          hasMore: model.chatList.chatCursor != null,
                        ),
                      if (model.chatList.moreChatsError
                          case final message?) ...[
                        InlineNotice(message: message, isError: true),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          label: const Text('Retry loading chats'),
                          icon: const Icon(Icons.refresh),
                          onPressed:
                              model.online && !model.loading && !model.mutating
                              ? model.moreChats
                              : null,
                        ),
                      ] else if (model.chatList.chatCursor != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: model.loadingMoreChats
                              ? Semantics(
                                  liveRegion: true,
                                  label: query.isEmpty
                                      ? 'Loading older chats'
                                      : 'Searching older chats',
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
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _NewChatButton extends StatelessWidget {
  const _NewChatButton({required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      button: true,
      label: 'New chat',
      child: Tooltip(
        message: 'New chat',
        excludeFromSemantics: true,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            fixedSize: const Size(52, 52),
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: const ExcludeSemantics(child: Icon(Icons.add)),
        ),
      ),
    ),
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.date, required this.now});
  final DateTime? date;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    // UTC date-only values compare local calendar days without DST offsets.
    final age = date == null
        ? null
        : DateTime.utc(now.year, now.month, now.day).difference(date!).inDays;
    final relative = switch (age) {
      null => 'Pinned',
      0 => 'Today',
      1 => 'Yesterday',
      _ => null,
    };
    final color = switch (age) {
      null => AppTheme.warning,
      0 => AppTheme.success,
      1 => AppTheme.info,
      _ => AppTheme.muted,
    };
    final localizations = MaterialLocalizations.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
        child: Row(
          children: [
            ExcludeSemantics(
              child: SizedBox.square(
                dimension: 14,
                child: date == null
                    ? Icon(Icons.push_pin, size: 14, color: color)
                    : Center(
                        child: SizedBox.square(
                          dimension: 6,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text.rich(
                TextSpan(
                  text: relative ?? localizations.formatShortMonthDay(date!),
                  children: relative != null
                      ? null
                      : [
                          TextSpan(
                            text: ' ${localizations.formatYear(date!)}',
                            style: const TextStyle(
                              color: AppTheme.muted,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                ),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: AppTheme.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Divider(color: AppTheme.border, height: 1)),
          ],
        ),
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.chat,
    required this.model,
    required this.now,
    required this.showDivider,
  });

  final RemoteChat chat;
  final ChatViewModel model;
  final DateTime now;
  final bool showDivider;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: showDivider
          ? const Border(bottom: BorderSide(color: AppTheme.border, width: 0.5))
          : null,
    ),
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 12,
      horizontalTitleGap: 8,
      title: Text(
        chat.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(fontSize: 15, height: 1.4, fontWeight: FontWeight.w500),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          _updated(context),
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: AppTheme.muted),
        ),
      ),
      trailing: PopupMenuButton<_ChatAction>(
        tooltip: 'Chat options',
        icon: const Icon(Icons.more_horiz, color: AppTheme.muted, size: 20),
        onSelected: (action) {
          switch (action) {
            case _ChatAction.pin:
              unawaited(model.togglePin(chat));
            case _ChatAction.delete:
              unawaited(_delete(context));
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: _ChatAction.pin,
            enabled: model.chatList.canPin,
            child: Text(
              model.chatList.isPinned(chat) ? 'Unpin chat' : 'Pin chat',
            ),
          ),
          PopupMenuItem(
            value: _ChatAction.delete,
            enabled: model.chatList.canDelete,
            child: const Text('Delete chat'),
          ),
        ],
      ),
      onTap: model.online && !model.loading && !model.mutating
          ? () => model.openChat(chat)
          : null,
    ),
  );

  String _updated(BuildContext context) {
    final elapsed = now.difference(chat.updatedAt);
    if (elapsed.inMinutes < 1) return 'Just now';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
    if (elapsed.inDays < 1) return '${elapsed.inHours}h ago';
    final date = chat.updatedAt.toLocal();
    final localizations = MaterialLocalizations.of(context);
    return date.year == now.year
        ? localizations.formatShortMonthDay(date)
        : localizations.formatMediumDate(date);
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          'Permanently delete “${chat.title}” and its sub-agent conversations from OpenCode? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) await model.deleteChat(chat);
  }
}

enum _ChatAction { pin, delete }

class _EmptyChats extends StatelessWidget {
  const _EmptyChats({required this.searching, required this.hasMore});
  final bool searching, hasMore;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Column(
      children: [
        ExcludeSemantics(
          child: Icon(
            searching ? Icons.search_off : Icons.chat_bubble_outline,
            size: 32,
            color: AppTheme.muted,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          searching
              ? hasMore
                    ? 'No matches in loaded chats.'
                    : 'No chats match your search.'
              : hasMore
              ? 'No main chats in this page.'
              : 'No chats yet',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          hasMore
              ? 'Older chats load automatically while connected.'
              : searching
              ? 'Try another title or clear your search.'
              : 'Start a new chat in this project.',
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}
