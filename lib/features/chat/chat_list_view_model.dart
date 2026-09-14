import 'package:flutter/foundation.dart';

import '../../platform/remote_api.dart';
import 'chat_request_scope.dart';
import 'data/chat_repository.dart';
import 'domain/chat_models.dart';

/// The current project's chat list: pagination, pinning, sort order, and
/// deletion from the list. `applyCreatedChat`/`applyUpdatedChat` let
/// `ConversationViewModel` keep this list in sync after a fork/rename of the
/// currently open chat without holding a reference back to it -- the
/// coordinator wires the two together.
final class ChatListViewModel extends ChangeNotifier with ChatRequestScope {
  ChatListViewModel(
    this.repository,
    this.connectorId,
    this.busyGate,
    this.errorBox, {
    required this.online,
    required this.trustLost,
    required this.active,
  });

  final ChatRepository repository;
  final String connectorId;
  @override
  final ChatBusyGate busyGate;
  @override
  final ChatErrorBox errorBox;
  final bool Function() online;
  final bool Function() trustLost;

  /// Whether the coordinator currently considers itself foregrounded --
  /// mirrors the original class's `_active` check inside its shared result
  /// validity test.
  final bool Function() active;

  bool _disposed = false;
  @override
  bool get scopeValid => !_disposed && active();

  List<RemoteChat> chats = [];
  String? chatCursor;
  int _chatPages = 0;
  String? moreChatsError;
  String? lastDeletedChatId;
  Set<String> _pinned = {};
  bool _pinsReady = false;
  bool _pinning = false;
  bool get isPinning => _pinning;

  bool isPinned(RemoteChat chat) => _pinned.contains(chat.id);
  bool get canPin =>
      _pinsReady &&
      !_pinning &&
      !busyGate.loading &&
      !busyGate.mutating &&
      repository.chatTrusted(connectorId);
  bool get canDelete =>
      !_disposed &&
      online() &&
      !busyGate.loading &&
      !busyGate.mutating &&
      !_pinning &&
      !trustLost() &&
      busyGate.chatAction == null &&
      repository.chatTrusted(connectorId);

  void _sortChats() => chats.sort((a, b) {
    if (isPinned(a) != isPinned(b)) return isPinned(a) ? -1 : 1;
    final updated = b.updatedAt.compareTo(a.updatedAt);
    return updated == 0 ? a.id.compareTo(b.id) : updated;
  });

  void reset() {
    // Whatever was in flight for this scope (a moreChats page, a delete) no
    // longer applies once the list itself is being replaced.
    invalidate();
    chats = [];
    chatCursor = null;
    _chatPages = 0;
    moreChatsError = null;
    _pinned = {};
    _pinsReady = false;
  }

  /// Raw fetch for coordinator-orchestrated flows (refresh/openProject/
  /// openPath), driven under the caller's own generation -- does not touch
  /// [busyGate] or this scope's own generation, but still bails out (without
  /// applying its result) once [isValid] turns false, at the same points the
  /// original single-class `_list` did. A pinned-id lookup failure degrades
  /// gracefully (unpinned list, reported error) rather than aborting the
  /// chat-list fetch.
  Future<void> fetchPage(
    RemoteProject project, {
    bool more = false,
    required bool Function() isValid,
  }) async {
    var pinned = _pinned;
    if (!more) {
      moreChatsError = null;
      chatCursor = null;
      _chatPages = 0;
      try {
        pinned = await repository.pinnedChatIds(connectorId, project.path);
        if (!isValid()) return;
        _pinsReady = true;
      } catch (_) {
        if (!isValid()) return;
        _pinsReady = false;
        pinned = {};
        errorBox.value = ChatFailure.pinStorage.message;
      }
    }
    final response = await repository.chatRequest(connectorId, 'chat.list', {
      'projectId': project.id,
      if (more && chatCursor != null) 'cursor': chatCursor,
    });
    final next = parseItems(
      response,
      'chats',
      50,
      RemoteChat.parse,
    ).where((chat) => chat.parentId == null).toList();
    if (!isValid()) return;
    if (!more) {
      final removedPins = <String>{};
      final missing = pinned
          .where((id) => !next.any((chat) => chat.id == id))
          .toList();
      for (var offset = 0; offset < missing.length; offset += 3) {
        final batch = missing.skip(offset).take(3);
        final summaries = await Future.wait(
          batch.map((id) async {
            try {
              final result = await repository.chatRequest(
                connectorId,
                'chat.get',
                {'projectId': project.id, 'sessionId': id},
              );
              final chat = RemoteChat.parse(requiredMap(result, 'chat'));
              if (chat.id != id || chat.parentId != null) {
                throw ChatFailure.invalid;
              }
              return chat;
            } catch (failure) {
              if (failure == ChatFailure.notFound) removedPins.add(id);
              if (isValid() &&
                  failure != ChatFailure.notFound &&
                  failure != ChatFailure.denied) {
                errorBox.value = 'Some pinned chats could not be loaded. Refresh to try again.';
              }
              return null;
            }
          }),
        );
        next.addAll(summaries.whereType<RemoteChat>());
      }
      for (final id in removedPins) {
        try {
          pinned = await repository.setChatPinned(
            connectorId,
            project.path,
            id,
            false,
          );
        } catch (_) {
          if (isValid()) errorBox.value = ChatFailure.pinStorage.message;
        }
      }
    }
    final nextCursor = pageCursor(response);
    if (more && nextCursor != null && nextCursor == chatCursor) {
      throw ChatFailure.invalid;
    }
    _pinned = pinned;
    chats = {
      for (final item in [...(more ? chats : <RemoteChat>[]), ...next])
        item.id: item,
    }.values.toList();
    _sortChats();
    chatCursor = nextCursor;
    _chatPages++;
    if (chats.length > 1000 || (chats.length == 1000 && chatCursor != null)) {
      chats = chats.take(1000).toList();
      chatCursor = null;
      errorBox.value = 'Showing the first 1,000 chats. The list is incomplete.';
    } else if (_chatPages >= 100 && chatCursor != null) {
      chatCursor = null;
      errorBox.value =
          'The chat page limit was reached. The list is incomplete.';
    }
  }

