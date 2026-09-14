import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../platform/remote_api.dart';

import 'data/connections_repository.dart';
import 'domain/remote_connection.dart';
import 'domain/connection_name.dart';

final class ConnectionsViewModel extends ChangeNotifier {
  ConnectionsViewModel(this.repository) {
    if (repository case final ConnectionsPresence source) {
      _presenceSubscription = source.presence.listen((statuses) {
        if (_disposed) return;
        _latestStatuses = statuses;
        _connections = _sorted(_connections.map(_withPresence).toList());
        notifyListeners();
      });
    }
  }

  final ConnectionsRepository repository;
  List<RemoteConnection> _connections = const [];
  bool _loading = false;
  bool _disposed = false;
  bool _active = true;
  Map<String, ConnectionStatus> _latestStatuses = const {};
  int _revision = 0;
  String? _error;
  String? _deletingId;
  String? _renamingId;
  String? _selectedId;
  StreamSubscription<Map<String, ConnectionStatus>>? _presenceSubscription;

  List<RemoteConnection> get connections => _connections;
  bool get isLoading => _loading;
  String? get error => _error;
  String? get deletingId => _deletingId;
  String? get renamingId => _renamingId;
  bool get isMutating => _deletingId != null || _renamingId != null;
  String? get selectedId => _selectedId;

  // Selection is local UI state; it does not authorize or connect a device.
  void selectConnection(String connectorId) {
    if (_disposed || isMutating || _selectedId == connectorId) return;
    if (!_connections.any((connection) => connection.id == connectorId)) return;
    _selectedId = connectorId;
    notifyListeners();
  }

  Future<void> load() async {
    if (_loading || _disposed || isMutating) return;
    final revision = ++_revision;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final connections = await repository.listConnections();
      if (_disposed || revision != _revision) return;
      _connections = _sorted(connections.map(_withPresence).toList());
      if (!_connections.any((connection) => connection.id == _selectedId)) {
        _selectedId = null;
      }
      if (repository case final ConnectionsPresence source) {
        source.setActive(_active);
      }
    } catch (error) {
      if (_disposed || revision != _revision) return;
      _error = error is ConnectionFailure
          ? error.message
          : 'Could not load your connections. Please try again.';
    } finally {
      if (!_disposed && revision == _revision) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  void addConfirmed(RemoteConnection connection) {
    if (_disposed) return;
    // An older list response must not erase a just-confirmed connection.
    _revision++;
    _loading = false;
    _error = null;
    _connections = _sorted([
      ..._connections.where((existing) => existing.id != connection.id),
      _withPresence(connection),
    ]);
    notifyListeners();
  }

  Future<bool> deleteConnection(String connectorId) async {
    if (_disposed || isMutating) return false;
    _revision++;
    _loading = false;
    _deletingId = connectorId;
    _error = null;
    notifyListeners();
    try {
      await repository.revokeConnection(connectorId);
      if (_disposed) return false;
      _connections = List.unmodifiable(
        _connections.where((c) => c.id != connectorId),
      );
      if (_selectedId == connectorId) _selectedId = null;
      return true;
    } catch (error) {
      if (!_disposed) {
        _error = error is ApiException && error.code == 'secure_storage'
            ? 'Remote access was revoked, but local cleanup failed. Unlock your device and retry deletion.'
            : 'Could not confirm revocation. The connection has been kept; check your connection and retry deletion.';
      }
      return false;
    } finally {
      if (!_disposed) {
        _deletingId = null;
        notifyListeners();
      }
    }
  }

  List<RemoteConnection> _sorted(List<RemoteConnection> connections) {
    final sorted = [...connections];
    sorted.sort((a, b) {
      final online = (a.status == ConnectionStatus.online ? 0 : 1).compareTo(
        b.status == ConnectionStatus.online ? 0 : 1,
      );
      if (online != 0) return online;
      final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return name == 0 ? a.id.compareTo(b.id) : name;
    });
    return List.unmodifiable(sorted);
  }

  String? validateName(String? input) {
    try {
      ConnectionName.parse(input ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  Future<bool> renameConnection(String connectorId, String input) async {
    if (_disposed || isMutating) return false;
    final validation = validateName(input);
    if (validation != null) {
      _error = validation;
      notifyListeners();
      return false;
    }
    _revision++;
    _loading = false;
    _renamingId = connectorId;
    _error = null;
    notifyListeners();
    try {
      final name = await repository.renameConnection(
        connectorId,
        ConnectionName.parse(input),
      );
      if (_disposed) return false;
      _connections = _sorted(
        _connections
            .map(
              (c) => c.id != connectorId
                  ? c
                  : RemoteConnection(
                      id: c.id,
                      name: name,
                      status: c.status,
                      lastSeen: c.lastSeen,
                    ),
            )
            .toList(),
      );
      return true;
    } catch (_) {
      if (!_disposed) {
        _error =
            'Could not confirm the new name. Refresh to check it or try again.';
      }
      return false;
    } finally {
      if (!_disposed) {
        _renamingId = null;
        notifyListeners();
      }
    }
  }

  RemoteConnection _withPresence(RemoteConnection connection) {
    if (repository is! ConnectionsPresence ||
        connection.status == ConnectionStatus.verificationRequired ||
        connection.status == ConnectionStatus.identityChanged) {
      return connection;
    }
    return RemoteConnection(
      id: connection.id,
      name: connection.name,
      status: _latestStatuses[connection.id] ?? ConnectionStatus.unknown,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _presenceSubscription?.cancel();
    if (repository case final ConnectionsPresence source) source.dispose();
    super.dispose();
  }

  void setActive(bool active) {
    if (_disposed) return;
    _active = active;
    if (repository case final ConnectionsPresence source) {
      source.setActive(active);
    }
  }
}
