import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_list_view_model.dart';
import 'chat_request_scope.dart';
import 'conversation_view_model.dart';
import 'data/chat_image_preferences.dart';
import 'data/chat_repository.dart';
import 'domain/chat_models.dart';
import 'projects_view_model.dart';

export 'conversation_view_model.dart' show ConversationViewModel, PromptMode;

enum ChatPage { projects, chats, conversation }

/// Coordinates the three areas of a connector's chat experience --
/// [ProjectsViewModel] (browsing authorized projects), [ChatListViewModel]
/// (a project's chat list), and [ConversationViewModel] (the open chat) --
/// behind the same public surface the single-class `ChatViewModel` used to
/// expose directly. `page`/`project` and the online/trust/lifecycle wiring
/// stay here since they're shared across all three areas; each area's own
/// data, and the mutating actions that only ever touch that area, live on
/// its own object.
final class ChatViewModel extends ChangeNotifier with ChatRequestScope {
  ChatViewModel(
    this.repository,
    this.connectorId, {
    this.parentSessionId,
    ChatImagePreferences? imagePreferences,
  }) {
    _online = repository.chatOnline(connectorId);
    projects = ProjectsViewModel(repository, connectorId);
    chatList = ChatListViewModel(
      repository,
      connectorId,
      _busyGate,
      _errorBox,
      online: () => online,
      trustLost: () => trustLost,
      active: () => _active,
    )..addListener(notifyListeners);
    conversation = ConversationViewModel(
      repository,
      connectorId,
      parentSessionId: parentSessionId,
      busyGate: _busyGate,
      errorBox: _errorBox,
      project: () => project,
      online: () => online,
      trustLost: () => trustLost,
      active: () => _active,
      chatList: chatList,
      credentialNotice: () => _credentialNotice,
      dismissCredentialNotice: dismissCredentialNotice,
      forkNoticeFor: (path, id) => _forkNotices[(path, id)],
      setForkNotice: (path, id, message) => _forkNotices[(path, id)] = message,
      scheduleRefreshIfOnline: () {
        if (online) unawaited(refresh());
      },
      isConversationPage: () => page == ChatPage.conversation,
      canRefresh: () => canRefresh,
      leaveConversationPage: () => page = ChatPage.chats,
      imagePreferences: imagePreferences,
    )..addListener(notifyListeners);
    _credentialEvents = repository.chatEvents.listen((event) {
      if (_disposed ||
          event.connectorId != connectorId ||
          event.operation != 'connector.credential.updated') {
        return;
      }
      final message = credentialNoticeMessage(event.body);
      if (message == null || !_seenCredentialNotices.add(event.requestId))
        return;
      _credentialNotice = message;
      notifyListeners();
    });
    _subscription = repository.chatConnectionChanges.listen((_) {
      if (!repository.chatTrusted(connectorId) && !_disposed) {
        trustLost = true;
        conversation.resetOnTrustLoss();
        _forkNotices.clear();
        invalidate();
        chatList.invalidate();
        conversation.invalidate();
        conversation.closeChat();
        page = ChatPage.projects;
        project = null;
        chatList.reset();
        projects.projects = [];
        _errorBox.value = 'This connection is no longer verified. Return to Connections and pair again.';
        notifyListeners();
      }
      final nowOnline = repository.chatOnline(connectorId);
      if (_disposed) return;
      conversation.notifyConnectionChanged();
      if (_online == nowOnline) {
        notifyListeners();
        return;
      }
      _online = nowOnline;
      if (!nowOnline) {
        conversation.stopLive();
        invalidate();
        chatList.invalidate();
        conversation.invalidate();
        _busyGate.loading = false;
        _busyGate.loadingMoreChats = false;
        _busyGate.loadingEarlierMessages = false;
        _busyGate.mutating = false;
        _busyGate.reading = false;
      }
      notifyListeners();
      // `online` is read through an injected closure by canSend/canRename/
      // canDeleteCurrentChat/etc., so a widget listening directly to
      // `conversation` (not just the coordinator) needs its own notification
      // to re-evaluate them.
      conversation.notifyExternalChange();
      // A reconnect is not a user-requested reload: merge in whatever
      // changed instead of collapsing an already-loaded history down to the
      // latest page, which would otherwise reset the reader's scroll
      // position on every reconnect (including routine relay lease renewal).
      if (nowOnline && _active) unawaited(refresh(resetHistory: false));
    });
  }

