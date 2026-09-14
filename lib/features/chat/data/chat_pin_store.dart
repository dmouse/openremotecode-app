import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../platform/secure_store.dart';
import 'chat_repository.dart';

/// Device-local preferences: only opaque session IDs, never conversation text.
final class ChatPinStore {
  ChatPinStore(this.store, this.scope);
  final SecureStore store;
  final String scope;
  Future<void> _writing = Future.value();
  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  String _key(String connectorId, String peerKey, String projectPath) =>
      'chat_pins_v1_${sha256.convert(utf8.encode(jsonEncode([scope, connectorId, peerKey, projectPath])))}';

  Future<Set<String>> read(
    String connectorId,
    String peerKey,
    String projectPath,
  ) async {
    await _writing;
    return _read(_key(connectorId, peerKey, projectPath));
  }

  Future<Set<String>> _read(String key) async {
    try {
      final raw = await store.read(key);
      if (raw == null) return {};
      if (raw.length > 4000) throw const FormatException();
      final value = jsonDecode(raw) as Map<String, dynamic>;
      final ids = value['ids'];
      if (value.length != 2 ||
          value['version'] != 1 ||
          ids is! List ||
          ids.length > 20 ||
          ids.any((id) => id is! String || !_id.hasMatch(id))) {
        throw const FormatException();
      }
      return ids.cast<String>().toSet();
    } catch (_) {
      throw ChatFailure.pinStorage;
    }
  }

  Future<Set<String>> set(
    String connectorId,
    String peerKey,
    String projectPath,
    String sessionId,
    bool pinned,
  ) {
    final key = _key(connectorId, peerKey, projectPath);
    final task = _writing.then((_) async {
      if (!_id.hasMatch(sessionId)) {
        throw ChatFailure.invalid;
      }
      final ids = await _read(key);
      if (pinned) {
        ids.add(sessionId);
        if (ids.length > 20) throw ChatFailure.pinLimit;
      } else {
        ids.remove(sessionId);
      }
      try {
        if (ids.isEmpty) {
          await store.delete(key);
        } else {
          await store.write(
            key,
            jsonEncode({'version': 1, 'ids': ids.toList()}),
          );
        }
      } catch (_) {
        throw ChatFailure.pinStorage;
      }
      return ids;
    });
    _writing = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }
}
