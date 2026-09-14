import 'dart:async';

import 'package:flutter/foundation.dart';

import 'data/chat_repository.dart';
import 'data/relay_crypto.dart';
import 'domain/mcp_models.dart';

enum McpPhase {
  loading,
  ready,
  unavailable,
  unsupported,
  offline,
  paused,
  untrusted,
}

/// Owned by Chat Details, independently of chat snapshots and mutations.
final class McpViewModel extends ChangeNotifier {
  McpViewModel(
    this.repository,
    this.connectorId,
    String projectId, {
    DateTime Function()? now,
  }) : _projectId = projectId,
       _now = now ?? DateTime.now {
    // A connector may emit its first event before acknowledging subscribe.
    _events = repository.chatEvents.listen(_event);
    _connections = repository.chatConnectionChanges.listen((_) => _reconcile());
  }

  final ChatRepository repository;
  final String connectorId;
  final DateTime Function() _now;
  late final StreamSubscription<ChatEvent> _events;
  late final StreamSubscription<void> _connections;
  String? _projectId, _subscriptionId;
  int _epoch = 0, _revision = -1, _responseRevision = -1;
  Object? _connectionGeneration;
  DateTime? _leaseExpires;
  bool _active = false, _disposed = false, _renewing = false;
  Timer? _renewal, _freshness, _lease, _retry;
  McpSnapshot? snapshot;
  McpPhase phase = McpPhase.paused;

  bool get live =>
      phase == McpPhase.ready &&
      _current(_epoch) &&
      _leaseValid &&
      (_freshness?.isActive ?? false);
  bool get supported => McpSnapshot.capabilities.every(
    (operation) => repository.chatSupports(connectorId, operation),
  );

  void setProject(String? projectId) {
    if (_disposed || _projectId == projectId) return;
    _stop();
    _projectId = projectId;
    snapshot = null;
    _reconcile();
  }

  void setActive(bool active) {
    if (_disposed || _active == active) return;
    _active = active;
    _reconcile();
  }

