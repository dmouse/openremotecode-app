import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../../../ui/core/inline_notice.dart';
import '../chat_view_model.dart';
import '../data/chat_repository.dart';
import '../domain/chat_models.dart';
import 'chat_composer_bar.dart';
import 'chat_details_screen.dart';
import 'chat_flow_app_bar.dart';
import 'chat_list_view.dart';
import 'conversation_page.dart';
import 'model_banner.dart';
import 'model_list_sheet.dart';
import 'project_path_sheet.dart';
import 'projects_view.dart';
import 'rename_chat_dialog.dart';
import 'todo_banner.dart';

class ChatFlowScreen extends StatefulWidget {
  const ChatFlowScreen({
    super.key,
    required this.repository,
    required this.connectorId,
    required this.connectionName,
  }) : initialProject = null,
       initialChat = null,
       parentSessionId = null,
       subtaskDepth = 0;
  const ChatFlowScreen._subtask({
    required this.repository,
    required this.connectorId,
    required this.connectionName,
    required this.initialProject,
    required this.initialChat,
    required this.parentSessionId,
    required this.subtaskDepth,
  });
  final ChatRepository repository;
  final String connectorId, connectionName;
  final RemoteProject? initialProject;
  final RemoteChat? initialChat;
  final String? parentSessionId;
  final int subtaskDepth;
  @override
  State<ChatFlowScreen> createState() => _ChatFlowScreenState();
}

