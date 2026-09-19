import 'dart:async';
import 'dart:convert';

import '../../connections/data/device_identity.dart';
import 'relay_crypto.dart';

abstract interface class ChatRepository {
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  );
  Stream<void> get chatConnectionChanges;
  Stream<ChatEvent> get chatEvents;

  /// Opaque pinned-peer lifetime; a full socket close invalidates every peer.
  Object chatConnectionGeneration(String connectorId);
  bool chatOnline(String connectorId);
  bool chatTrusted(String connectorId);
  bool chatSupports(String connectorId, String operation);
  Future<Set<String>> pinnedChatIds(String connectorId, String projectPath);
  Future<Set<String>> setChatPinned(
    String connectorId,
    String projectPath,
    String sessionId,
    bool pinned,
  );
}

/// Published only after peer authentication and current-connection checks.
final class ChatEvent {
  const ChatEvent({
    required this.connectorId,
    required this.generation,
    required this.operation,
    required this.requestId,
    required this.body,
  });
  final String connectorId, operation, requestId;
  final Object generation;
  final Map<String, dynamic> body;
}

enum ChatFailure implements Exception {
  offline,
  unsupported,
  unavailable,
  denied,
  expired,
  busy,
  uncertain,
  notFound,
  chatBusy,
  pinStorage,
  pinLimit,
  invalid;

  String get message => switch (this) {
    offline =>
      'OpenCode is offline or reconnecting. Keep it running on your computer.',
    unsupported => 'Restart OpenCode with the updated Remote plugin to open projects and chats.',
    unavailable => 'OpenCode could not complete this request. Try again.',
    denied => 'This project or chat is not authorized on this connection.',
    expired => 'This project view expired. Go back and open the project again.',
    busy => 'Another request is still running. Please wait.',
    uncertain => 'The result could not be confirmed. Refresh before trying again to avoid duplicate work.',
    invalid => 'The connector returned an invalid response.',
    notFound => 'This chat no longer exists in OpenCode.',
    chatBusy => 'Stop the response before changing this chat.',
    pinStorage => 'Chat pins could not be saved or loaded. Please try again.',
    pinLimit => 'You can pin up to 20 chats per project. Unpin a chat first.',
  };
}

/// Renders a connector.credential.updated body, or null when it is not a shape this build
/// understands. Defensive because the body crosses the relay boundary.
String? credentialNoticeMessage(Map<String, dynamic> body) {
  if (body['version'] != 1) return null;
  return switch (body['outcome']) {
    'renewed' => 'Remote access was renewed automatically.',
    'failed' => 'Remote access could not be renewed. OpenCode will try again.',
    _ => null,
  };
}

final class RelayRequests {
  RelayRequests({this.crypto = const NativeRelayCrypto()});
  final RelayCrypto crypto;
  final _pending = <String, _Pending>{};
  final _epochs = <String, _Epoch>{};
  final _generations = <String, Object>{};
  int _opening = 0;
  Object generation(String peerKeyId) =>
      _generations.putIfAbsent(peerKeyId, Object.new);

  /// Binds a peer to the epoch its hello just established. Sequence numbers and
  /// the replay window restart with it, so envelopes from any earlier
  /// connection no longer decrypt and cannot be replayed into this one.
  void connect({required String peerKeyId, required String epoch}) {
    _epochs[peerKeyId] = _Epoch(epoch);
  }

