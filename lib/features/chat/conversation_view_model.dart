import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../platform/remote_api.dart';
import 'chat_list_view_model.dart';
import 'chat_request_scope.dart';
import 'data/chat_image_preferences.dart';
import 'data/chat_repository.dart';
import 'data/chat_stream.dart';
import 'domain/chat_models.dart';
import 'model_selection_view_model.dart';

enum PromptMode { build, plan }

/// The currently open chat: its messages, live status, permission prompt,
/// task list, model selection, and the mutating actions that act on it
/// (send/abort, rename/fork/delete, older-history paging). One long-lived
/// instance per `ChatViewModel`, reset in place by [open]/[startNew] rather
/// than recreated on every chat switch, matching the original class.
final class ConversationViewModel extends ChangeNotifier with ChatRequestScope {
  ConversationViewModel(
    this.repository,
    this.connectorId, {
    this.parentSessionId,
    required this.busyGate,
    required this.errorBox,
    required this.project,
    required this.online,
    required this.trustLost,
    required this.active,
    required this.chatList,
    required this.credentialNotice,
    required this.dismissCredentialNotice,
    required this.forkNoticeFor,
    required this.setForkNotice,
    required this.scheduleRefreshIfOnline,
    required this.isConversationPage,
    required this.canRefresh,
    required this.leaveConversationPage,
    ChatImagePreferences? imagePreferences,
  }) : models = ModelSelectionViewModel(repository, connectorId),
       _imagePreferences =
           imagePreferences ?? PreferencesChatImagePreferences() {
    models.addListener(notifyListeners);
    unawaited(_loadShowImages());
    _stream = ChatStream(repository, connectorId, _streamSnapshot, () {
      if (!_disposed) {
        _schedulePoll();
        notifyListeners();
      }
    });
  }

  final ChatRepository repository;
  final String connectorId;
  final String? parentSessionId;
  bool get isSubtask => parentSessionId != null;
  bool get supportsSubtasks =>
      repository.chatSupports(connectorId, 'chat.subtask.snapshot');

  @override
  final ChatBusyGate busyGate;
  @override
  final ChatErrorBox errorBox;

  /// The project the open (or about-to-open) chat belongs to. Owned by the
  /// coordinator, since project selection is shared with the chats page.
  final RemoteProject? Function() project;
  final bool Function() online;
  final bool Function() trustLost;

  /// Whether the coordinator currently considers itself foregrounded --
  /// mirrors the original class's `_active` check inside its shared result
  /// validity test.
  final bool Function() active;
  final ChatListViewModel chatList;

  /// Connector-scoped, so it is owned by ChatViewModel and simply surfaced here.
  final String? Function() credentialNotice;
  final void Function() dismissCredentialNotice;
  final String? Function(String projectPath, String chatId) forkNoticeFor;
  final void Function(String projectPath, String chatId, String message)
  setForkNotice;
  final void Function() scheduleRefreshIfOnline;

  /// Whether the coordinator's `page` is currently `ChatPage.conversation`.
  final bool Function() isConversationPage;

  /// The coordinator's general "nothing else is in flight, connector
  /// trusted" check -- shared across every page, not conversation-specific.
  final bool Function() canRefresh;

  /// Moves the coordinator's `page` back to `ChatPage.chats` -- used only by
  /// [deleteCurrentChat], whose deletion confirms while still viewing the
  /// now-deleted chat.
  final void Function() leaveConversationPage;

  final ModelSelectionViewModel models;
  final ChatImagePreferences _imagePreferences;
  late final ChatStream _stream;

  bool _disposed = false;
  bool _covered = false;
  bool _sending = false;
  bool _creating = false, _creationUncertain = false;
  int _draftNumber = 0;
  Timer? _poll;

  @override
  bool get scopeValid => !_disposed && active();

  bool get activityLive =>
      online() && !_covered && (!_stream.supported || _stream.live);
  bool get isWorking =>
      online() &&
      !_covered &&
      error == null &&
      (status == 'busy' ||
          messages.any(
            (m) =>
                m.parts?.any(
                  // A subtask carries no activity of its own, and a background
                  // one leaves this session idle while it runs, so its own
                  // status is the only sign the chat is still waiting.
                  (p) => p.activity?.running == true || p.task?.active == true,
                ) ==
                true,
          ));

  void _schedulePoll() {
    _poll?.cancel();
    if (_disposed ||
        !online() ||
        _covered ||
        chat == null ||
        !isConversationPage() ||
        _stream.active) {
      return;
    }
    _poll = Timer(const Duration(seconds: 3), () {
      unawaited(snapshot(quiet: true).whenComplete(_schedulePoll));
    });
  }

  bool _showImages = true;
  bool get showImages => _showImages;
  Future<void> _loadShowImages() async {
    bool value;
    try {
      value = await _imagePreferences.readShowImages();
    } catch (_) {
      // Platform storage may be unavailable (e.g. a cold start race or a
      // host without the plugin registered); keep the safe default.
      return;
    }
    if (_disposed || value == _showImages) return;
    _showImages = value;
    notifyListeners();
  }