  Future<void> moreChats(RemoteProject project) async {
    if (chatCursor == null) return;
    await run(
      (generation) =>
          fetchPage(project, more: true, isValid: () => valid(generation)),
      moreChats: true,
      onStart: () => moreChatsError = null,
      onFailure: (failure) => moreChatsError = describeChatFailure(failure),
    );
  }

  Future<void> togglePin(RemoteChat selected, RemoteProject project) async {
    if (!canPin || !chats.any((chat) => chat.id == selected.id)) return;
    final startGeneration = generation;
    _pinning = true;
    errorBox.value = null;
    notifyListeners();
    try {
      final pinned = await repository.setChatPinned(
        connectorId,
        project.path,
        selected.id,
        !isPinned(selected),
      );
      if (!valid(startGeneration)) return;
      _pinned = pinned;
      _sortChats();
    } catch (failure) {
      if (valid(startGeneration)) {
        errorBox.value = failure is ChatFailure
            ? failure.message
            : ChatFailure.pinStorage.message;
      }
    } finally {
      _pinning = false;
      if (!_disposed) notifyListeners();
    }
  }

  void applyUpdatedChat(RemoteChat updated) {
    chats = [for (final item in chats) item.id == updated.id ? updated : item];
    _sortChats();
    notifyListeners();
  }

  void applyCreatedChat(RemoteChat created) {
    chats = [
      created,
      ...chats.where((item) => item.id != created.id),
    ].take(1000).toList();
    _sortChats();
    notifyListeners();
  }

  Future<void> deleteChat(
    RemoteChat selected,
    RemoteProject project, {
    required bool isCurrent,
    required bool Function() canDeleteCurrent,
    required void Function() onCurrentChatDeleted,
    // Extra validity check evaluated alongside this scope's own generation --
    // lets a delete-of-the-current-chat also be discarded when the caller
    // (the conversation) has since moved on to a different chat, even though
    // this list's own fetch/pagination generation never changed.
    bool Function()? isValid,
  }) async {
    if (!canDelete ||
        (isCurrent
            ? !canDeleteCurrent()
            : !chats.any((c) => c.id == selected.id))) {
      return;
    }
    if (!repository.chatSupports(connectorId, 'chat.delete')) {
      errorBox.value =
          'Restart OpenCode with the updated Remote plugin to delete chats.';
      notifyListeners();
      return;
    }
    await run(
      (generation) async {
        try {
          final response = await repository.chatRequest(
            connectorId,
            'chat.delete',
            {'projectId': project.id, 'sessionId': selected.id},
          );
          if (response['version'] != 1 || response['deleted'] != true) {
            throw ChatFailure.invalid;
          }
        } on ChatFailure catch (failure) {
          if (failure != ChatFailure.notFound) rethrow;
        }
        if (!valid(generation) || !(isValid?.call() ?? true)) return;
        chats.removeWhere((chat) => chat.id == selected.id);
        _pinned.remove(selected.id);
        lastDeletedChatId = selected.id;
        if (isCurrent) onCurrentChatDeleted();
        notifyListeners();
        try {
          await repository.setChatPinned(
            connectorId,
            project.path,
            selected.id,
            false,
          );
        } catch (_) {
          errorBox.value = 'Chat deleted. Its saved pin could not be cleared.';
        }
      },
      mutation: true,
      chatAction: 'chat.delete',
      onFailure: (failure) => errorBox.value = describeChatFailure(failure),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
