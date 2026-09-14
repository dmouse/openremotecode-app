import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../chat_view_model.dart';
import 'conversation_header.dart';

/// Builds the chat flow's app bar: title varies by page (connection name,
/// project name, or the conversation header), with a "Chat options" menu on
/// the conversation page and a plain refresh action elsewhere.
///
/// This is a builder function rather than a widget because the conversation
/// page's title needs a height computed from the text scale factor
/// ([ConversationHeader.height]), and [PreferredSizeWidget.preferredSize]
/// has no [BuildContext] to compute that from -- so the height is resolved
/// here, before the [AppBar] (which already implements
/// [PreferredSizeWidget] correctly from a fixed `toolbarHeight`) is built.
class ChatFlowAppBar {
  ChatFlowAppBar._();

  static AppBar build(
    BuildContext context, {
    required ChatViewModel model,
    required String title,
    required bool busy,
    required VoidCallback onBack,
    required VoidCallback onOpenDetails,
    required VoidCallback onRename,
  }) {
    final page = model.page;
    final conversation = model.conversation;
    return AppBar(
      backgroundColor: AppTheme.background,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: AppTheme.border),
      ),
      centerTitle: page == ChatPage.conversation ? false : null,
      leadingWidth: page == ChatPage.conversation ? 56 : null,
      titleSpacing: page == ChatPage.conversation ? 4 : null,
      leading: BackButton(onPressed: onBack),
      // Two tight lines still need room once text scales up, but they fit
      // the default bar height, so only large scales grow it.
      toolbarHeight:
          page == ChatPage.conversation &&
              ConversationHeader.modelLine(conversation) != null
          ? ConversationHeader.height(context)
          : null,
      title: page == ChatPage.conversation
          ? ConversationHeader(
              online: model.online,
              working: conversation.isWorking,
              model: conversation,
              title: title,
              onOpenDetails: model.isSubtask ? null : onOpenDetails,
            )
          : Tooltip(
              message: title,
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
      actions: [
        if (page == ChatPage.chats || page == ChatPage.projects)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Tooltip(
              message: model.online ? 'Online' : 'Offline',
              excludeFromSemantics: true,
              child: Icon(
                model.online
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
                size: 20,
                semanticLabel: model.online ? 'Online' : 'Offline',
                color: model.online ? AppTheme.success : AppTheme.muted,
              ),
            ),
          ),
        if (page == ChatPage.conversation && !model.isSubtask)
          PopupMenuButton<String>(
            tooltip: 'Chat options',
            enabled: !busy,
            icon: const Icon(Icons.more_vert, color: AppTheme.muted),
            onSelected: (action) {
              if (action == 'rename') onRename();
              if (action == 'fork') {
                unawaited(conversation.forkChat());
              }
              if (action == 'todos') conversation.showTodos();
              if (action == 'refresh' && model.canRefresh) {
                unawaited(model.refresh());
              }
            },
            itemBuilder: (_) => [
              // The tab is the only way into the task list, so the menu
              // carries the way back once it has been dismissed. It leads:
              // it is the one item here that undoes something the user just
              // did, and it is only present while a list is actually being
              // held back.
              if (conversation.canShowTodos) ...[
                const PopupMenuItem(
                  value: 'todos',
                  child: Text('Show task list'),
                ),
                const PopupMenuDivider(),
              ],
              PopupMenuItem(
                value: 'rename',
                enabled: conversation.canRename,
                child: const Text('Rename chat'),
              ),
              PopupMenuItem(
                value: 'fork',
                enabled: conversation.canFork,
                child: const Text('Fork chat'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'refresh',
                enabled: model.canRefresh,
                child: const Text('Refresh'),
              ),
              if (!conversation.isDraft && conversation.chatActionsUnsupported)
                PopupMenuItem(
                  enabled: false,
                  child: Text(
                    'Restart OpenCode with the updated Remote plugin to enable these actions.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
            ],
          )
        else
          IconButton(
            tooltip: 'Refresh',
            onPressed: model.canRefresh ? model.refresh : null,
            icon: const Icon(Icons.refresh),
          ),
      ],
    );
  }
}