  Future<void> setShowImages(bool value) async {
    if (value == _showImages) return;
    _showImages = value;
    notifyListeners();
    try {
      await _imagePreferences.writeShowImages(value);
    } catch (_) {
      // Best-effort persistence; the in-memory choice above still applies.
    }
    if (!_disposed && online() && chat != null) await snapshot(quiet: true);
  }

  /// Stops the live stream/poll (e.g. the app is backgrounded or the screen
  /// is covered for security) and resumes with a fresh read when uncovered.
  void setCovered(bool covered) {
    _covered = covered;
    if (covered) {
      _stream.stop();
      _poll?.cancel();
    } else if (online() && chat != null) {
      unawaited(snapshot(quiet: true));
    }
    notifyListeners();
  }

  PromptMode? _selectedPromptMode;
  bool get supportsPromptMode =>
      repository.chatSupports(connectorId, 'chat.prompt') &&
      repository.chatSupports(connectorId, 'chat.prompt.mode');
  PromptMode? get promptMode =>
      _selectedPromptMode ?? (supportsPromptMode ? PromptMode.build : null);
  bool get canChangePromptMode =>
      !_disposed &&
      !isSubtask &&
      isConversationPage() &&
      online() &&
      !busyGate.mutating &&
      !_sending &&
      !_creating &&
      !trustLost() &&
      repository.chatTrusted(connectorId);

  void selectPromptMode(PromptMode mode) {
    if (!canChangePromptMode || !supportsPromptMode) return;
    _selectedPromptMode = mode;
    notifyListeners();
  }

  bool get canChangeModel =>
      !_disposed &&
      !isSubtask &&
      isConversationPage() &&
      online() &&
      !busyGate.mutating &&
      !_sending &&
      !_creating &&
      !trustLost() &&
      repository.chatTrusted(connectorId);

  Future<void> loadAvailableModels({bool force = false}) async {
    if (!canChangeModel || !models.supportsModelSelection) return;
    final selected = project();
    if (selected == null) return;
    await models.loadModels(selected.id, force: force);
  }

  void selectModel(ChatModelOption? model, [String? effort]) {
    if (!canChangeModel || !models.supportsModelSelection) return;
    models.select(model, effort);
  }

  RemoteChat? chat;
  String? get error => errorBox.value;
  String status = 'unknown';
  ChatPermission? permission;
  ChatQuestion? question;

  /// The id of the pending batch the composer is currently drafting a free-text
  /// answer for, or null. Compared against [question]'s own id rather than cleared
  /// eagerly, so it naturally stops applying the moment that batch is answered,
  /// replaced or goes away -- the same "derive, don't chase every clear site" shape
  /// [question] itself already relies on.
  String? _answeringQuestionId;
  int? _answeringQuestionIndex;
  bool get answeringCustomQuestion =>
      _answeringQuestionId != null && _answeringQuestionId == question?.id;

  /// The index within the pending batch being drafted, when [answeringCustomQuestion].
  int? get answeringQuestionIndex =>
      answeringCustomQuestion ? _answeringQuestionIndex : null;

  /// Answers staged so far for the pending batch, by index, in the wire shape
  /// (`{'selected': [...]}` or `{'text': ...}`) -- keyed to [question]'s own id so a
  /// new or replaced batch never inherits a previous one's drafts. Nothing is sent to
  /// OpenCode until every entry is non-null; see [_submitQuestionIfComplete].
  String? _stagedBatchId;
  final List<Map<String, dynamic>?> _staged = [];

  void _ensureStaged(ChatQuestion pending) {
    if (_stagedBatchId == pending.id) return;
    _stagedBatchId = pending.id;
    _staged
      ..clear()
      ..addAll(
        List<Map<String, dynamic>?>.filled(pending.questions.length, null),
      );
  }

  /// The option indices already staged for question [index] of the pending batch, or
  /// null if that question has no staged answer (including one staged as free text,
  /// which has no option indices to show as selected).
  List<int>? stagedSelection(int index) {
    final pending = question;
    if (pending == null) return null;
    _ensureStaged(pending);
    if (index < 0 || index >= _staged.length) return null;
    final selected = _staged[index]?['selected'];
    return selected is List<int> ? selected : null;
  }

  /// OpenCode's own task list for this chat, in its order. Read-only -- the
  /// agent writes it; this app only counts and shows it. See CHAT-TODOS.md.
  List<ChatTodo> todos = const [];
  bool get supportsTodos => repository.chatSupports(connectorId, 'chat.todos');

  /// Completed items over the whole list. A cancelled task keeps its place in
  /// the denominator: the count reports the plan as written, and the banner
  /// says which items were dropped rather than quietly shrinking the total.
  int get todosDone => todos.where((todo) => todo.done).length;
  int get todosTotal => todos.length;

  /// Whether the user dismissed the task tab from the task list once every
  /// task on it was done. Cleared the moment the list stops being fully
  /// done -- a task added or reopened later never stays hidden behind an
  /// old dismissal of a different, finished list.
  bool todosHidden = false;

  /// Which finished list each chat's user dismissed, by chat id, so leaving a
  /// chat and coming back doesn't bring back a list they already put away.
  /// Kept only in memory for as long as this flow is open: the signature is
  /// derived from task text, which never goes to device storage. Not cleared
  /// by [open]/[startNew]/[_clearMessages] -- it must survive a chat switch
  /// and back, which is the entire point of keying it by chat id.
  final _dismissedTodos = <String, int>{};

