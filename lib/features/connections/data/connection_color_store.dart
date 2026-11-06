import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../platform/secure_store.dart';
import '../domain/connection_color.dart';

final class ConnectionColorStore {
  ConnectionColorStore(this.store, this.scope);
  final SecureStore store;
  final String scope;
  String _key(String id) =>
      'connection_color_v1_${sha256.convert(utf8.encode(jsonEncode([scope, id])))}';
  Future<ConnectionColor> read(String id) async {
    final value = await store.read(_key(id));
    return ConnectionColor.values.where((c) => c.name == value).firstOrNull ??
        ConnectionColor.lime;
  }

  Future<void> write(String id, ConnectionColor color) =>
      color == ConnectionColor.lime
      ? store.delete(_key(id))
      : store.write(_key(id), color.name);
}
