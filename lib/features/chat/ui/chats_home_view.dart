import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/core/inline_notice.dart';
import '../../../ui/core/search_field.dart';
import '../../../ui/core/chat_avatar.dart';
import 'chat_filter_strip.dart';
import 'chat_row_activity.dart';
import '../../../ui/core/app_theme.dart';
import '../chat_view_model.dart';
import '../chats_home_view_model.dart';

class ChatsHomeView extends StatefulWidget {
  const ChatsHomeView({
    super.key,
    required this.model,
    required this.onOpen,
    required this.onConnect,
    this.onOpenDraft,
  });
  final ChatsHomeViewModel model;
  final ValueChanged<HomeChat> onOpen;
  final VoidCallback onConnect;
  final ValueChanged<ChatViewModel>? onOpenDraft;

  @override
  State<ChatsHomeView> createState() => _ChatsHomeViewState();
}

class _ChatsHomeViewState extends State<ChatsHomeView> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  void _filterChanged() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _checkMore();
  }

  Timer? _debounce;
  bool _scheduled = false;

  Future<void> _chatOptions(HomeChat entry) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(entry.pinned ? 'Unpin chat' : 'Pin chat'),
              leading: const Icon(Icons.push_pin_outlined),
              onTap: () => Navigator.pop(context, 'pin'),
            ),
            ListTile(
              title: const Text('Delete chat'),
              leading: const Icon(Icons.delete_outline),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    bool valid() =>
        mounted &&
        widget.model.sources.contains(entry.source) &&
        entry.source.online &&
        entry.source.repository.chatTrusted(entry.connection.id);
    if (!mounted || !valid()) return;
    if (action == 'pin') {
      await entry.source.togglePin(entry.chat);
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete chat?'),
          content: Text(
            'Permanently delete “${entry.chat.title}” and its sub-agent conversations from OpenCode? This cannot be undone.',
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
      if (confirmed == true && valid()) {
        await entry.source.deleteChat(entry.chat);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_checkMore);
    _scroll.addListener(_checkMore);
    _search.addListener(_searchChanged);
  }

  void _searchChanged() {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _checkMore);
  }

  void _checkMore() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted ||
          _debounce?.isActive == true ||
          !_scroll.hasClients ||
          _scroll.position.extentAfter > 320 ||
          widget.model.loading ||
          !widget.model.hasMore ||
          widget.model.errors.isNotEmpty ||
          widget.model.sources.any((s) => s.chatList.moreChatsError != null)) {
        return;
      }
      unawaited(widget.model.loadMore());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    widget.model.removeListener(_checkMore);
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final model = widget.model;
      final query = _search.text.trim().toLowerCase();
      final chats = model.chats
          .where((entry) => entry.chat.title.toLowerCase().contains(query))
          .toList();
      final drafts = model.draftSources
          .where(
            (source) =>
                query.isEmpty ||
                'new chat ${source.project!.name}'.toLowerCase().contains(
                  query,
                ),
          )
          .toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: SearchField(
              controller: _search,
              hintText: model.hasMore ? 'Search loaded chats' : 'Search chats',
            ),
          ),
          ChatFilterStrip(model: model, onChanged: _filterChanged),
          if (model.loading)
            const LinearProgressIndicator(semanticsLabel: 'Loading chats'),
          Expanded(
            child: RefreshIndicator(
              onRefresh: model.refresh,
              child: CustomScrollView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (model.filterNotice != null)
                            InlineNotice(message: model.filterNotice!),
                          for (final machine in model.machines)
                            if ((model.selectedMachine == null ||
                                    model.selectedMachine == machine.id) &&
                                !model.repository.chatOnline(machine.id))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  '${machine.name} · ${machine.statusLabel}. ${machine.needsVerification ? 'Open Connect to verify this device.' : 'Keep OpenCode running to load current chats.'}',
                                ),
                              ),
                          for (final error in model.errors.toSet())
                            InlineNotice(message: error, isError: true),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    sliver: SliverList.builder(
                      itemCount: drafts.length + chats.length,
                      itemBuilder: (context, index) {
                        if (index < drafts.length) {
                          final source = drafts[index];
                          final machine = model.machines.firstWhere(
                            (m) => m.id == source.connectorId,
                          );
                          return ListTile(
                            key: ValueKey((
                              'new-draft',
                              source.connectorId,
                              source.project!.path,
                            )),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 8,
                            ),
                            leading: ChatAvatar(
                              color: model.connections.colorFor(
                                source.connectorId,
                              ),
                            ),
                            title: const Text('New chat'),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Draft',
                                  style: TextStyle(
                                    color: AppTheme.of(context).warning,
                                  ),
                                ),
                                Text(
                                  '${machine.name} · ${source.project!.name}',
                                ),
                              ],
                            ),
                            onTap: source.online && widget.onOpenDraft != null
                                ? () => widget.onOpenDraft!(source)
                                : null,
                          );
                        }
                        final entry = chats[index - drafts.length];
                        return ListTile(
                          key: ValueKey((
                            entry.connection.id,
                            entry.project.path,
                            entry.chat.id,
                          )),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 8,
                          ),
                          leading: ChatAvatar(
                            color: model.connections.colorFor(
                              entry.connection.id,
                            ),
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  entry.chat.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              ChatRowActivity(
                                activity: entry.chat.activity,
                                online: entry.source.online,
                              ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (model.hasDraft(entry))
                                Text(
                                  'Draft',
                                  style: TextStyle(
                                    color: AppTheme.of(context).warning,
                                  ),
                                ),
                              Text(
                                '${entry.connection.name} · ${entry.project.name}${entry.source.online ? '' : ' · Last known'}',
                              ),
                            ],
                          ),
                          trailing: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                MaterialLocalizations.of(context)
                                    .formatShortDate(
                                      entry.chat.updatedAt.toLocal(),
                                    ),
                              ),
                              if (entry.pinned)
                                const Icon(
                                  Icons.push_pin,
                                  size: 16,
                                  semanticLabel: 'Pinned',
                                ),
                            ],
                          ),
                          onTap: entry.source.online
                              ? () => widget.onOpen(entry)
                              : null,
                          onLongPress: entry.source.online
                              ? () => _chatOptions(entry)
                              : null,
                        );
                      },
                    ),
                  ),
                  if (chats.isEmpty && drafts.isEmpty && !model.loading)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          children: [
                            Text(
                              model.machines.isEmpty
                                  ? 'Connect your first OpenCode instance'
                                  : query.isNotEmpty
                                  ? 'No matching chats loaded.'
                                  : 'No chats available yet.',
                            ),
                            if (model.machines.isEmpty)
                              TextButton(
                                onPressed: widget.onConnect,
                                child: const Text('Connect'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        for (final source in model.sources)
                          if (source.chatList.moreChatsError != null)
                            TextButton(
                              onPressed: model.loading
                                  ? null
                                  : () => source.moreChats(),
                              child: const Text('Retry loading chats'),
                            ),
                        if (model.errors.isNotEmpty)
                          TextButton(
                            onPressed: model.loading ? null : model.refresh,
                            child: const Text('Retry loading chats'),
                          ),
                        if (model.hasMore && !model.loading)
                          TextButton(
                            onPressed: model.loadMore,
                            child: const Text('Load older chats'),
                          ),
                        const SizedBox(height: 88),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Only authorized, online projects are offered; choosing never creates a session.
Future<ChatViewModel?> chooseChatProject(
  BuildContext context,
  ChatsHomeViewModel model,
) => showModalBottomSheet<ChatViewModel>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (_) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => FractionallySizedBox(
      heightFactor: .7,
      child: ListView(
        children: [
          const ListTile(
            title: Text('New chat'),
            subtitle: Text('Choose a project'),
          ),
          for (final source in model.sources.where((s) => s.online))
            ListTile(
              title: Text(source.project!.name),
              subtitle: Text(
                '${model.machines.firstWhere((m) => m.id == source.connectorId).name} · ${source.project!.path}',
              ),
              onTap: () => Navigator.pop(context, source),
            ),
          if (!model.sources.any((s) => s.online))
            const ListTile(
              title: Text(
                'No online projects. Connect a machine and approve a folder through /remote in OpenCode.',
              ),
            ),
        ],
      ),
    ),
  ),
);