  /// Identifies one list as the agent wrote it. A different plan -- other
  /// tasks, or the same tasks in another order -- is a different list, and an
  /// old dismissal never hides it.
  int get _todosSignature =>
      Object.hashAll(todos.map((todo) => Object.hash(todo.id, todo.content)));

  void hideTodos() {
    if (todosHidden) return;
    todosHidden = true;
    if (chat case final chat?) _dismissedTodos[chat.id] = _todosSignature;
    notifyListeners();
  }

  /// Whether a hidden list can be brought back. Hiding only stops the tab
  /// being drawn -- the list itself is untouched and still counted -- so this
  /// is offered whenever a list is being held back from a chat that has one.
  bool get canShowTodos => todosHidden && todosTotal > 0;

  /// Brings a hidden task list back, from Chat options: the tab is the only
  /// way into the list, so dismissing it must be undoable without waiting for
  /// the agent to write a different plan.
  void showTodos() {
    if (!todosHidden) return;
    todosHidden = false;
    if (chat case final chat?) _dismissedTodos.remove(chat.id);
    notifyListeners();
  }

  /// Re-derives [todosHidden] from what the user dismissed whenever a list
  /// arrives, so it holds across leaving and re-entering the chat.
  void _syncTodosHidden() {
    final id = chat?.id;
    // An empty list shows nothing either way, and is also what a failed read
    // looks like -- so it keeps the dismissal rather than forgetting it.
    if (id == null || todosTotal == 0) {
      todosHidden = false;
      return;
    }
    if (todosDone != todosTotal) {
      // The plan is no longer finished: whatever was dismissed is over, and a
      // later finished list must be shown until it is dismissed in its turn.
      todosHidden = false;
      _dismissedTodos.remove(id);
      return;
    }
    todosHidden = _dismissedTodos[id] == _todosSignature;
  }

  List<ChatMessage> messages = [];
  String? messageCursor;
  bool get loadingEarlierMessages => busyGate.loadingEarlierMessages;
  String? earlierMessagesError, messageHistoryNotice;
  bool _historyInitialized = false;
  final _messageCursors = <String>{};
  int messageHistoryRevision = 0;
  bool get canLoadEarlierMessages =>
      !_disposed &&
      online() &&
      isConversationPage() &&
      chat != null &&
      project() != null &&
      messageCursor != null &&
      !busyGate.loading &&
      !busyGate.mutating &&
      !busyGate.reading;

  bool get _canManageChat =>
      canRefresh() &&
      !isSubtask &&
      isConversationPage() &&
      chat != null &&
      project() != null &&
      !_creating &&
      !chatList.isPinning;
  bool get canRename =>
      _canManageChat && repository.chatSupports(connectorId, 'chat.rename');
  bool get chatActionsUnsupported =>
      online() &&
      (!repository.chatSupports(connectorId, 'chat.rename') ||
          !repository.chatSupports(connectorId, 'chat.fork'));
  String? get _forkNotice {
    final selectedProject = project();
    if (selectedProject == null || chat == null) return null;
    return forkNoticeFor(selectedProject.path, chat!.id);
  }

  bool get canFork =>
      _canManageChat &&
      status == 'idle' &&
      _forkNotice == null &&
      repository.chatSupports(connectorId, 'chat.fork');
  bool get canDeleteCurrentChat =>
      _canManageChat &&
      status == 'idle' &&
      chat!.parentId == null &&
      repository.chatSupports(connectorId, 'chat.delete');
  bool get isSending => busyGate.mutating && _sending;
  String get progressLabel => switch (busyGate.chatAction) {
    'chat.rename' => 'Renaming chat',
    'chat.fork' => 'Forking chat',
    'chat.delete' => 'Deleting chat',
    _ => 'Loading OpenCode',
  };
  static String? validateChatTitle(String? value) {
    final title = value?.trim() ?? '';
    if (title.isEmpty) return 'Enter a chat name.';
    if (title.length > 512) return 'Use 512 characters or fewer.';
    return null;
  }

  bool get isDraft => isConversationPage() && chat == null;
  String? get composerKey => !isConversationPage()
      ? null
      : chat == null
      ? 'draft:$_draftNumber'
      : 'chat:${chat!.id}';
  bool get canSend =>
      !_disposed &&
      !trustLost() &&
      !isSubtask &&
      isConversationPage() &&
      project() != null &&
      online() &&
      !busyGate.loading &&
      !busyGate.mutating &&
      !_sending &&
      !busyGate.reading &&
      busyGate.chatAction == null &&
      !_creating &&
      !_creationUncertain &&
      (_selectedPromptMode == null || supportsPromptMode) &&
      (models.selectedModel == null || models.supportsModelSelection);

  Future<Map<String, dynamic>> _request(
    String operation, [
    Map<String, dynamic> body = const {},
  ]) => repository.chatRequest(connectorId, operation, body);

  void _handleFailure(Object failure) {
    errorBox.value = describeChatFailure(failure);
  }