  final ChatRepository repository;
  final String connectorId;
  final String? parentSessionId;
  bool get isSubtask => parentSessionId != null;
  bool get supportsSubtasks => conversation.supportsSubtasks;

  /// Browsing authorized projects. See [ProjectsViewModel].
  late final ProjectsViewModel projects;

  /// The selected project's chat list. See [ChatListViewModel].
  late final ChatListViewModel chatList;

  /// The currently open chat. See [ConversationViewModel].
  late final ConversationViewModel conversation;
  final _busyGate = ChatBusyGate();
  final _errorBox = ChatErrorBox();
  @override
  ChatBusyGate get busyGate => _busyGate;
  @override
  ChatErrorBox get errorBox => _errorBox;
  @override
  bool get scopeValid => !_disposed && _active;
  @override
  String? get pendingForkNotice {
    final selectedProject = project;
    final currentChat = conversation.chat;
    if (selectedProject == null || currentChat == null) return null;
    return _forkNotices[(selectedProject.path, currentChat.id)];
  }

  @override
  String? get pendingCreationUncertainMessage =>
      conversation.pendingCreationUncertainMessage;

  late final StreamSubscription<void> _subscription;
  late final StreamSubscription<ChatEvent> _credentialEvents;
  // A renewal is connector-scoped, so it is held here and shown in whichever conversation
  // is open. Session-lifetime only: the connector owns message history, so this never
  // becomes part of it. requestIds are remembered so a redelivery cannot show it twice.
  final _seenCredentialNotices = <String>{};
  String? _credentialNotice;
  String? get credentialNotice => _credentialNotice;

  void dismissCredentialNotice() {
    if (_credentialNotice == null) return;
    _credentialNotice = null;
    notifyListeners();
  }

  bool _disposed = false, _active = true, _online = false;
  final _forkNotices = <(String, String), String>{};

  // The busy gate and error box are created and owned here, then shared
  // across projects/chatList/conversation (see ChatRequestScope) so a
  // project refresh that can reassign the selected project/chat never runs
  // concurrently with e.g. a chat rename. That makes them coordinator-level
  // concerns even though the underlying action lives on one sub-object.
  bool get loading => _busyGate.loading;
  bool get mutating => _busyGate.mutating;
  bool get loadingMoreChats => _busyGate.loadingMoreChats;
  String? get error => _errorBox.value;
  bool trustLost = false;

  ChatPage page = ChatPage.projects;
  RemoteProject? project;
  bool get online => _online && _active;
  bool get canRefresh =>
      !_disposed &&
      online &&
      !_busyGate.loading &&
      !_busyGate.mutating &&
      !_busyGate.reading &&
      _busyGate.chatAction == null &&
      repository.chatTrusted(connectorId);

  void setActive(bool active) {
    _active = active;
    if (!active) {
      conversation.stopLive();
      invalidate();
      chatList.invalidate();
      conversation.invalidate();
      _busyGate.loading = false;
      _busyGate.loadingMoreChats = false;
      _busyGate.loadingEarlierMessages = false;
      _busyGate.mutating = false;
      _busyGate.reading = false;
    }
    // Resuming from background is not a user-requested reload either -- see
    // the connection listener above for why this merges instead of resetting.
    if (active && online) unawaited(refresh(resetHistory: false));
    if (!_disposed) notifyListeners();
    // `active` (via `online`) is read through an injected closure by
    // canSend/canRename/canDeleteCurrentChat/etc., so a widget listening
    // directly to `conversation` needs its own notification too.
    conversation.notifyExternalChange();
  }

  void _handleFailure(Object failure) {
    _errorBox.value = describeChatFailure(failure);
  }

  /// [resetHistory] controls whether an already-open conversation's message
  /// history is collapsed back to just the latest page (true, the default --
  /// matches an explicit user-requested "Refresh") or merged in place (false
  /// -- for a reconnect/background-resume driven call, which should not
  /// disturb a reader's scroll position). See
  /// [ConversationViewModel.reloadForProjectRefresh].
  Future<void> refresh({bool resetHistory = true}) => run(
    (generation) async {
      await projects.fetchList();
      if (!valid(generation)) return;
      notifyListeners();
      if (page == ChatPage.projects) return;
      final selected = projects.projects
          .where((p) => p.path == project?.path)
          .firstOrNull;
      if (selected == null) {
        _clearToProjects();
        return;
      }
      project = selected;
      if (page == ChatPage.chats) {
        await chatList.fetchPage(selected, isValid: () => valid(generation));
        if (!valid(generation)) return;
        _forkNotices.removeWhere((key, _) => key.$1 == selected.path);
      } else if (conversation.chat != null) {
        await conversation.reloadForProjectRefresh(
          generation: generation,
          isValid: () => valid(generation),
          resetHistory: resetHistory,
        );
      }
    },
    onFailure: _handleFailure,
    onAfterSuccess: _afterSuccess,
    onAfterStale: _afterStale,
  );

