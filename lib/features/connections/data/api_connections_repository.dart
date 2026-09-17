import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../platform/remote_api.dart';
import '../../auth/auth_repository.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/data/chat_pin_store.dart';
import '../../chat/data/relay_crypto.dart';
import '../domain/pairing_review.dart';
import '../domain/remote_connection.dart';
import '../domain/connection_name.dart';
import 'connections_repository.dart';
import 'device_identity.dart';

final class ApiConnectionsRepository
    implements ConnectionsRepository, ConnectionsPresence, ChatRepository {
  ApiConnectionsRepository(this.auth)
    : scope = auth.session!.scope,
      identities = DeviceIdentityStore(auth.store, auth.session!.scope),
      pins = ChatPinStore(auth.store, auth.session!.scope);

  final AuthRepository auth;
  final String scope;
  final DeviceIdentityStore identities;
  final ChatPinStore pins;
  Map<String, dynamic>? _record;
  Future<Map<String, dynamic>>? _loadingDevice;
  Map<String, dynamic>? _pending;
  PairingReview? _pendingReview;
  final _presence = StreamController<Map<String, ConnectionStatus>>.broadcast();
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retry;
  Timer? _handshake;
  // A relay admission's lease is capped at five minutes (see ADR 0014), so
  // the connection is proactively replaced ahead of that expiry instead of
  // waiting for the server to force-close it. `_renewal` is the pending
  // renewal timer; `_renewingSocket`/`_renewingSubscription`/
  // `_renewingHandshake` track the not-yet-live replacement connection, kept
  // separate from `_socket`/`_subscription` so the current connection keeps
  // serving requests until the replacement is confirmed ready.
  Timer? _renewal;
  WebSocket? _renewingSocket;
  StreamSubscription<dynamic>? _renewingSubscription;
  Timer? _renewingHandshake;
  static const _renewalMargin = Duration(seconds: 45);
  static const _minRenewalLeadTime = Duration(seconds: 5);
  bool _active = false;
  bool _disposed = false;
  int _attempt = 0;
  int _socketGeneration = 0;
  final Map<String, ConnectionStatus> _statuses = {};
  final _chatRequests = RelayRequests();
  final _chatChanges = StreamController<void>.broadcast();
  final _chatEvents = StreamController<ChatEvent>.broadcast();
  final _capabilities = <String, Set<String>>{};
  bool _relayReady = false;
  Set<String> _inventoryTrusted = {};
  @override
  bool chatTrusted(String connectorId) =>
      !_disposed &&
      auth.session?.scope == scope &&
      _inventoryTrusted.contains(connectorId);

  @override
  bool chatSupports(String connectorId, String operation) =>
      chatTrusted(connectorId) &&
      (_capabilities[connectorId]?.contains(operation) ?? false);

  @override
  Future<Set<String>> pinnedChatIds(
    String connectorId,
    String projectPath,
  ) async {
    _checkSession();
    if (!chatTrusted(connectorId)) throw ChatFailure.denied;
    final peer = _peer(connectorId);
    final ids = await pins.read(connectorId, peer.keyId, projectPath);
    _checkSession();
    if (!chatTrusted(connectorId) || !_peer(connectorId).matches(peer)) {
      throw ChatFailure.denied;
    }
    return ids;
  }

  @override
  Future<Set<String>> setChatPinned(
    String connectorId,
    String projectPath,
    String sessionId,
    bool pinned,
  ) async {
    _checkSession();
    if (!chatTrusted(connectorId)) throw ChatFailure.denied;
    final peer = _peer(connectorId);
    final ids = await pins.set(
      connectorId,
      peer.keyId,
      projectPath,
      sessionId,
      pinned,
    );
    _checkSession();
    if (!chatTrusted(connectorId) || !_peer(connectorId).matches(peer)) {
      throw ChatFailure.denied;
    }
    return ids;
  }

  @override
  Stream<void> get chatConnectionChanges => _chatChanges.stream;
  @override
  Stream<ChatEvent> get chatEvents => _chatEvents.stream;
  @override
  Object chatConnectionGeneration(String connectorId) =>
      _chatRequests.generation(_peer(connectorId).keyId);
  @override
  bool chatOnline(String connectorId) =>
      _active &&
      !_disposed &&
      _relayReady &&
      _statuses[connectorId] == ConnectionStatus.online &&
      chatTrusted(connectorId);

  PublicIdentity _peer(String connectorId) {
    final binding = requiredMap(requiredMap(_record!, 'bindings'), connectorId);
    return PublicIdentity.parse(requiredMap(binding, 'identity'));
  }

  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async {
    _checkSession();
    if (!chatOnline(connectorId) || _socket == null) throw ChatFailure.offline;
    if (!(_capabilities[connectorId]?.contains(operation) ?? false)) {
      throw ChatFailure.unsupported;
    }
    final socket = _socket!;
    final generation = chatConnectionGeneration(connectorId);
    final peer = _peer(connectorId);
    final result = await _chatRequests.request(
      operation: operation,
      body: body,
      identity: requiredMap(_record!, 'identity'),
      peer: peer,
      send: (frame) {
        _checkSession();
        if (_socket != socket || !chatOnline(connectorId)) {
          throw ChatFailure.offline;
        }
        socket.add(frame);
      },
    );
    _checkSession();
    if (!chatOnline(connectorId) ||
        _socket != socket ||
        generation != chatConnectionGeneration(connectorId) ||
        !_peer(connectorId).matches(peer)) {
      throw ChatFailure.offline;
    }
    return result;
  }

  Future<void> _receiveChat(
    Map<String, dynamic> message,
    WebSocket socket,
  ) async {
    try {
      final id = trustedKeyIds.entries
          .where((entry) => entry.value == message['senderKeyId'])
          .firstOrNull
          ?.key;
      // A revoked peer may still have an already routed frame in flight.
      if (id == null || !chatOnline(id) || _socket != socket) return;
      final generation = chatConnectionGeneration(id);
      final peer = _peer(id);
      bool current() =>
          _socket == socket &&
          chatOnline(id) &&
          generation == chatConnectionGeneration(id) &&
          _peer(id).matches(peer);
      await _chatRequests.receive(
        message,
        requiredMap(_record!, 'identity'),
        peer,
        isCurrent: current,
        onEvent: (operation, requestId, body) {
          if (!current() || !chatSupports(id, operation)) return;
          _chatEvents.add(
            ChatEvent(
              connectorId: id,
              generation: generation,
              operation: operation,
              requestId: requestId,
              body: Map.unmodifiable(body),
            ),
          );
        },
      );
    } catch (_) {
      if (_socket == socket) await socket.close();
    }
  }

  @override
  Stream<Map<String, ConnectionStatus>> get presence => _presence.stream;

  @override
  void setActive(bool active) {
    if (_disposed || _active == active) return;
    _active = active;
    _socketGeneration++;
    _retry?.cancel();
    _handshake?.cancel();
    _cancelRenewal();
    _subscription?.cancel();
    _socket?.close();
    _socket = null;
    _relayReady = false;
    _chatRequests.disconnect();
    _capabilities.clear();
    _statuses.clear();
    _publishPresence();
    if (active) unawaited(_connectPresence(_socketGeneration));
  }

  Future<void> _connectPresence(int generation) async {
    try {
      final opened = await openPresence();
      if (!_active || _disposed || generation != _socketGeneration) {
        await opened?.socket.close();
        return;
      }
      if (opened == null) return;
      final socket = opened.socket;
      final nonce = opened.nonce;
      _socket = socket;
      _handshake = Timer(const Duration(seconds: 10), () {
        _schedulePresence(generation);
      });
      var ready = false;
      _subscription = socket.listen(
        (raw) {
          try {
            if (raw is! String || raw.length > 2 * 1024 * 1024) {
              throw const FormatException();
            }
            final message = jsonDecode(raw) as Map<String, dynamic>;
            if (message['protocolVersion'] != relayProtocolVersion) {
              throw const FormatException();
            }
            if (message['type'] == 'relay.ready') {
              if (message['keyId'] != deviceKeyId ||
                  message['role'] != 'client') {
                throw const FormatException();
              }
              ready = true;
              _relayReady = true;
              _handshake?.cancel();
              _attempt = 0;
              _statuses.addEntries(
                trustedKeyIds.keys.map(
                  (id) => MapEntry(id, ConnectionStatus.offline),
                ),
              );
              _scheduleRenewal(generation, message['authorizationExpiresAt']);
              _publishPresence();
              return;
            }
            _dispatchRelayMessage(socket, nonce, ready, message);
          } catch (_) {
            unawaited(socket.close());
          }
        },
        onError: (_) => _handleSocketClosed(generation, socket),
        onDone: () => _handleSocketClosed(generation, socket),
        cancelOnError: true,
      );
    } catch (_) {
      _schedulePresence(generation);
    }
  }

  /// Dispatches every relay message type that a live connection can receive
  /// once past its handshake -- shared between the normal connection
  /// (`_connectPresence`) and a not-yet-swapped-in renewal candidate
  /// (`_renew`) so both handle `connector.hello`/`relay.envelope`/
  /// `connector.offline` identically.
  void _dispatchRelayMessage(
    WebSocket socket,
    String nonce,
    bool ready,
    Map<String, dynamic> message,
  ) {
    if (ready && message['type'] == 'connector.hello') {
      final identity = PublicIdentity.parse(requiredMap(message, 'identity'));
      final connectorNonce = message['nonce'];
      final clientKeyId = deviceKeyId;
      if (connectorNonce is! String || clientKeyId == null) {
        throw const FormatException();
      }
      for (final entry in trustedKeyIds.entries) {
        if (entry.value == identity.keyId) {
          _statuses[entry.key] = ConnectionStatus.online;
          _chatRequests.connect(
            peerKeyId: identity.keyId,
            epoch: deriveRelayEpoch(
              connectorKeyId: identity.keyId,
              connectorNonce: connectorNonce,
              clientKeyId: clientKeyId,
              clientNonce: nonce,
            ),
          );
          final capabilities = message['capabilities'];
          if (capabilities is! List ||
              capabilities.length > 64 ||
              capabilities.any(
                (value) => value is! String || value.length > 64,
              )) {
            throw const FormatException();
          }
          _capabilities[entry.key] = capabilities.cast<String>().toSet();
        }
      }
    } else if (ready && message['type'] == 'relay.envelope') {
      unawaited(_receiveChat(message, socket));
      return;
    } else if (ready && message['type'] == 'connector.offline') {
      for (final entry in trustedKeyIds.entries) {
        if (entry.value == message['keyId']) {
          _statuses[entry.key] = ConnectionStatus.offline;
          _chatRequests.disconnect(peerKeyId: entry.value);
        }
      }
    }
    _publishPresence();
  }

  /// A connection closing (error or done) is only ever significant for
  /// whichever socket is actually live or being renewed right now. A
  /// superseded renewal candidate that failed before going live leaves the
  /// still-live connection untouched; an old connection this repository
  /// itself just replaced via a completed renewal (see [_completeRenewal])
  /// is no longer `_socket`, so its closing is expected and ignored here --
  /// it must not re-enter the reactive reconnect path and flip presence
  /// offline for what was actually a seamless renewal.
  void _handleSocketClosed(int generation, WebSocket socket) {
    if (identical(_renewingSocket, socket)) {
      _renewingHandshake?.cancel();
      _renewingHandshake = null;
      _renewingSubscription = null;
      _renewingSocket = null;
      return;
    }
    if (!identical(_socket, socket)) return;
    _schedulePresence(generation);
  }

  /// Schedules [_renew] ahead of [authorizationExpiresAt] (parsed from a
  /// `relay.ready` message) by [_renewalMargin], so the connection is
  /// replaced before the relay force-closes it at its five-minute lease
  /// (see ADR 0014). A lease shorter than [_minRenewalLeadTime] past the
  /// margin (e.g. capped by a near-expiry device credential) is left to the
  /// existing reactive reconnect path instead of racing a renewal with no
  /// useful lead time.
  void _scheduleRenewal(int generation, Object? authorizationExpiresAt) {
    _renewal?.cancel();
    _renewal = null;
    if (authorizationExpiresAt is! String) return;
    final expiresAt = DateTime.tryParse(authorizationExpiresAt);
    if (expiresAt == null) return;
    final delay = expiresAt.difference(DateTime.now()) - _renewalMargin;
    if (delay < _minRenewalLeadTime) return;
    _renewal = Timer(delay, () => unawaited(_renew(generation)));
  }

  /// Opens a replacement connection while the current one is still live,
  /// swapping over only once the replacement's own `relay.ready` confirms
  /// the server has admitted it. The relay hub replaces the old
  /// registration atomically the moment the new one registers (ADR 0014),
  /// so presence never needs to flip offline for this.
  Future<void> _renew(int generation) async {
    if (!_active || _disposed || generation != _socketGeneration || _socket == null) {
      return;
    }
    ({WebSocket socket, String nonce})? opened;
    try {
      opened = await openPresence();
    } catch (_) {
      opened = null;
    }
    if (opened == null) return;
    if (!_active || _disposed || generation != _socketGeneration || _socket == null) {
      unawaited(opened.socket.close());
      return;
    }
    final socket = opened.socket;
    final nonce = opened.nonce;
    _renewingSocket = socket;
    var ready = false;
    _renewingHandshake = Timer(const Duration(seconds: 10), () {
      _cleanupRenewalCandidate(socket);
    });
    late final StreamSubscription<dynamic> subscription;
    subscription = socket.listen(
      (raw) {
        try {
          if (raw is! String || raw.length > 2 * 1024 * 1024) {
            throw const FormatException();
          }
          final message = jsonDecode(raw) as Map<String, dynamic>;
          if (message['protocolVersion'] != relayProtocolVersion) {
            throw const FormatException();
          }
          if (!ready) {
            if (message['type'] != 'relay.ready' ||
                message['keyId'] != deviceKeyId ||
                message['role'] != 'client') {
              throw const FormatException();
            }
            ready = true;
            _renewingHandshake?.cancel();
            _renewingHandshake = null;
            _renewingSocket = null;
            _renewingSubscription = null;
            _completeRenewal(generation, socket, subscription, nonce, message);
            return;
          }
          _dispatchRelayMessage(socket, nonce, true, message);
        } catch (_) {
          _cleanupRenewalCandidate(socket);
        }
      },
      onError: (_) => _handleSocketClosed(generation, socket),
      onDone: () => _handleSocketClosed(generation, socket),
      cancelOnError: true,
    );
    _renewingSubscription = subscription;
  }

  void _cleanupRenewalCandidate(WebSocket socket) {
    if (identical(_renewingSocket, socket)) {
      _renewingHandshake?.cancel();
      _renewingHandshake = null;
      _renewingSubscription = null;
      _renewingSocket = null;
    }
    unawaited(socket.close());
  }

  /// Swaps a confirmed-ready renewal candidate in as the live connection.
  /// Deliberately does not touch `_statuses`/`_capabilities` or publish a
  /// presence update: the connection never actually went offline, so there
  /// is nothing to reset -- the hub replays each trusted connector's hello
  /// to the new connection (ADR 0014), which reconfirms them shortly after.
  void _completeRenewal(
    int generation,
    WebSocket socket,
    StreamSubscription<dynamic> subscription,
    String nonce,
    Map<String, dynamic> readyMessage,
  ) {
    if (!_active || _disposed || generation != _socketGeneration) {
      unawaited(subscription.cancel());
      unawaited(socket.close());
      return;
    }
    final previousSocket = _socket;
    final previousSubscription = _subscription;
    _socket = socket;
    _subscription = subscription;
    _relayReady = true;
    _attempt = 0;
    _scheduleRenewal(generation, readyMessage['authorizationExpiresAt']);
    unawaited(previousSubscription?.cancel());
    unawaited(previousSocket?.close());
  }

  void _cancelRenewal() {
    _renewal?.cancel();
    _renewal = null;
    _renewingHandshake?.cancel();
    _renewingHandshake = null;
    unawaited(_renewingSubscription?.cancel());
    _renewingSubscription = null;
    final socket = _renewingSocket;
    _renewingSocket = null;
    unawaited(socket?.close());
  }

  void _schedulePresence(int generation) {
    if (!_active ||
        _disposed ||
        generation != _socketGeneration ||
        (_retry?.isActive ?? false)) {
      return;
    }
    _cancelRenewal();
    _socket?.close();
    _handshake?.cancel();
    _subscription?.cancel();
    _socket = null;
    _relayReady = false;
    _chatRequests.disconnect();
    _capabilities.clear();
    _statuses.clear();
    _publishPresence();
    final delay = 1 << (_attempt++).clamp(0, 5);
    _retry = Timer(
      Duration(seconds: delay),
      () => unawaited(_connectPresence(generation)),
    );
  }

  void _publishPresence() {
    if (!_disposed) {
      _chatChanges.add(null);
      _presence.add(
        Map.unmodifiable({
          for (final id in trustedKeyIds.keys)
            id: _statuses[id] ?? ConnectionStatus.unknown,
        }),
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    setActive(false);
    _disposed = true;
    _presence.close();
    _chatChanges.close();
    _chatEvents.close();
  }

  void _checkSession() {
    if (_disposed || auth.session?.scope != scope) {
      throw ConnectionFailure.unauthorized;
    }
  }

  Future<Map<String, dynamic>> _device() async {
    _checkSession();
    if (_record case final record?) return record;
    final future = _loadingDevice ??= identities.loadOrCreate();
    try {
      final record = await future;
      _checkSession();
      return _record = record;
    } finally {
      _loadingDevice = null;
    }
  }

  @override
  Future<List<RemoteConnection>> listConnections() async {
    try {
      _checkSession();
      final response = await auth.request('/v1/connectors');
      final values = response.body['connectors'];
      if (values is! List || values.length > 1000) {
        throw const ApiException(0, 'invalid_response');
      }
      final record = await _device();
      final bindings = requiredMap(record, 'bindings');
      final connections = <RemoteConnection>[];
      final trustedIds = <String>{};
      for (final item in values) {
        if (item is! Map<String, dynamic>) {
          throw const ApiException(0, 'invalid_response');
        }
        final id = requiredString(item, 'id', max: 64);
        final identity = PublicIdentity.parse(requiredMap(item, 'identity'));
        final binding = bindings[id];
        final trusted =
            binding is Map<String, dynamic> &&
            identity.matches(
              PublicIdentity.parse(requiredMap(binding, 'identity')),
            );
        if (trusted) trustedIds.add(id);
        connections.add(
          RemoteConnection(
            id: id,
            name: requiredString(item, 'name', max: 64),
            status: trusted
                ? ConnectionStatus.unknown
                : binding == null
                ? ConnectionStatus.verificationRequired
                : ConnectionStatus.identityChanged,
          ),
        );
      }
      _checkSession();
      for (final id in _inventoryTrusted.difference(trustedIds)) {
        final keyId = trustedKeyIds[id];
        if (keyId != null) _chatRequests.disconnect(peerKeyId: keyId);
      }
      _inventoryTrusted = trustedIds;
      _publishPresence();
      return connections;
    } catch (error) {
      throw _failure(error);
    }
  }

  @override
  Future<void> revokeConnection(String connectorId) async {
    _checkSession();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(connectorId)) {
      throw const ApiException(0, 'invalid_request');
    }
    // Revoke first. A timeout is uncertain and must not pretend the connection
    // was deleted. Owner retries are idempotent on the server.
    await auth.request('/v1/connectors/$connectorId/revoke', method: 'POST');
    _checkSession();
    // Remote revocation takes effect even if local secure-store cleanup fails.
    _inventoryTrusted.remove(connectorId);
    final keyId = trustedKeyIds[connectorId];
    if (keyId != null) _chatRequests.disconnect(peerKeyId: keyId);
    _statuses.remove(connectorId);
    _publishPresence();
    final record = await _device();
    final bindings = {...requiredMap(record, 'bindings')}..remove(connectorId);
    final next = {...record, 'bindings': bindings};
    await identities.save(next);
    _checkSession();
    _record = next;
  }

  @override
  Future<String> renameConnection(String connectorId, String name) async {
    _checkSession();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(connectorId)) {
      throw const ApiException(0, 'invalid_request');
    }
    final response = await auth.request(
      '/v1/connectors/$connectorId/rename',
      method: 'POST',
      body: {'name': ConnectionName.parse(name)},
    );
    _checkSession();
    if (response.body['connectorId'] != connectorId) {
      throw const ApiException(0, 'invalid_response');
    }
    return ConnectionName.parse(requiredString(response.body, 'name', max: 64));
  }

  @override
  Future<PairingReview> reviewPairing(String code) async {
    try {
      _pending = null;
      _pendingReview = null;
      final record = await _device();
      final identity = requiredMap(record, 'identity');
      final challenge = await auth.request(
        '/v1/devices/challenge',
        method: 'POST',
        body: {},
      );
      if (!requiredDate(challenge.body, 'expiresAt').isAfter(DateTime.now())) {
        throw ConnectionFailure.expiredCode;
      }
      final proof = await compute(signDeviceChallenge, {
        'identity': identity,
        'challenge': requiredString(challenge.body, 'challenge', max: 43),
      });
      final claim = await auth.request(
        '/v1/connector-pairings/claim',
        method: 'POST',
        body: {
          'userCode': code,
          'deviceName': 'Open Remote Code Mobile',
          'identity': PublicIdentity.parse(identity).toJson(),
          'proof': proof,
        },
      );
      _checkSession();
      final transcript = requiredMap(claim.body, 'transcript');
      final pairingId = requiredString(claim.body, 'pairingId', max: 64);
      if (pairingId != transcript['pairingId'] ||
          !PublicIdentity.parse(identity).matches(
            PublicIdentity.parse(requiredMap(transcript, 'deviceIdentity')),
          )) {
        throw ConnectionFailure.identityMismatch;
      }
      requiredString(claim.body, 'deviceId', max: 64);
      final safety = await compute(pairingSafetyCode, transcript);
      final review = PairingReview(
        pairingId: pairingId,
        safetyCode: safety,
        expiresAt: requiredDate(claim.body, 'expiresAt'),
      );
      _pending = claim.body;
      _pendingReview = review;
      return review;
    } catch (error) {
      throw _failure(error);
    }
  }

  @override
  Future<RemoteConnection> confirmPairing(PairingReview review) async {
    try {
      _checkSession();
      final pending = _pending;
      if (!identical(review, _pendingReview) || pending == null) {
        throw ConnectionFailure.identityMismatch;
      }
      if (!review.expiresAt.isAfter(DateTime.now())) {
        throw ConnectionFailure.expiredCode;
      }
      final response = await auth.request(
        '/v1/connector-pairings/${Uri.encodeComponent(review.pairingId)}/confirm',
        method: 'POST',
        body: {'deviceId': pending['deviceId']},
      );
      _checkSession();
      final connectorId = requiredString(response.body, 'connectorId', max: 64);
      if (response.body['deviceId'] != pending['deviceId']) {
        throw ConnectionFailure.identityMismatch;
      }
      final credential = response.credential('device', auth.session!.server);
      final record = await _device();
      final connector = PublicIdentity.parse(
        requiredMap(requiredMap(pending, 'transcript'), 'connectorIdentity'),
      );
      final bindings = {...requiredMap(record, 'bindings')};
      final previous = bindings[connectorId];
      if (previous is Map<String, dynamic> &&
          !connector.matches(
            PublicIdentity.parse(requiredMap(previous, 'identity')),
          )) {
        throw ConnectionFailure.identityMismatch;
      }
      bindings[connectorId] = {
        'identity': connector.toJson(),
        'deviceId': pending['deviceId'],
      };
      final next = {
        ...record,
        'bindings': bindings,
        'deviceId': pending['deviceId'],
        'deviceCookie': '${credential.name}=${credential.value}',
        'deviceExpiresAt': credential.expires!.toUtc().toIso8601String(),
      };
      await identities.save(next);
      _checkSession();
      _record = next;
      _pending = null;
      _pendingReview = null;
      if (_active) {
        setActive(false);
        setActive(true);
      }
      // Confirm establishes trust. Presence is learned separately from the relay.
      final connections = await listConnections();
      final matching = connections.where(
        (connection) => connection.id == connectorId,
      );
      if (matching.isEmpty) throw const ApiException(0, 'invalid_response');
      return matching.first;
    } catch (error) {
      throw _failure(error, confirming: true);
    }
  }

  /// Renew inside the final third of the credential's 365-day life. Expressed as remaining
  /// time so it needs no issue timestamp and behaves the same for a record written before
  /// rotation existed.
  static const _deviceRenewalWindow = Duration(days: 120);
  Future<void>? _deviceMaintenance;

  /// Settles any rotation an earlier run left pending, then renews the device credential if
  /// it is close enough to expiry. Never throws and never leaves the caller without a usable
  /// credential: every failure path keeps whatever was last persisted.
  void maintainDeviceCredential() {
    _deviceMaintenance ??= _runDeviceMaintenance()
        .catchError((_) {})
        .whenComplete(() {
          _deviceMaintenance = null;
        });
  }

  Future<void> _runDeviceMaintenance() async {
    var record = await _settlePendingDeviceCredential(await _device());
    final cookie = record['deviceCookie'];
    final deviceId = record['deviceId'];
    if (cookie is! String || deviceId is! String) return;
    final expires = requiredDate(record, 'deviceExpiresAt');
    final now = DateTime.now();
    // An expired credential has to re-pair; there is nothing left to renew with.
    if (!expires.isAfter(now) ||
        expires.difference(now) > _deviceRenewalWindow) {
      return;
    }
    final rotated = await auth.request(
      '/v1/devices/self/rotate',
      method: 'POST',
      body: {'deviceId': deviceId},
      cookie: cookie,
    );
    _checkSession();
    // The replacement arrives in the body, not as a cookie, so it cannot overwrite the
    // credential still in use. It reuses the current cookie's name.
    final credential = requiredString(rotated.body, 'credential');
    final activateBy = requiredDate(rotated.body, 'activateBy');
    final pending = '${cookie.split('=').first}=$credential';
    // Durable before activation: activation retires the previous credential, so a process
    // death between the two must not leave this one unrecorded.
    record = {
      ...record,
      'pendingDeviceCookie': pending,
      'pendingActivateBy': activateBy.toUtc().toIso8601String(),
    };
    await identities.save(record);
    await _settlePendingDeviceCredential(record);
  }

  /// Resolves a credential this client recorded but may never have activated. Activation is
  /// attempted first, because a rotation committed just before the app was killed leaves the
  /// pending credential as the only working one.
  Future<Map<String, dynamic>> _settlePendingDeviceCredential(
    Map<String, dynamic> record,
  ) async {
    final pending = record['pendingDeviceCookie'];
    final deviceId = record['deviceId'];
    if (pending is! String || deviceId is! String) return record;
    try {
      final activated = await auth.request(
        '/v1/devices/self/rotate/activate',
        method: 'POST',
        body: {'deviceId': deviceId},
        cookie: pending,
      );
      _checkSession();
      final promoted = {
        ...record,
        'deviceCookie': pending,
        'deviceExpiresAt': requiredDate(
          activated.body,
          'credentialExpiresAt',
        ).toUtc().toIso8601String(),
      }..remove('pendingDeviceCookie');
      promoted.remove('pendingActivateBy');
      await identities.save(promoted);
      return promoted;
    } catch (_) {
      // A failure here is ambiguous — rejected, or never delivered — and the server may
      // still hold this credential as pending. Only its own deadline proves it worthless.
      final deadline = DateTime.tryParse(
        record['pendingActivateBy'] is String
            ? record['pendingActivateBy'] as String
            : '',
      );
      if (deadline == null || deadline.isAfter(DateTime.now())) return record;
      final dropped = {...record}..remove('pendingDeviceCookie');
      dropped.remove('pendingActivateBy');
      await identities.save(dropped);
      return dropped;
    }
  }

  /// One admitted socket carries both presence and encrypted chat envelopes.
  /// Returns the per-connection nonce alongside the socket -- rather than
  /// stashing it in shared instance state -- because a renewal opens a new
  /// connection while the current one is still live, so two nonces can be
  /// in play at once (see [_renew]).
  Future<({WebSocket socket, String nonce})?> openPresence() async {
    final record = await _device();
    if (record['deviceCookie'] == null || record['deviceId'] == null) {
      return null;
    }
    if (!requiredDate(record, 'deviceExpiresAt').isAfter(DateTime.now())) {
      return null;
    }
    final response = await auth.request(
      '/v1/relay/tickets',
      method: 'POST',
      body: {'deviceId': record['deviceId']},
      cookie: requiredString(record, 'deviceCookie', max: 600),
    );
    _checkSession();
    // Renewal runs only after admission has succeeded. Presenting the current credential
    // cancels a pending rotation, so rotating before the ticket would cancel itself on
    // every attempt and the credential would silently reach expiry.
    maintainDeviceCredential();
    final path = requiredString(response.body, 'webSocketUrl');
    if (!path.startsWith('/') ||
        path.startsWith('//') ||
        path.contains('?') ||
        path.contains('#') ||
        path.contains('\\')) {
      throw const ApiException(0, 'invalid_response');
    }
    final server = auth.session!.server.uri;
    final uri = server.replace(
      scheme: server.scheme == 'https' ? 'wss' : 'ws',
      path: path,
    );
    final ticket = requiredString(response.body, 'ticket');
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(ticket)) {
      throw const ApiException(0, 'invalid_response');
    }
    final client = NoRedirectHttpClient();
    try {
      final socket = await WebSocket.connect(
        uri.toString(),
        protocols: ['opencode-remote.v1', 'ticket.$ticket'],
        customClient: client,
        maxPayloadLength: 2 * 1024 * 1024,
        compression: CompressionOptions.compressionOff,
      ).timeout(const Duration(seconds: 10));
      client.close();
      if (_disposed || auth.session?.scope != scope) {
        await socket.close();
        return null;
      }
      socket.pingInterval = const Duration(seconds: 25);
      // A nonce per connection; with the connector's it derives this epoch.
      final nonce = relayNonce();
      socket.add(
        jsonEncode({
          'protocolVersion': relayProtocolVersion,
          'type': 'client.hello',
          'identity': PublicIdentity.parse(requiredMap(record, 'identity'))
              .toJson(),
          'nonce': nonce,
        }),
      );
      return (socket: socket, nonce: nonce);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  Map<String, String> get trustedKeyIds {
    final bindings = _record?['bindings'];
    if (bindings is! Map<String, dynamic>) return {};
    return bindings.map(
      (id, raw) => MapEntry(
        id,
        PublicIdentity.parse(
          requiredMap(raw as Map<String, dynamic>, 'identity'),
        ).keyId,
      ),
    );
  }

  String? get deviceKeyId => _record == null
      ? null
      : PublicIdentity.parse(requiredMap(_record!, 'identity')).keyId;

  Object _failure(Object error, {bool confirming = false}) {
    if (error is ConnectionFailure) return error;
    if (error is ApiException) {
      if (error.status == 401) return ConnectionFailure.unauthorized;
      if (error.status == 410) return ConnectionFailure.expiredCode;
      if (error.status == 409) {
        return confirming
            ? ConnectionFailure.connectorNotReady
            : ConnectionFailure.usedCode;
      }
      if (error.status == 400 || error.status == 404) {
        return ConnectionFailure.invalidCode;
      }
      if (error.code == 'secure_storage') {
        return ConnectionFailure.secureStorage;
      }
      if (error.code == 'network' || error.code == 'timeout') {
        return ConnectionFailure.network;
      }
    }
    return error;
  }
}