  @override
  String? get pendingForkNotice => _forkNotice;
  String? get pendingCredentialNotice => credentialNotice();

  @override
  String? get pendingCreationUncertainMessage => _creationUncertain
      ? 'The new chat could not be confirmed. Return to Chats and refresh before trying again.'
      : null;

  /// Reschedules the background snapshot poll, exposed for the coordinator's
  /// own cross-domain [run] calls (`refresh`) to invoke too -- the original
  /// single-class `_run` called this unconditionally after every successful
  /// operation, not just conversation-scoped ones; it's a no-op when this
  /// isn't the open conversation.
  void schedulePollIfNeeded() => _schedulePoll();

  /// Clears the open chat and its history without touching [busyGate] --
  /// used by coordinator-level orchestration (openProject, openPath, back,
  /// backToProjects, a chat's own deletion, trust loss) that already governs
  /// its own generation/busy-gate transition.
  void closeChat() {
    // Whatever was in flight for this chat (a snapshot read, a rename/fork/
    // send) no longer applies once it's no longer the open chat.
    invalidate();
    chat = null;
    _creationUncertain = false;
    _clearMessages();
    // Callers (openProject, openPath, back, backToProjects, a chat's own
    // deletion, trust loss) drive this under their own generation/busy-gate
    // transition and notify their own listeners afterward, but a widget that
    // listens directly to this scope (e.g. a details route or rename dialog
    // watching `composerKey`/`chat`) needs its own notification too.
    notifyListeners();
  }

  /// Clears chat-scoped selection state that must not survive a trust loss --
  /// connector re-pairing may offer a different model/provider list.
  void resetOnTrustLoss() {
    _selectedPromptMode = null;
    models.resetAll();
  }

  void notifyConnectionChanged() => _stream.connectionChanged();

  /// Stops the live stream/poll without clearing chat data -- used when the
  /// connector goes offline or the app backgrounds.
  void stopLive() {
    _poll?.cancel();
    _stream.stop();
  }

  /// Reloads the open chat's snapshot as part of a coordinator-driven
  /// project refresh, validated against the caller's own generation rather
  /// than this scope's -- matches the original single-class `refresh()`,
  /// which read the conversation snapshot under the same generation as the
  /// project-list fetch that preceded it.
  ///
  /// [resetHistory] should be true only for a refresh the user actually
  /// asked for (the "Refresh" menu action, an authoritative reload). A
  /// reconnect or background-resume driven refresh is not evidence the
  /// chat's identity changed, so it should merge instead: forcing a reset
  /// there used to collapse an already-loaded, possibly-long history down
  /// to just the latest page on every reconnect, jumping the reader's
  /// scroll position back to the bottom. `open`/`startNew`/trust loss reset
  /// through their own explicit paths regardless of this flag.
  Future<void> reloadForProjectRefresh({
    required int generation,
    required bool Function() isValid,
    bool resetHistory = true,
  }) => _readSnapshot(generation, resetHistory: resetHistory, isValid: isValid);

  /// Resets to a brand-new, unopened chat -- entering the conversation page
  /// with an empty draft rather than an existing session.
  void startNew() {
    invalidate();
    _draftNumber++;
    busyGate.reading = false;
    _creationUncertain = false;
    errorBox.value = null;
    chat = null;
    _clearMessages();
    status = 'idle';
    notifyListeners();
  }

  /// Opens [selected] and fetches its snapshot.
  Future<void> open(RemoteChat selected) async {
    invalidate();
    busyGate.reading = false;
    chat = selected;
    _creationUncertain = false;
    _clearMessages();
    status = 'unknown';
    permission = null;
    question = null;
    // A model choice belongs to the chat it was made in -- carrying it over
    // into a different chat would silently redirect that chat's prompts too.
    // The snapshot below recovers this chat's own last-used model, if any.
    models.reset();
    notifyListeners();
    await snapshot();
  }

  Future<void> snapshot({bool quiet = false}) => run(
    _readSnapshot,
    quiet: quiet,
    onFailure: _handleFailure,
    onAfterSuccess: schedulePollIfNeeded,
    onAfterStale: scheduleRefreshIfOnline,
  );

