import 'dart:async';
import 'dart:convert';

import '../../../platform/remote_api.dart';

import '../domain/chat_models.dart';
import 'chat_repository.dart';
import 'relay_crypto.dart';

/// One metadata-only lease for all approved folders on a connector. A gap or
/// reconnect requests an authoritative list, never conversation message content.
final class ChatListStream {
  ChatListStream(
    this.repository,
    this.connectorId,
    this.onChange,
    this.reconcile,
  );
  final ChatRepository repository;
  final String connectorId;
  final void Function(String, RemoteChat) onChange;
  final void Function() reconcile;
  StreamSubscription<ChatEvent>? _events;
  Map<String, dynamic>? _target;
  Object? _generation;
  String? _signature;
  int _revision = -1;
  bool _disposed = false, _pending = false;
  Timer? _renew, _expiry, _retry;

  void start(List<String> projects) {
    if (_disposed ||
        projects.isEmpty ||
        !repository.chatSupports(connectorId, 'chat.list.subscribe') ||
        !repository.chatSupports(connectorId, 'chat.list.updated')) {
      return;
    }
    projects.sort();
    final signature = jsonEncode(projects);
    if (_signature == signature && _target != null && _current(_target!)) {
      return;
    }
    stop();
    _events ??= repository.chatEvents.listen(_event);
    _signature = signature;
    _generation = repository.chatConnectionGeneration(connectorId);
    _target = {
      'version': 1,
      'subscriptionId': requestId(),
      'projectIds': projects,
    };
    unawaited(_subscribe());
  }

  bool _current(Map<String, dynamic> target) =>
      !_disposed &&
      identical(target, _target) &&
      repository.chatOnline(connectorId) &&
      repository.chatTrusted(connectorId) &&
      identical(_generation, repository.chatConnectionGeneration(connectorId));

  bool _matches(Map<String, dynamic> body) =>
      body['version'] == 1 &&
      body['subscriptionId'] == _target?['subscriptionId'] &&
      jsonEncode(body['projectIds']) == _signature;

  Future<void> _subscribe() async {
    final target = _target;
    if (target == null || _pending || !_current(target)) return;
    _pending = true;
    final initial = _revision < 0;
    final requested = _revision;
    try {
      final body = await repository
          .chatRequest(connectorId, 'chat.list.subscribe', target)
          .timeout(const Duration(seconds: 20));
      if (!_current(target)) return;
      final revision = body['revision'];
      if (!_matches(body) ||
          revision is! int ||
          revision < 0 ||
          revision > 9007199254740991 ||
          revision < requested) {
        throw const FormatException();
      }
      if (initial || revision > _revision) reconcile();
      if (revision > _revision) _revision = revision;
      _renew?.cancel();
      _renew = Timer(
        const Duration(seconds: 25),
        () => unawaited(_subscribe()),
      );
      _expiry?.cancel();
      _expiry = Timer(const Duration(seconds: 50), _lost);
    } catch (_) {
      if (identical(target, _target)) _lost();
    } finally {
      if (identical(target, _target)) _pending = false;
    }
  }

  void _event(ChatEvent event) {
    final target = _target;
    if (target == null ||
        !_current(target) ||
        event.connectorId != connectorId ||
        !identical(event.generation, _generation) ||
        event.requestId != target['subscriptionId'] ||
        !['chat.list.updated', 'chat.list.closed'].contains(event.operation)) {
      return;
    }
    try {
      final body = event.body;
      if (!_matches(body)) throw const FormatException();
      if (event.operation == 'chat.list.closed') {
        _lost();
        return;
      }
      final revision = body['revision'];
      if (revision is! int ||
          revision < 0 ||
          revision > 9007199254740991 ||
          body['reset'] is! bool ||
          body['changes'] is! List ||
          (body['changes'] as List).length > 50 ||
          body.keys.any(
            (key) => ![
              'version',
              'subscriptionId',
              'projectIds',
              'revision',
              'reset',
              'changes',
            ].contains(key),
          )) {
        throw const FormatException();
      }
      if (revision <= _revision) return;
      final changes = <(String, RemoteChat)>[];
      for (final raw in body['changes'] as List) {
        if (raw is! Map<String, dynamic> ||
            !((target['projectIds'] as List).contains(raw['projectId']))) {
          throw const FormatException();
        }
        final chat = RemoteChat.parse(requiredMap(raw, 'chat'));
        if (chat.parentId != null) throw const FormatException();
        changes.add((raw['projectId'] as String, chat));
      }
      if (body['reset'] == true || revision != _revision + 1) reconcile();
      _revision = revision;
      for (final change in changes) {
        onChange(change.$1, change.$2);
      }
    } catch (_) {
      _lost();
    }
  }

  void _lost() {
    stop();
    if (!_disposed) _retry = Timer(const Duration(seconds: 3), reconcile);
  }

  void stop() {
    final target = _target;
    _target = null;
    _signature = null;
    _revision = -1;
    _pending = false;
    _renew?.cancel();
    _expiry?.cancel();
    _retry?.cancel();
    if (target != null &&
        repository.chatOnline(connectorId) &&
        repository.chatTrusted(connectorId) &&
        identical(
          _generation,
          repository.chatConnectionGeneration(connectorId),
        )) {
      unawaited(
        repository
            .chatRequest(connectorId, 'chat.list.unsubscribe', target)
            .catchError((_) => <String, dynamic>{}),
      );
    }
  }

  void dispose() {
    _disposed = true;
    stop();
    unawaited(_events?.cancel());
  }
}