class _ChatFlowScreenState extends State<ChatFlowScreen>
    with WidgetsBindingObserver {
  late final model = ChatViewModel(
    widget.repository,
    widget.connectorId,
    parentSessionId: widget.parentSessionId,
  );
  final search = TextEditingController();
  final draft = TextEditingController();
  final _composerFocus = FocusNode();
  final _modelSearch = TextEditingController();
  ChatPage? previousPage;
  String? previousChat;
  final _drafts = <String, String>{};
  bool _detailsOpen = false;
  bool _subtaskOpen = false;
  bool _modePickerOpen = false;
  bool _modelPickerOpen = false;
  bool _modelBannerOpen = false;
  bool _todoBannerOpen = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    model.addListener(_changed);
    if (widget.initialChat case final chat?) {
      model.project = widget.initialProject;
      unawaited(model.openChat(chat));
    } else {
      unawaited(model.refresh());
    }
  }

  void _changed() {
    if (model.isSubtask && (model.trustLost || model.project == null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.pop(context);
        }
      });
    }
    if (model.chatList.lastDeletedChatId != null) {
      _drafts.remove('chat:${model.chatList.lastDeletedChatId}');
    }
    if (model.trustLost) {
      _drafts.clear();
      draft.clear();
      previousChat = null;
    }
    final nextChat = model.conversation.composerKey;
    final createdFromDraft =
        previousPage == ChatPage.conversation &&
        model.page == ChatPage.conversation &&
        previousChat?.startsWith('draft:') == true &&
        model.conversation.chat != null;
    if (previousPage != model.page) {
      search.clear();
      previousPage = model.page;
    }
    if (previousChat != nextChat) {
      if (previousChat != null &&
          previousChat != 'chat:${model.chatList.lastDeletedChatId}') {
        _drafts[previousChat!] = draft.text;
      }
      if (createdFromDraft && nextChat != null) {
        _drafts[nextChat] = draft.text;
        _drafts.remove(previousChat);
      }
      if (_drafts.length > 10) _drafts.remove(_drafts.keys.first);
      previousChat = nextChat;
      draft.text = _drafts[previousChat] ?? '';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      model.setActive(state == AppLifecycleState.resumed);
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    model.removeListener(_changed);
    model.dispose();
    search.dispose();
    draft.dispose();
    _composerFocus.dispose();
    _modelSearch.dispose();
    super.dispose();
  }

  Future<void> _openPath() async {
    final entered = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ProjectPathSheet(connectionName: widget.connectionName),
    );
    if (entered != null && mounted) await model.openPath(entered);
  }

  Future<void> _renameChat() async {
    if (!model.conversation.canRename) return;
    final currentTitle = model.conversation.chat!.title;
    await showDialog<void>(
      context: context,
      builder: (_) =>
          RenameChatDialog(title: currentTitle, model: model.conversation),
    );
  }

  Future<void> _choosePromptMode() async {
    if (_modePickerOpen || !model.conversation.canChangePromptMode) return;
    final source = model.conversation.composerKey;
    _modePickerOpen = true;
    try {
      final selected = await showModalBottomSheet<PromptMode>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (context) => ListenableBuilder(
          listenable: model,
          builder: (context, _) => SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!model.conversation.supportsPromptMode)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Restart OpenCode with the updated Remote plugin to choose Build or Plan.',
                      ),
                    ),
                  for (final mode in PromptMode.values)
                    ListTile(
                      enabled:
                          model.conversation.canChangePromptMode &&
                          model.conversation.supportsPromptMode &&
                          model.conversation.composerKey == source,
                      selected: model.conversation.promptMode == mode,
                      selectedColor: AppTheme.ink,
                      leading: Icon(
                        mode == PromptMode.build
                            ? Icons.build_outlined
                            : Icons.edit_note,
                      ),
                      title: Text(mode == PromptMode.build ? 'Build' : 'Plan'),
                      trailing: model.conversation.promptMode == mode
                          ? const Icon(Icons.check, color: AppTheme.ink)
                          : null,
                      onTap: () => Navigator.pop(context, mode),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      if (mounted &&
          selected != null &&
          model.conversation.composerKey == source) {
        model.conversation.selectPromptMode(selected);
      }
    } finally {
      _modePickerOpen = false;
    }
  }

  /// The composer's model banner: raised from the bottom edge over the input,
  /// the way the Build/Plan picker is. Its title leads on to the model list,
  /// and picking a model with levels of its own brings the banner back up so
  /// the slider is there to set them. The provider list is fetched on the way
  /// open -- never on chat load.
  Future<void> _openModelBanner() async {
    if (_modelBannerOpen || !model.conversation.canChangeModel) return;
    final source = model.conversation.composerKey;
    _modelBannerOpen = true;
    unawaited(model.conversation.loadAvailableModels());
    try {
      while (true) {
        if (!mounted || model.conversation.composerKey != source) break;
        final change = await showModalBottomSheet<bool>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          builder: (context) => ListenableBuilder(
            listenable: model,
            builder: (context, _) => ModelBanner(
              model: model.conversation,
              source: source,
              onChangeModel: () => Navigator.pop(context, true),
            ),
          ),
        );
        if (change != true ||
            !mounted ||
            model.conversation.composerKey != source) {
          break;
        }
        // Dismissing the list without choosing ends there; a chosen model
        // that has no levels left to set has nothing to come back for.
        if (!await _chooseModel()) break;
        if (model.conversation.models.selectedModel?.effortLevels.isEmpty ??
            true) {
          break;
        }
      }
    } finally {
      _modelBannerOpen = false;
    }
  }

  /// The model list, reached from the banner's title: one searchable sheet of
  /// names. Effort is not repeated here -- the banner's slider owns it.
  /// Answers whether a model was chosen.
  Future<bool> _chooseModel() async {
    if (_modelPickerOpen || !model.conversation.canChangeModel) return false;
    final source = model.conversation.composerKey;
    _modelPickerOpen = true;
    _modelSearch.clear();
    // Lazy: only fetched when the user actually opens the banner or this list.
    unawaited(model.conversation.loadAvailableModels());
    try {
      final selected = await showModalBottomSheet<ChatModelOption>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (context) => ModelListSheet(
          model: model.conversation,
          source: source,
          search: _modelSearch,
          onSelected: (option) => Navigator.pop(context, option),
        ),
      );
      if (mounted &&
          selected != null &&
          model.conversation.composerKey == source) {
        // The effort in force carries over to the new model; selectModel()
        // drops it when that model does not offer it.
        model.conversation.selectModel(
          selected,
          model.conversation.models.selectedEffort,
        );
        return true;
      }
      return false;
    } finally {
      _modelPickerOpen = false;
    }
  }

  /// The task tab's list: a bottom sheet like the model banner, kept
  /// live while it is up so a task ticking over is visible without closing it.
  /// A banner left open over a chat the conversation has since left closes
  /// itself rather than showing another chat's list.
  Future<void> _openTodoBanner() async {
    if (_todoBannerOpen || model.page != ChatPage.conversation) return;
    final source = model.conversation.composerKey;
    _todoBannerOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (context) => ListenableBuilder(
          listenable: model,
          builder: (context, _) {
            if (model.conversation.composerKey != source || model.trustLost) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (ModalRoute.of(context)?.isCurrent == true) {
                  Navigator.pop(context);
                }
              });
              return const SizedBox.shrink();
            }
            return TodoBanner(model: model.conversation);
          },
        ),
      );
    } finally {
      _todoBannerOpen = false;
    }
  }

  Future<void> _openDetails() async {
    if (_detailsOpen ||
        model.page != ChatPage.conversation ||
        model.trustLost) {
      return;
    }
    _detailsOpen = true;
    model.conversation.setCovered(true);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ChatDetailsScreen(model: model.conversation),
        ),
      );
    } finally {
      _detailsOpen = false;
      if (mounted) model.conversation.setCovered(false);
    }
  }

  Future<void> _openSubtask(ChatSubtask task) async {
    final parent = model.conversation.chat;
    final project = model.project;
    if (_subtaskOpen ||
        task.sessionId == null ||
        parent == null ||
        project == null ||
        !model.online ||
        model.trustLost ||
        !model.supportsSubtasks ||
        widget.subtaskDepth >= 8) {
      return;
    }
    _subtaskOpen = true;
    model.conversation.setCovered(true);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ChatFlowScreen._subtask(
            repository: widget.repository,
            connectorId: widget.connectorId,
            connectionName: widget.connectionName,
            initialProject: project,
            parentSessionId: parent.id,
            subtaskDepth: widget.subtaskDepth + 1,
            initialChat: RemoteChat(
              task.sessionId!,
              task.title,
              parent.updatedAt,
              parentId: parent.id,
            ),
          ),
        ),
      );
    } finally {
      _subtaskOpen = false;
      if (mounted) model.conversation.setCovered(false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final busy = model.loading || model.mutating;
      final title = switch (model.page) {
        ChatPage.projects => widget.connectionName,
        ChatPage.chats => model.project!.name,
        ChatPage.conversation => model.conversation.chat?.title ?? 'New chat',
      };
      return PopScope(
        canPop: model.isSubtask || model.page == ChatPage.projects,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) model.back();
        },
        child: Scaffold(
          backgroundColor: AppTheme.background,
          appBar: ChatFlowAppBar.build(
            context,
            model: model,
            title: title,
            busy: busy,
            onBack: () {
              if (model.isSubtask || model.page == ChatPage.projects) {
                Navigator.pop(context);
              } else {
                model.back();
              }
            },
            onOpenDetails: _openDetails,
            onRename: () => unawaited(_renameChat()),
          ),
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!model.online)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20),
                    child: InlineNotice(
                      message: 'OpenCode must be running on your computer. Any displayed content may be out of date.',
                    ),
                  ),
                if (model.error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    child: InlineNotice(message: model.error!, isError: true),
                  ),
                if (busy &&
                    !model.loadingMoreChats &&
                    !model.conversation.loadingEarlierMessages)
                  LinearProgressIndicator(
                    semanticsLabel: model.conversation.progressLabel,
                  ),
                Expanded(
                  child: switch (model.page) {
                    ChatPage.projects => ProjectsView(
                      model: model,
                      search: search,
                      onPath: _openPath,
                    ),
                    ChatPage.chats => ChatListView(
                      model: model,
                      search: search,
                    ),
                    ChatPage.conversation => ConversationPage(
                      model: model.conversation,
                      isSubtask: model.isSubtask,
                      onOpenSubtask:
                          model.supportsSubtasks && widget.subtaskDepth < 8
                          ? _openSubtask
                          : null,
                      onOpenTodoBanner: _openTodoBanner,
                    ),
                  },
                ),
                if (model.page == ChatPage.conversation && !model.isSubtask)
                  ChatComposerBar(
                    model: model.conversation,
                    draft: draft,
                    composerFocus: _composerFocus,
                    busy: busy,
                    online: model.online,
                    onOpenModelBanner: _openModelBanner,
                    onChoosePromptMode: _choosePromptMode,
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