  Future<void> _readSnapshot(
    int generation, {
    bool older = false,
    bool resetHistory = false,
    bool Function()? isValid,
  }) async {
    final check = isValid ?? () => valid(generation);
    if (chat == null) return;
    final selectedProject = project();
    if (selectedProject == null) return;
    if (!older) _stream.stop();
    final cursor = older ? messageCursor : null;
    final response = await _request(
      isSubtask ? 'chat.subtask.snapshot' : 'chat.snapshot',
      {
        'projectId': selectedProject.id,
        'sessionId': chat!.id,
        'cursor': ?cursor,
        if (isSubtask) 'parentSessionId': parentSessionId,
        if (!isSubtask && supportsSubtasks) 'includeSubtasks': true,
        if (repository.chatSupports(connectorId, 'chat.tools'))
          'includeTools': true,
        if (repository.chatSupports(connectorId, 'chat.tools') &&
            repository.chatSupports(connectorId, 'chat.shell'))
          'includeShell': true,
        if (repository.chatSupports(connectorId, 'chat.activities'))
          'includeActivities': true,
        if (_showImages && repository.chatSupports(connectorId, 'chat.images'))
          'includeImages': true,
        if (repository.chatSupports(connectorId, 'chat.permissions'))
          'includePermissions': true,
        if (repository.chatSupports(connectorId, 'chat.questions'))
          'includeQuestions': true,
        if (supportsTodos) 'includeTodos': true,
      },
    );
    final next = parseItems(response, 'messages', 10, ChatMessage.parse);
    final summary = RemoteChat.parse(requiredMap(response, 'chat'));
    if (!check()) return;
    if (summary.id != chat!.id ||
        summary.parentId != parentSessionId ||
        !['idle', 'busy', 'retry', 'unknown'].contains(response['status'])) {
      throw ChatFailure.invalid;
    }
    final nextCursor = pageCursor(response);
    if (older &&
        nextCursor != null &&
        (nextCursor == cursor || _messageCursors.contains(nextCursor))) {
      throw ChatFailure.invalid;
    }
    if (resetHistory) _clearMessages();
    chat = summary;
    _syncChatList(summary);
    status = response['status'] as String;
    permission = parsePermission(response);
    question = parseQuestion(response);
    todos = parseTodos(response) ?? const [];
    _syncTodosHidden();
    // Only the unpaginated (latest) fetch's `model` reliably reflects what
    // this chat is currently using; an earlier-history page never sets one.
    if (!older) models.applyRecovered(response['model']);
    if (older) {
      messages = {
        for (final m in [...next, ...messages]) m.id: m,
      }.values.toList();
      if (cursor != null) _messageCursors.add(cursor);
      messageCursor = nextCursor;
    } else {
      messages = {
        for (final m in [...messages, ...next]) m.id: m,
      }.values.toList();
      // Latest-page polling must never replace the oldest retained cursor or
      // reopen an exhausted/capped history, even when fewer than 10 rows remain.
      if (!_historyInitialized) messageCursor = nextCursor;
    }
    _historyInitialized = true;
    if (messages.length > 200 ||
        (messages.length == 200 && messageCursor != null)) {
      messages = messages.skip(messages.length - 200).toList();
      messageCursor = null;
      messageHistoryNotice = 'Showing the latest 200 loaded messages. Earlier history is not shown.';
    } else if (_messageCursors.length >= 100 && messageCursor != null) {
      messageCursor = null;
      messageHistoryNotice =
          'The history page limit was reached. Earlier history is not shown.';
    }
    if (!_covered && online() && check()) {
      await _stream.start({
        'projectId': selectedProject.id,
        'sessionId': chat!.id,
        if (isSubtask) 'parentSessionId': parentSessionId,
        if (!isSubtask && supportsSubtasks) 'includeSubtasks': true,
        if (repository.chatSupports(connectorId, 'chat.tools'))
          'includeTools': true,
        if (repository.chatSupports(connectorId, 'chat.tools') &&
            repository.chatSupports(connectorId, 'chat.shell'))
          'includeShell': true,
        if (repository.chatSupports(connectorId, 'chat.activities'))
          'includeActivities': true,
        if (_showImages && repository.chatSupports(connectorId, 'chat.images'))
          'includeImages': true,
        if (repository.chatSupports(connectorId, 'chat.permissions'))
          'includePermissions': true,
        if (repository.chatSupports(connectorId, 'chat.questions'))
          'includeQuestions': true,
        if (supportsTodos) 'includeTodos': true,
      });
      _schedulePoll();
    }
    // `reloadForProjectRefresh` calls this directly, outside this scope's own
    // `run()` wrapper (it runs under the coordinator's project-refresh
    // generation instead) -- so unlike every other caller, notifying isn't
    // otherwise handled afterward. A widget listening directly to this scope
    // (not just the coordinator) still needs to see the reloaded snapshot.
    notifyListeners();
  }

  // Snapshot polling picks up OpenCode's own asynchronous title generation
  // (fires after the first prompt) as well as edits from other clients, but
  // only this chat's own `chat` field reflected it until now -- the project's
  // chat list kept showing the creation-time placeholder title until the
  // list was refetched from scratch. Subtasks never appear in that list.
  void _syncChatList(RemoteChat summary) {
    if (isSubtask) return;
    final current = chatList.chats.where((c) => c.id == summary.id).firstOrNull;
    if (current != null &&
        current.title == summary.title &&
        current.updatedAt == summary.updatedAt) {
      return;
    }
    chatList.applyUpdatedChat(summary);
  }

  void _streamSnapshot(Map<String, dynamic> response, bool reset) {
    if (_disposed || chat == null) return;
    final summary = RemoteChat.parse(requiredMap(response, 'chat'));
    final next = parseItems(response, 'messages', 10, ChatMessage.parse);
    if (response['version'] != 1 ||
        summary.id != chat!.id ||
        summary.parentId != parentSessionId ||
        !['idle', 'busy', 'retry', 'unknown'].contains(response['status'])) {
      throw ChatFailure.invalid;
    }
    if (reset) {
      messages = [];
      messageCursor = pageCursor(response);
      _messageCursors.clear();
      messageHistoryRevision++;
    }
    chat = summary;
    _syncChatList(summary);
    status = response['status'] as String;
    permission = parsePermission(response);
    question = parseQuestion(response);
    todos = parseTodos(response) ?? const [];
    _syncTodosHidden();
    messages = {
      for (final message in [...messages, ...next]) message.id: message,
    }.values.toList();
    if (messages.length > 200) {
      messages = messages.skip(messages.length - 200).toList();
      messageCursor = null;
      messageHistoryNotice = 'Showing the latest 200 loaded messages. Earlier history is not shown.';
    }
    notifyListeners();
  }