  void _reconcile() {
    if (_disposed) return;
    final trusted = repository.chatTrusted(connectorId);
    if (!trusted ||
        _projectId == null ||
        !_active ||
        !repository.chatOnline(connectorId) ||
        !supported) {
      _stop();
      if (!trusted || _projectId == null) snapshot = null;
      phase = !trusted
          ? McpPhase.untrusted
          : !_active
          ? McpPhase.paused
          : !repository.chatOnline(connectorId)
          ? McpPhase.offline
          : !supported
          ? McpPhase.unsupported
          : McpPhase.unavailable;
      notifyListeners();
      return;
    }
    if ((_subscriptionId != null || (_retry?.isActive ?? false)) &&
        _connectionGeneration ==
            repository.chatConnectionGeneration(connectorId)) {
      return;
    }
    _stop();
    _connectionGeneration = repository.chatConnectionGeneration(connectorId);
    _subscriptionId = requestId();
    phase = McpPhase.loading;
    _leaseFrom(_now());
    final epoch = _epoch;
    _renewal = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_current(epoch) && !_renewing) unawaited(_subscribe(epoch));
    });
    unawaited(_subscribe(epoch));
    notifyListeners();
  }

  bool _current(int epoch) =>
      !_disposed &&
      _active &&
      epoch == _epoch &&
      _subscriptionId != null &&
      repository.chatTrusted(connectorId) &&
      repository.chatOnline(connectorId) &&
      supported &&
      _connectionGeneration == repository.chatConnectionGeneration(connectorId);

  bool get _leaseValid => _leaseExpires?.isAfter(_now()) ?? false;

  void _leaseFrom(DateTime sentAt) {
    // Start conservatively at send time, not at a delayed acknowledgement.
    _leaseExpires = sentAt.add(const Duration(seconds: 60));
    _lease?.cancel();
    _lease = Timer(_leaseExpires!.difference(_now()), _recover);
  }

  void _recover() {
    _stop();
    phase = McpPhase.unavailable;
    _retry = Timer(const Duration(seconds: 30), _reconcile);
    notifyListeners();
  }

  Future<void> _subscribe(int epoch) async {
    if (!_current(epoch) || _renewing) return;
    if (!_leaseValid) {
      _recover();
      return;
    }
    final id = _subscriptionId!;
    final project = _projectId!;
    final generation = _connectionGeneration;
    final sentAt = _now();
    _renewing = true;
    try {
      final raw = await repository.chatRequest(
        connectorId,
        'project.mcp.subscribe',
        McpSnapshot.request(project, subscriptionId: id),
      );
      if (!_current(epoch)) {
        // Unsubscribe may have overtaken an in-flight subscribe on close.
        unawaited(_unsubscribe(project, id, generation));
        return;
      }
      if (!_leaseValid) {
        _recover();
        return;
      }
      final next = McpSnapshot.parse(raw, subscription: true);
      if (next.projectId != project ||
          next.subscriptionId != id ||
          next.revision! <= _responseRevision) {
        throw ChatFailure.invalid;
      }
      _responseRevision = next.revision!;
      _accept(next);
      _leaseFrom(sentAt);
      // An older response still confirms lease renewal, but cannot regress data.
      _fresh();
      notifyListeners();
    } catch (_) {
      if (_current(epoch)) {
        _recover();
      }
    } finally {
      if (epoch == _epoch) _renewing = false;
    }
  }

  void _event(ChatEvent event) {
    if (!_current(_epoch) ||
        event.connectorId != connectorId ||
        event.generation != _connectionGeneration ||
        event.operation != 'project.mcp.updated' ||
        event.requestId != _subscriptionId) {
      return;
    }
    if (!_leaseValid) {
      _recover();
      return;
    }
    try {
      final next = McpSnapshot.parse(event.body, subscription: true);
      if (next.projectId != _projectId ||
          next.subscriptionId != _subscriptionId ||
          next.revision! <= _revision) {
        return;
      }
      _accept(next);
      _fresh();
      notifyListeners();
    } on FormatException {
      _recover();
    }
  }

  void _accept(McpSnapshot next) {
    if (next.revision! <= _revision) return;
    _revision = next.revision!;
    snapshot = next;
  }

  void _fresh() {
    phase = snapshot?.available == true ? McpPhase.ready : McpPhase.unavailable;
    _freshness?.cancel();
    _freshness = Timer(const Duration(seconds: 45), () {
      phase = McpPhase.unavailable;
      notifyListeners();
    });
  }

  void _stop() {
    final id = _subscriptionId;
    final project = _projectId;
    final generation = _connectionGeneration;
    _epoch++;
    _subscriptionId = null;
    _revision = _responseRevision = -1;
    _renewing = false;
    _renewal?.cancel();
    _freshness?.cancel();
    _lease?.cancel();
    _retry?.cancel();
    _leaseExpires = null;
    if (id != null && project != null) {
      unawaited(_unsubscribe(project, id, generation));
    }
  }

  Future<void> _unsubscribe(
    String project,
    String id,
    Object? generation,
  ) async {
    if (!repository.chatTrusted(connectorId) ||
        !repository.chatOnline(connectorId) ||
        generation != repository.chatConnectionGeneration(connectorId) ||
        !repository.chatSupports(connectorId, 'project.mcp.unsubscribe')) {
      return;
    }
    try {
      final response = await repository.chatRequest(
        connectorId,
        'project.mcp.unsubscribe',
        McpSnapshot.request(project, subscriptionId: id),
      );
      if (response.length != 2 ||
          response['version'] is! int ||
          response['version'] != 1 ||
          response['unsubscribed'] != true) {
        throw ChatFailure.invalid;
      }
    } catch (_) {
      // Best effort only. The v1 connector lease expires after 60 seconds.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _stop();
    _disposed = true;
    snapshot = null;
    _events.cancel();
    _connections.cancel();
    super.dispose();
  }
}