  Future<void> openProject(RemoteProject selected) async {
    if (_busyGate.loading || _busyGate.mutating) return;
    invalidate();
    _busyGate.reading = false;
    project = selected;
    conversation.closeChat();
    chatList.reset();
    page = ChatPage.chats;
    notifyListeners();
    await run(
      (generation) async {
        await chatList.fetchPage(selected, isValid: () => valid(generation));
        if (!valid(generation)) return;
        _forkNotices.removeWhere((key, _) => key.$1 == selected.path);
      },
      onFailure: _handleFailure,
      onAfterSuccess: _afterSuccess,
      onAfterStale: _afterStale,
    );
  }

  Future<void> openPath(String input) => run(
    (generation) async {
      final selected = await projects.resolvePath(input);
      if (!valid(generation)) return;
      project = selected;
      conversation.closeChat();
      chatList.reset();
      page = ChatPage.chats;
      await chatList.fetchPage(selected, isValid: () => valid(generation));
      if (!valid(generation)) return;
      _forkNotices.removeWhere((key, _) => key.$1 == selected.path);
    },
    onFailure: _handleFailure,
    onAfterSuccess: _afterSuccess,
    onAfterStale: _afterStale,
  );

  void _afterSuccess() => conversation.schedulePollIfNeeded();
  void _afterStale() {
    if (online) unawaited(refresh());
  }

  Future<void> togglePin(RemoteChat selected) async {
    if (project == null || !chatList.chats.any((c) => c.id == selected.id)) {
      return;
    }
    await chatList.togglePin(selected, project!);
  }

  Future<void> deleteChat(RemoteChat selected) async {
    if (project == null) return;
    final current =
        page == ChatPage.conversation && conversation.chat?.id == selected.id;
    final conversationGeneration = conversation.generation;
    await chatList.deleteChat(
      selected,
      project!,
      isCurrent: current,
      canDeleteCurrent: () => conversation.canDeleteCurrentChat,
      // See ConversationViewModel.deleteCurrentChat: the conversation may
      // have moved on to a different chat while this request was in flight.
      isValid: () => !current || conversation.valid(conversationGeneration),
      onCurrentChatDeleted: () {
        page = ChatPage.chats;
        conversation.closeChat();
      },
    );
  }

  Future<void> moreChats() async {
    if (page != ChatPage.chats ||
        project == null ||
        chatList.chatCursor == null) {
      return;
    }
    await chatList.moreChats(project!);
  }

  Future<void> openChat(RemoteChat selected) async {
    if (_busyGate.loading || _busyGate.mutating) return;
    page = ChatPage.conversation;
    await conversation.open(selected);
  }

  void startNewChat() {
    if (_disposed ||
        page != ChatPage.chats ||
        project == null ||
        _busyGate.loading ||
        _busyGate.mutating) {
      return;
    }
    page = ChatPage.conversation;
    conversation.startNew();
  }

  void back() {
    invalidate();
    _busyGate.loading = false;
    _busyGate.loadingMoreChats = false;
    _busyGate.loadingEarlierMessages = false;
    _busyGate.mutating = false;
    _busyGate.reading = false;
    _errorBox.value = null;
    if (page == ChatPage.conversation) {
      page = ChatPage.chats;
      conversation.closeChat();
      unawaited(refresh());
    } else {
      _clearToProjects();
    }
    notifyListeners();
  }

  void backToProjects() {
    if (_disposed) return;
    invalidate();
    _busyGate.loading = false;
    _busyGate.loadingMoreChats = false;
    _busyGate.loadingEarlierMessages = false;
    _busyGate.mutating = false;
    _busyGate.reading = false;
    _errorBox.value = null;
    _clearToProjects();
    notifyListeners();
    unawaited(refresh());
  }

  void _clearToProjects() {
    page = ChatPage.projects;
    project = null;
    chatList.reset();
    conversation.closeChat();
  }

  @override
  void dispose() {
    unawaited(_credentialEvents.cancel());
    _disposed = true;
    invalidate();
    _subscription.cancel();
    chatList.dispose();
    conversation.dispose();
    super.dispose();
  }
}
