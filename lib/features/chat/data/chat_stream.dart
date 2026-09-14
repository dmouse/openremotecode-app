import 'dart:async';
import 'dart:convert';

import 'chat_repository.dart';
import 'relay_crypto.dart';

/// One foreground conversation lease. Events are replacements, never blindly
/// appended token deltas. Baselines and monotonically numbered updates reconcile
/// events that arrive before the subscribe response or after a reconnect.
final class ChatStream {
  ChatStream(
    this.repository,
    this.connectorId,
    this.onSnapshot,
    this.onChanged,
  );
  final ChatRepository repository;
  final String connectorId;
  final void Function(Map<String, dynamic>, bool) onSnapshot;
  final void Function() onChanged;
  StreamSubscription<ChatEvent>? _events;
  bool supported = false;
  Map<String, dynamic>? _target;
  String? _signature;
  Object? _generation;
  int _revision = -1;
  bool _pending = false, _disposed = false;
  Timer? _renew, _gap;
  final _buffer = <int, Map<String, dynamic>>{};
  bool get active => _target != null;
  bool get live => active && _revision >= 0;
  void connectionChanged() {
    final target = _target;
    if (target != null && !_current(target)) stop();
  }

  Future<void> start(Map<String, dynamic> target) async {
    supported =
        repository.chatSupports(connectorId, 'chat.stream.subscribe') &&
        repository.chatSupports(connectorId, 'chat.stream.updated');
    if (_disposed ||
        !repository.chatSupports(connectorId, 'chat.stream.subscribe') ||
        !repository.chatSupports(connectorId, 'chat.stream.updated')) {
      return;
    }
    final signature = jsonEncode(target);
    if (_signature == signature && active) return;
    stop();
    _events ??= repository.chatEvents.listen(_event);
    _signature = signature;
    _target = {...target, 'subscriptionId': requestId()};
    _generation = repository.chatConnectionGeneration(connectorId);
    await _subscribe();
  }

  bool _current(Map<String, dynamic> target) =>
      !_disposed &&
      identical(target, _target) &&
      repository.chatOnline(connectorId) &&
      repository.chatTrusted(connectorId) &&
      identical(_generation, repository.chatConnectionGeneration(connectorId));

  Future<void> _subscribe() async {
    final target = _target;
    if (target == null || _pending || !_current(target)) return;
    _pending = true;
    try {
      final response = await repository.chatRequest(
        connectorId,
        'chat.stream.subscribe',
        target,
      );
      if (!_current(target)) return;
      final revision = _validate(response);
      if (revision > _revision) {
        onSnapshot(
          response['snapshot'] as Map<String, dynamic>,
          response['reset'] == true ||
              (response['resetRevision'] as int? ?? -1) > _revision,
        );
        _revision = revision;
      }
      _buffer.removeWhere((key, _) => key <= _revision);
      _drain();
      onChanged();
      _renew?.cancel();
      _renew = Timer(
        const Duration(seconds: 25),
        () => unawaited(_subscribe()),
      );
    } catch (_) {
      if (identical(target, _target)) stop();
    } finally {
      if (identical(target, _target)) _pending = false;
    }
  }

  int _validate(Map<String, dynamic> body) {
    final target = _target!;
    final revision = body['revision'];
    if (body['version'] != 1 ||
        body['subscriptionId'] != target['subscriptionId'] ||
        body['projectId'] != target['projectId'] ||
        body['sessionId'] != target['sessionId'] ||
        body['parentSessionId'] != target['parentSessionId'] ||
        body['reset'] is! bool ||
        body['snapshot'] is! Map<String, dynamic> ||
        revision is! int ||
        revision < 0 ||
        revision > 9007199254740991 ||
        (body.containsKey('resetRevision') &&
            (body['resetRevision'] is! int ||
                body['resetRevision'] < 0 ||
                body['resetRevision'] > revision)) ||
        body.keys.any(
          (key) => ![
            'version',
            'subscriptionId',
            'projectId',
            'sessionId',
            'parentSessionId',
            'revision',
            'reset',
            'resetRevision',
            'snapshot',
          ].contains(key),
        )) {
      throw const FormatException();
    }
    return revision;
  }

  void _event(ChatEvent event) {
    final target = _target;
    if (target == null ||
        !_current(target) ||
        event.connectorId != connectorId ||
        !identical(event.generation, _generation) ||
        ![
          'chat.stream.updated',
          'chat.stream.closed',
        ].contains(event.operation) ||
        event.requestId != target['subscriptionId']) {
      return;
    }
    if (event.operation == 'chat.stream.closed') {
      if (event.body['projectId'] == target['projectId'] &&
          event.body['sessionId'] == target['sessionId']) {
        stop();
      }
      return;
    }
    try {
      final revision = _validate(event.body);
      if (revision <= _revision) return;
      if (_buffer.length >= 4) throw const FormatException();
      _buffer[revision] = event.body;
      if (_revision >= 0) _drain();
    } catch (_) {
      stop();
    }
  }

  void _drain() {
    while (_buffer.containsKey(_revision + 1)) {
      final body = _buffer.remove(_revision + 1)!;
      onSnapshot(
        body['snapshot'] as Map<String, dynamic>,
        body['reset'] == true ||
            (body['resetRevision'] as int? ?? -1) > _revision,
      );
      _revision++;
    }
    _gap?.cancel();
    if (_buffer.isNotEmpty) {
      _gap = Timer(const Duration(milliseconds: 500), stop);
    }
  }

  void stop() {
    final previous = _target;
    _target = null;
    _signature = null;
    _revision = -1;
    _pending = false;
    _buffer.clear();
    _renew?.cancel();
    _gap?.cancel();
    if (previous != null &&
        repository.chatOnline(connectorId) &&
        repository.chatTrusted(connectorId)) {
      unawaited(
        repository
            .chatRequest(connectorId, 'chat.stream.unsubscribe', {
              for (final key in [
                'projectId',
                'sessionId',
                'parentSessionId',
                'subscriptionId',
              ])
                if (previous.containsKey(key)) key: previous[key],
            })
            .catchError((_) => <String, dynamic>{}),
      );
    }
    if (previous != null && !_disposed) onChanged();
  }

  void dispose() {
    _disposed = true;
    stop();
    _events?.cancel();
  }
}
