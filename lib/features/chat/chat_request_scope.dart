import 'package:flutter/foundation.dart';

import 'data/chat_repository.dart';

/// Shared busy/action bookkeeping that keeps mutating operations serialized
/// across every [ChatRequestScope] that shares one instance -- e.g. a
/// project refresh that can reassign the selected project/chat must not run
/// concurrently with a chat rename or a message send. Generation numbers
/// (which guard a single async result against being applied once stale) stay
/// per-scope; only this busy gate is shared.
final class ChatBusyGate {
  bool loading = false;
  bool mutating = false;
  bool reading = false;
  bool loadingMoreChats = false;
  bool loadingEarlierMessages = false;
  String? chatAction;

  bool get busy => loading || mutating || reading || chatAction != null;
}

/// The general-purpose error surface, shared the same way as [ChatBusyGate]:
/// any scope's failed request can report to it, and the coordinator's facade
/// reads it regardless of which scope last wrote it. Distinct from a scope's
/// own narrow error fields (e.g. `moreChatsError`), which stay local.
final class ChatErrorBox {
  String? value;
}

/// Runs chat-repository requests behind a shared [ChatBusyGate] and a
/// per-scope generation counter, so a result that arrives after this scope's
/// context changed (a different chat opened, the connector went offline, the
/// view disposed) is discarded instead of applied.
mixin ChatRequestScope on ChangeNotifier {
  /// The gate this scope serializes against. Scopes that must exclude each
  /// other's mutations (today: projects, chats, and the open conversation,
  /// coordinated by `ChatViewModel`) share one instance.
  ChatBusyGate get busyGate;

  /// The shared general-error surface this scope reports non-domain-specific
  /// failures to, and clears at the start of each non-quiet [run].
  ChatErrorBox get errorBox;

  int _generation = 0;

  /// The generation a caller should capture before starting async work, to
  /// later check with [valid].
  int get generation => _generation;

  /// Extra scope-specific validity beyond "same generation" -- override to
  /// add conditions like "not disposed" or "still the active foreground
  /// scope". True by default.
  bool get scopeValid => true;

  /// Whether a result computed under [generation] is still applicable.
  bool valid(int generation) => generation == _generation && scopeValid;

  /// Discards any in-flight request's result without starting a new one.
  void invalidate() => _generation++;

  /// Notifies this scope's own listeners without changing any of its state --
  /// for the coordinator to call when cross-cutting state this scope reads
  /// through an injected closure (`online`, `trustLost`, `active`) changes,
  /// so a widget that listens directly to this scope (not the coordinator)
  /// still re-evaluates derived getters like `canSend` or `canSave`.
  void notifyExternalChange() => notifyListeners();

  /// A fork-uncertainty notice pending for whatever this scope currently
  /// considers "the open chat" -- reapplied to [errorBox] after *every*
  /// successful or stale-terminated [run] across every scope, matching the
  /// original single-class `_run`'s unconditional `if (_forkNotice != null)
  /// error = _forkNotice;` in its `finally` block. `null` by default; only a
  /// scope that tracks an open chat (`ConversationViewModel`, and the
  /// coordinator) needs to override it.
  String? get pendingForkNotice => null;

  /// A message pending because chat creation (for a first prompt) couldn't
  /// be confirmed -- reapplied to [errorBox] after every successful [run]
  /// across every scope, the same way [pendingForkNotice] is, matching the
  /// original single-class `_run`'s unconditional `if (_creationUncertain)
  /// error = '...';`. Checked before [pendingForkNotice], which can override
  /// it, matching the original's assignment order. `null` by default.
  String? get pendingCreationUncertainMessage => null;

  /// Runs [action] behind [busyGate], returning early if the gate or this
  /// scope is already busy. [onFailure] receives a caught error only while
  /// the generation captured at the start is still valid. [onBeforeNotify]
  /// runs on a still-valid completion (success or failure) before flags are
  /// applied to listeners -- for adjustments that must be visible in that
  /// same notification, not a later one. [onAfterSuccess] runs after that
  /// notification on a still-valid completion; [onAfterStale] runs instead
  /// when the scope went stale while a [chatAction]-tagged mutation was in
  /// flight (matching the original class's "an uncertain mutation still
  /// needs a follow-up refresh" rule).
  Future<void> run(
    Future<void> Function(int generation) action, {
    bool mutation = false,
    bool quiet = false,
    bool moreChats = false,
    bool earlierMessages = false,
    String? chatAction,
    required void Function(Object failure) onFailure,
    void Function()? onStart,
    void Function()? onBeforeNotify,
    void Function()? onAfterSuccess,
    void Function()? onAfterStale,
  }) async {
    final gate = busyGate;
    if (!scopeValid || gate.busy) return;
    final startGeneration = _generation;
    gate.chatAction = chatAction;
    gate.loadingMoreChats = moreChats;
    gate.loadingEarlierMessages = earlierMessages;
    // Clears a scope-local error field (e.g. `moreChatsError`) that the
    // shared errorBox doesn't know about -- mirrors the original class's
    // `if (moreChats) moreChatsError = null;` / `if (earlierMessages)
    // earlierMessagesError = null;`.
    onStart?.call();
    if (mutation) {
      gate.mutating = true;
    } else if (quiet) {
      gate.reading = true;
    } else {
      gate.loading = true;
    }
    if (!quiet) errorBox.value = null;
    notifyListeners();
    try {
      await action(startGeneration);
    } catch (failure) {
      if (valid(startGeneration)) onFailure(failure);
    } finally {
      if (chatAction != null) gate.chatAction = null;
      if (valid(startGeneration)) {
        gate.loading = false;
        gate.loadingMoreChats = false;
        gate.loadingEarlierMessages = false;
        gate.mutating = false;
        gate.reading = false;
        onBeforeNotify?.call();
        if (pendingCreationUncertainMessage case final message?) {
          errorBox.value = message;
        }
        if (pendingForkNotice case final notice?) errorBox.value = notice;
        notifyListeners();
        onAfterSuccess?.call();
      } else if (chatAction != null) {
        if (pendingForkNotice case final notice?) errorBox.value = notice;
        notifyListeners();
        onAfterStale?.call();
      }
    }
  }
}

String describeChatFailure(Object failure) =>
    failure is ChatFailure ? failure.message : ChatFailure.invalid.message;