  Future<Map<String, dynamic>> request({
    required String operation,
    required Map<String, dynamic> body,
    required Map<String, dynamic> identity,
    required PublicIdentity peer,
    required void Function(String) send,
  }) async {
    if (_pending.length >= 4) throw ChatFailure.busy;
    final epoch = _epochs[peer.keyId];
    if (epoch == null) throw ChatFailure.unavailable;
    final id = requestId();
    final entry = _Pending(peer.keyId, operation);
    _pending[id] = entry;
    final generation = this.generation(peer.keyId);
    // Attach the error handler before native crypto can yield and disconnect.
    final response = entry.completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw _mutation(operation)
          ? ChatFailure.uncertain
          : ChatFailure.unavailable,
    );
    unawaited(() async {
      try {
        final envelope = await crypto.seal(
          identity,
          peer,
          {
            'protocolVersion': relayProtocolVersion,
            'kind': 'request',
            'requestId': id,
            'sentAt': DateTime.now().millisecondsSinceEpoch,
            'operation': operation,
            'body': {'version': 1, ...body},
          },
          epoch.epoch,
          epoch.sequence++,
        );
        if (generation != _generations[peer.keyId] ||
            entry.completer.isCompleted ||
            _pending[id] != entry) {
          return;
        }
        send(jsonEncode(envelope));
      } catch (_) {
        if (!entry.completer.isCompleted) {
          entry.completer.completeError(ChatFailure.unavailable);
        }
      }
    }());
    try {
      return await response;
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> receive(
    Map<String, dynamic> envelope,
    Map<String, dynamic> own,
    PublicIdentity peer, {
    bool Function()? isCurrent,
    void Function(
      String operation,
      String requestId,
      Map<String, dynamic> body,
    )?
    onEvent,
  }) async {
    if (_opening >= 4) throw ChatFailure.busy;
    final epoch = _epochs[peer.keyId];
    if (epoch == null) return;
    validateEnvelope(envelope, own['keyId'] as String, peer.keyId, epoch.epoch);
    final sequence = envelope['sequence'];
    // Consumed before decrypting, so a replay is refused whatever it contains.
    if (sequence is! int || !epoch.window.accept(sequence)) return;
    _opening++;
    final generation = this.generation(peer.keyId);
    try {
      final payload = await crypto.open(own, peer, envelope, epoch.epoch);
      if (generation != _generations[peer.keyId] ||
          isCurrent?.call() == false ||
          _epochs[peer.keyId] != epoch) {
        return;
      }
      // Events never resolve requests, even when their correlation IDs collide.
      if (payload['kind'] == 'event') {
        if (connectorEventOperations.contains(payload['operation'])) {
          onEvent?.call(
            payload['operation'] as String,
            payload['requestId'] as String,
            payload['body'] as Map<String, dynamic>,
          );
        }
        return;
      }
      if (payload['kind'] != 'response') return;
      final entry = _pending[payload['requestId']];
      if (entry == null ||
          entry.peer != peer.keyId ||
          entry.completer.isCompleted) {
        return;
      }
      final body = payload['body'] as Map<String, dynamic>;
      if (payload['operation'] == 'protocol.error') {
        entry.completer.completeError(switch (body['code']) {
          'unsupported_operation' => ChatFailure.unsupported,
          'access_denied' => ChatFailure.denied,
          'context_expired' => ChatFailure.expired,
          'uncertain_outcome' => ChatFailure.uncertain,
          'chat_not_found' => ChatFailure.notFound,
          'chat_busy' => ChatFailure.chatBusy,
          _ => ChatFailure.unavailable,
        });
      } else if (payload['operation'] == entry.operation &&
          body['version'] == 1) {
        entry.completer.complete(body);
      } else {
        entry.completer.completeError(ChatFailure.invalid);
      }
    } catch (_) {
      if (generation != _generations[peer.keyId] ||
          isCurrent?.call() == false) {
        return;
      }
      rethrow;
    } finally {
      _opening--;
    }
  }

  void disconnect({String? peerKeyId}) {
    // Retire only this peer's lifetime unless the entire socket is closing.
    if (peerKeyId == null) {
      _generations.clear();
      _epochs.clear();
    } else {
      _generations.remove(peerKeyId);
      _epochs.remove(peerKeyId);
    }
    _pending.removeWhere((_, entry) {
      if (peerKeyId != null && entry.peer != peerKeyId) return false;
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(
          _mutation(entry.operation)
              ? ChatFailure.uncertain
              : ChatFailure.offline,
        );
      }
      return true;
    });
    // Keep the bounded replay window across reconnects.
  }

  static bool _mutation(String operation) => [
    'chat.create',
    'chat.prompt',
    'chat.abort',
    'chat.delete',
    'chat.rename',
    'chat.fork',
  ].contains(operation);
}

final class _Epoch {
  _Epoch(this.epoch);
  final String epoch;
  final window = ReplayWindow();
  int sequence = 0;
}

final class _Pending {
  _Pending(this.peer, this.operation);
  final String peer;
  final String operation;
  final completer = Completer<Map<String, dynamic>>();
}