  Future<void> olderMessages() async {
    if (!canLoadEarlierMessages) return;
    await run(
      (g) => _readSnapshot(g, older: true),
      earlierMessages: true,
      onStart: () => earlierMessagesError = null,
      onFailure: (failure) =>
          earlierMessagesError = describeChatFailure(failure),
      onAfterSuccess: schedulePollIfNeeded,
      onAfterStale: scheduleRefreshIfOnline,
    );
  }

  void _clearMessages() {
    _stream.stop();
    _poll?.cancel();
    messages = [];
    // A task list belongs to the chat it was written in; carrying one over
    // would count another conversation's plan in this one's header.
    todos = const [];
    todosHidden = false;
    messageCursor = null;
    _historyInitialized = false;
    _messageCursors.clear();
    busyGate.loadingEarlierMessages = false;
    earlierMessagesError = null;
    messageHistoryNotice = null;
    messageHistoryRevision++;
  }

  Future<bool> _createForPrompt(int generation) async {
    final draftKey = composerKey;
    final selected = project();
    if (selected == null) return false;
    bool sameDraft() =>
        !_disposed &&
        !trustLost() &&
        composerKey == draftKey &&
        project()?.path == selected.path;
    _creating = true;
    try {
      final response = await _request('chat.create', {
        'projectId': selected.id,
      });
      final created = RemoteChat.parse(requiredMap(response, 'chat'));
      if (!sameDraft()) return false;
      // Keep a confirmed session after a disconnect/background transition, so
      // an explicit retry uses it. Never send the prompt after cancellation.
      chat = created;
      chatList.applyCreatedChat(created);
      notifyListeners();
      if (valid(generation) &&
          repository.chatSupports(connectorId, 'chat.stream.subscribe')) {
        await _readSnapshot(generation);
      }
      return valid(generation);
    } catch (failure) {
      if (sameDraft() &&
          ![
            ChatFailure.denied,
            ChatFailure.expired,
            ChatFailure.unsupported,
            ChatFailure.busy,
          ].contains(failure)) {
        _creationUncertain = true;
        errorBox.value = ChatFailure.uncertain.message;
        notifyListeners();
      }
      rethrow;
    } finally {
      _creating = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> send(String input) async {
    if (input.trim().isEmpty || input.length > 32000 || !canSend) {
      return false;
    }
    var accepted = false;
    final mode = promptMode;
    final selectedModel = models.selectedModel;
    final selectedEffort = models.selectedEffort;
    final sendGeneration = generation;
    _sending = true;
    try {
      await run(
        (generation) async {
          final selectedProject = project();
          if (selectedProject == null) return;
          if (chat == null && !await _createForPrompt(generation)) return;
          if (mode != null && !supportsPromptMode) {
            throw ChatFailure.unsupported;
          }
          if (selectedModel != null && !models.supportsModelSelection) {
            throw ChatFailure.unsupported;
          }
          final response = await _request('chat.prompt', {
            'projectId': selectedProject.id,
            'sessionId': chat!.id,
            'text': input,
            if (mode != null) 'mode': mode.name,
            if (selectedModel != null)
              'model': {
                'providerID': selectedModel.providerId,
                'modelID': selectedModel.modelId,
                'effort': ?selectedEffort,
              },
          });
          if (!valid(generation)) return;
          if (response['accepted'] != true) throw ChatFailure.invalid;
          accepted = true;
          if (!_stream.live) await _readSnapshot(generation);
        },
        mutation: true,
        onFailure: _handleFailure,
        onAfterSuccess: schedulePollIfNeeded,
        onAfterStale: scheduleRefreshIfOnline,
      );
    } finally {
      _sending = false;
      if (!_disposed) notifyListeners();
    }
    return accepted && valid(sendGeneration);
  }

  Future<void> abort() => run(
    (generation) async {
      final selectedProject = project();
      if (chat == null || isSubtask || selectedProject == null) return;
      await _request('chat.abort', {
        'projectId': selectedProject.id,
        'sessionId': chat!.id,
      });
      if (valid(generation)) await _readSnapshot(generation);
    },
    mutation: true,
    onFailure: _handleFailure,
    onAfterSuccess: schedulePollIfNeeded,
    onAfterStale: scheduleRefreshIfOnline,
  );

  bool get supportsPermissionReply =>
      repository.chatSupports(connectorId, 'chat.permission.reply');

  bool get supportsQuestionReply =>
      repository.chatSupports(connectorId, 'chat.question.reply');

  /// Stages an answer of selected option indices for question [index] of the pending
  /// batch. Once every question in the batch has a staged answer, submits the whole
  /// batch in one `chat.question.reply` -- with a single-question batch this
  /// reproduces the original "tap Answer -> sends immediately" behavior exactly.
  /// Free text instead goes through [answerQuestionAtWithText]; rejecting the whole
  /// batch goes through [rejectQuestion].
  Future<void> answerQuestionAt(int index, List<int> selected) {
    final pending = question;
    if (pending == null ||
        !supportsQuestionReply ||
        index < 0 ||
        index >= pending.questions.length) {
      return Future.value();
    }
    final options = pending.questions[index].options;
    final valid_ =
        selected
            .where(
              (optionIndex) => optionIndex >= 0 && optionIndex < options.length,
            )
            .toSet()
            .toList(growable: false)
          ..sort();
    if (valid_.isEmpty) return Future.value();
    _ensureStaged(pending);
    _staged[index] = {'selected': valid_};
    notifyListeners();
    return _submitQuestionIfComplete();
  }

  /// Rejects the whole pending batch, from any page. OpenCode's own reject has no
  /// per-question form, so there is no way to decline part of a batch while answering
  /// the rest -- replaces the old "empty selection" reject path.
  Future<void> rejectQuestion() => run(
    (generation) async {
      final pending = question;
      final selectedProject = project();
      if (chat == null ||
          pending == null ||
          !supportsQuestionReply ||
          selectedProject == null) {
        return;
      }
      // Optimistic for the same reason as a permission reply: a stale prompt asking
      // about an already-answered batch is worse than a brief gap.
      question = null;
      _answeringQuestionId = null;
      _answeringQuestionIndex = null;
      _stagedBatchId = null;
      _staged.clear();
      notifyListeners();
      await _request('chat.question.reply', {
        'projectId': selectedProject.id,
        'sessionId': chat!.id,
        'questionId': pending.id,
        'response': 'reject',
      });
      if (valid(generation)) await _readSnapshot(generation);
    },
    mutation: true,
    onFailure: _handleFailure,
    onAfterSuccess: schedulePollIfNeeded,
    onAfterStale: scheduleRefreshIfOnline,
  );

  /// Switches the composer into drafting a free-text answer to question [index] of the
  /// pending batch, mirroring OpenCode's own TUI "type your own answer" affordance --
  /// only offered when that question's own [ChatQuestionPrompt.custom] flag allows it.
  /// See ADR 0011.
  void startQuestionCustomAnswer(int index) {
    final pending = question;
    if (pending == null ||
        index < 0 ||
        index >= pending.questions.length ||
        !pending.questions[index].custom ||
        !supportsQuestionReply) {
      return;
    }
    _answeringQuestionId = pending.id;
    _answeringQuestionIndex = index;
    notifyListeners();
  }

  /// Leaves free-text drafting and returns to the option list, without answering.
  void cancelQuestionCustomAnswer() {
    if (_answeringQuestionId == null) return;
    _answeringQuestionId = null;
    _answeringQuestionIndex = null;
    notifyListeners();
  }

  /// Stages [text] as question [index]'s answer, the same way [answerQuestionAt]
  /// stages an option selection -- see there for the batch-completion/auto-submit
  /// rule. The text is forwarded as-typed, the same way a normal chat message already
  /// forwards free text -- see ADR 0011. Returns whether it was actually staged, the
  /// same "safe to clear the draft" signal [send] returns, so the composer can share
  /// its own clear-on-success handling.
  Future<bool> answerQuestionAtWithText(int index, String text) async {
    final pending = question;
    final trimmed = text.trim();
    if (pending == null ||
        !supportsQuestionReply ||
        index < 0 ||
        index >= pending.questions.length ||
        !pending.questions[index].custom ||
        trimmed.isEmpty) {
      return false;
    }
    _ensureStaged(pending);
    _staged[index] = {
      'text': trimmed.length > 2000 ? trimmed.substring(0, 2000) : trimmed,
    };
    _answeringQuestionId = null;
    _answeringQuestionIndex = null;
    notifyListeners();
    await _submitQuestionIfComplete();
    return true;
  }

  /// Sends the whole pending batch's staged answers, in order, once every question has
  /// one -- the single place [answerQuestionAt]/[answerQuestionAtWithText]'s "auto-
  /// submit on completion" rule lives.
  Future<void> _submitQuestionIfComplete() => run(
    (generation) async {
      final pending = question;
      final selectedProject = project();
      if (chat == null ||
          pending == null ||
          !supportsQuestionReply ||
          selectedProject == null) {
        return;
      }
      _ensureStaged(pending);
      if (_staged.any((answer) => answer == null)) return;
      final answers = List<Map<String, dynamic>>.from(
        _staged.cast<Map<String, dynamic>>(),
      );
      // Optimistic for the same reason as a permission reply: a stale prompt asking
      // about an already-answered batch is worse than a brief gap.
      question = null;
      _answeringQuestionId = null;
      _answeringQuestionIndex = null;
      _stagedBatchId = null;
      _staged.clear();
      notifyListeners();
      await _request('chat.question.reply', {
        'projectId': selectedProject.id,
        'sessionId': chat!.id,
        'questionId': pending.id,
        'response': 'answer',
        'answers': answers,
      });
      if (valid(generation)) await _readSnapshot(generation);
    },
    mutation: true,
    onFailure: _handleFailure,
    onAfterSuccess: schedulePollIfNeeded,
    onAfterStale: scheduleRefreshIfOnline,
  );

  /// Answers the pending permission request. [PermissionDecision.always] is a
  /// persistent grant, sent only for an explicit user tap. See
  /// CHAT-PERMISSIONS.md.
  Future<void> respondToPermission(PermissionDecision decision) => run(
    (generation) async {
      final pending = permission;
      final selectedProject = project();
      if (chat == null ||
          pending == null ||
          !supportsPermissionReply ||
          selectedProject == null) {
        return;
      }
      // Optimistic: the next snapshot reconciles this either way, and a stale
      // banner asking about an already-answered request is worse than a brief
      // gap before the authoritative state confirms it.
      permission = null;
      notifyListeners();
      await _request('chat.permission.reply', {
        'projectId': selectedProject.id,
        'sessionId': chat!.id,
        'permissionId': pending.id,
        'response': decision.wire,
      });
      if (valid(generation)) await _readSnapshot(generation);
    },
    mutation: true,
    onFailure: _handleFailure,
    onAfterSuccess: schedulePollIfNeeded,
    onAfterStale: scheduleRefreshIfOnline,
  );

  Future<bool> renameChat(String input) async {
    if (!canRename) return false;
    final validation = validateChatTitle(input);
    if (validation != null) {
      errorBox.value = validation;
      notifyListeners();
      return false;
    }
    final title = input.trim();
    if (title == chat!.title) return true;
    final selected = chat!;
    final selectedProject = project();
    if (selectedProject == null) return false;
    var saved = false;
    await run(
      (generation) async {
        final response = await _request('chat.rename', {
          'projectId': selectedProject.id,
          'sessionId': selected.id,
          'title': title,
        });
        final renamed = RemoteChat.parse(requiredMap(response, 'chat'));
        if (response['version'] != 1 ||
            renamed.id != selected.id ||
            renamed.title != title ||
            renamed.parentId != null) {
          throw ChatFailure.invalid;
        }
        if (!valid(generation)) return;
        chat = renamed;
        chatList.applyUpdatedChat(renamed);
        saved = true;
      },
      mutation: true,
      chatAction: 'chat.rename',
      onFailure: _handleFailure,
      onAfterSuccess: schedulePollIfNeeded,
      onAfterStale: scheduleRefreshIfOnline,
    );
    return saved;
  }

  Future<void> forkChat() async {
    if (!canFork) return;
    final selected = chat!;
    final selectedProject = project();
    if (selectedProject == null) return;
    await run(
      (generation) async {
        late final RemoteChat fork;
        try {
          final response = await _request('chat.fork', {
            'projectId': selectedProject.id,
            'sessionId': selected.id,
          });
          fork = RemoteChat.parse(requiredMap(response, 'chat'));
          if (response['version'] != 1 ||
              fork.id == selected.id ||
              fork.parentId != null) {
            throw ChatFailure.invalid;
          }
        } catch (failure) {
          if (!_disposed &&
              !trustLost() &&
              ![
                ChatFailure.denied,
                ChatFailure.expired,
                ChatFailure.unsupported,
                ChatFailure.busy,
                ChatFailure.chatBusy,
                ChatFailure.notFound,
              ].contains(failure)) {
            setForkNotice(
              selectedProject.path,
              selected.id,
              'The fork could not be confirmed. Return to Chats and check for the new chat before forking again.',
            );
          }
          rethrow;
        }
        if (!valid(generation)) {
          if (!_disposed && !trustLost()) {
            setForkNotice(
              selectedProject.path,
              selected.id,
              'A fork was created. Return to Chats to open it before forking again.',
            );
          }
          return;
        }
        chat = fork;
        chatList.applyCreatedChat(fork);
        _clearMessages();
        status = 'unknown';
        permission = null;
        question = null;
        notifyListeners();
        await _readSnapshot(generation);
      },
      mutation: true,
      chatAction: 'chat.fork',
      onFailure: _handleFailure,
      onAfterSuccess: schedulePollIfNeeded,
      onAfterStale: scheduleRefreshIfOnline,
    );
  }

  Future<void> deleteCurrentChat() async {
    if (!canDeleteCurrentChat) return;
    final selected = chat!;
    final selectedProject = project();
    if (selectedProject == null) return;
    final startGeneration = generation;
    await chatList.deleteChat(
      selected,
      selectedProject,
      isCurrent: true,
      canDeleteCurrent: () => canDeleteCurrentChat,
      // The delete itself runs under ChatListViewModel's own generation, but
      // applying "this was the open chat" once the response arrives must
      // also still be true for *this* conversation scope -- e.g. the user
      // may have navigated to a different chat while the request was in
      // flight, which only bumps this scope's generation, not the list's.
      isValid: () => valid(startGeneration),
      onCurrentChatDeleted: () {
        leaveConversationPage();
        chat = null;
        status = 'unknown';
        permission = null;
        question = null;
        _clearMessages();
      },
    );
  }

  @override
  void dispose() {
    _disposed = true;
    invalidate();
    _poll?.cancel();
    _stream.dispose();
    models.dispose();
    super.dispose();
  }
}
