import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/auth/auth_repository.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/data/relay_crypto.dart';
import 'package:openremotecode/features/chat/domain/mcp_models.dart';
import 'package:openremotecode/features/chat/mcp_view_model.dart';
import 'package:openremotecode/features/connections/data/api_connections_repository.dart';
import 'package:openremotecode/features/connections/data/device_identity.dart';
import 'package:openremotecode/features/connections/domain/remote_connection.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/platform/remote_api.dart';

import 'support/auth_fakes.dart';
import 'support/mcp_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = overrides);
  });

  for (final transition in [
    'four offline flaps',
    'inventory trust drop',
    'revocation',
    'revocation storage failure',
  ]) {
    test(
      'healthy MCP lifetime and pending request survive unrelated $transition',
      () async {
        final h = await _Harness.open(twoConnectors: true);
        final repo = h.repository;
        final model = McpViewModel(repo, 'connector', mcpProject)
          ..setActive(true);
        addTearDown(model.dispose);
        await _until(() => model.live);
        // Fence initial subscription acknowledgement before delaying more decrypts.
        await repo.chatRequest('connector', 'chat.snapshot', {});
        final id = model.snapshot!.subscriptionId!;
        final generation = repo.chatConnectionGeneration('connector');
        final events = <ChatEvent>[];
        final listener = repo.chatEvents.listen(events.add);
        addTearDown(listener.cancel);
        h.holdChatResponses = true;
        var healthyCompleted = false;
        final healthy = repo.chatRequest('connector', 'chat.snapshot', {}).then(
          (body) {
            healthyCompleted = true;
            return body;
          },
        );
        final affected = expectLater(
          repo.chatRequest('other', 'chat.snapshot', {}),
          throwsA(ChatFailure.offline),
        );
        await _until(() => h.held.length == 2);
        final gate = Completer<void>();
        h.gate = gate;
        h.sendEvent(id: id, revision: 5);
        h.sendEvent(from: h.otherPeer);
        await _until(() => h.delayedOpens == 2);
        if (transition == 'four offline flaps') {
          for (var i = 0; i < 4; i++) {
            h.sockets.last.add(
              jsonEncode({
                'protocolVersion': 2,
                'type': 'connector.offline',
                'keyId': h.otherPeer!['keyId'],
              }),
            );
            await _until(() => !repo.chatOnline('other'));
            expect(model.live, isTrue);
            h.hello(h.api.otherIdentity!);
            await _until(() => repo.chatOnline('other'));
            expect(
              repo.chatConnectionGeneration('connector'),
              same(generation),
            );
          }
        } else if (transition == 'inventory trust drop') {
          h.api.otherVisible = false;
          await repo.listConnections();
        } else {
          h.store.failWrite = transition == 'revocation storage failure';
          if (h.store.failWrite) {
            await expectLater(
              repo.revokeConnection('other'),
              throwsA(isA<ApiException>()),
            );
            expect(repo.chatTrusted('other'), isFalse);
          } else {
            await repo.revokeConnection('other');
          }
        }
        await affected;
        expect(healthyCompleted, isFalse);
        expect(repo.chatConnectionGeneration('connector'), same(generation));
        expect(model.live, isTrue);
        gate.complete();
        await _until(() => events.isNotEmpty);
        h.gate = null;
        if (transition.startsWith('revocation')) h.sendEvent(from: h.otherPeer);
        final held = h.held.singleWhere(
          (request) => request.$1 == h.peer['keyId'],
        );
        h.send({
          ...held.$2,
          'kind': 'response',
          'body': {'version': 1},
        });
        expect(await healthy, {'version': 1});
        expect(events.map((event) => event.connectorId), ['connector']);
        expect(model.snapshot?.subscriptionId, id);
        expect(model.snapshot?.revision, 5);
        expect(h.slots[h.peer['keyId']], {id});
        expect(
          h.operations.where((op) => op == 'project.mcp.subscribe'),
          hasLength(1),
        );
        model.dispose();
        await _until(() => h.slots[h.peer['keyId']]!.isEmpty);
      },
    );
  }

  test('API socket authenticates event connector/generation and feeds independent MCP subscription', () async {
    final harness = await _Harness.open();
    final repo = harness.repository;
    final received = <ChatEvent>[];
    final events = repo.chatEvents.listen(received.add);
    addTearDown(events.cancel);
    final model = McpViewModel(repo, 'connector', mcpProject)..setActive(true);
    addTearDown(model.dispose);
    await _until(() => model.live);
    expect(received.single.connectorId, 'connector');
    expect(
      received.single.generation,
      repo.chatConnectionGeneration('connector'),
    );
    expect(received.single.requestId, model.snapshot?.subscriptionId);
    expect(model.snapshot?.revision, 2);
    expect(harness.operations, ['project.mcp.subscribe']);
    // An authenticated protocol error is isolated from a normal chat response.
    await expectLater(
      repo.chatRequest(
        'connector',
        'project.mcp.snapshot',
        McpSnapshot.request(mcpProject),
      ),
      throwsA(ChatFailure.unavailable),
    );
    expect(await repo.chatRequest('connector', 'chat.snapshot', {}), {
      'version': 1,
    });
    expect(model.live, isTrue);
    final generation = repo.chatConnectionGeneration('connector');
    repo.setActive(false);
    await _until(() => !model.live);
    repo.setActive(true);
    await _until(() => repo.chatOnline('connector') && model.live);
    expect(repo.chatConnectionGeneration('connector'), isNot(same(generation)));
    expect(
      received.last.generation,
      repo.chatConnectionGeneration('connector'),
    );
    expect(received.last.requestId, isNot(received.first.requestId));
  });

  test(
    'proactive renewal replaces the connection ahead of its lease without a visible disconnect',
    () async {
      final harness = await _Harness.open(
        authorizationExpiresAt: DateTime.now().add(const Duration(seconds: 52)),
      );
      final repo = harness.repository;
      final statuses = <ConnectionStatus>[];
      final presence = repo.presence.listen(
        (map) => statuses.add(map['connector']!),
      );
      addTearDown(presence.cancel);
      final generation = repo.chatConnectionGeneration('connector');

      // The renewal timer fires ~7s ahead of the 52s lease, given a 45s
      // margin and a 5s minimum lead time below which it would not schedule.
      await _untilEventually(() => harness.sockets.length == 2);
      // A successful renewal is invisible on the repository's public API
      // (no presence change, no generation bump), so wait for its other
      // observable side effect instead: the superseded connection actually
      // being closed by the client once the replacement is confirmed ready.
      await _untilEventually(
        () => harness.sockets.first.readyState != WebSocket.open,
      );
      await _until(() => repo.chatOnline('connector'));
      expect(
        statuses.any((status) => status == ConnectionStatus.offline),
        isFalse,
        reason: 'a proactive renewal must never publish an offline transition',
      );
      // The old connection's identity keeps working post-swap.
      expect(repo.chatConnectionGeneration('connector'), same(generation));
      expect(await repo.chatRequest('connector', 'chat.snapshot', {}), {
        'version': 1,
      });
      expect(harness.operations, ['chat.snapshot']);

      // The real relay force-closes the superseded connection once the
      // replacement registers (ADR 0014) -- simulate that here.
      await harness.sockets.first.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        harness.sockets.length,
        2,
        reason:
            'the superseded connection closing must not be treated as a '
            'real disconnect and trigger another reconnect',
      );
      expect(repo.chatOnline('connector'), isTrue);
      expect(
        statuses.any((status) => status == ConnectionStatus.offline),
        isFalse,
      );
      expect(repo.chatConnectionGeneration('connector'), same(generation));
    },
  );

  test(
    'an unexpected disconnect still falls back to the reactive reconnect path',
    () async {
      final harness = await _Harness.open();
      final repo = harness.repository;
      await _until(() => repo.chatOnline('connector'));
      expect(harness.sockets.length, 1);

      await harness.sockets.single.close();
      await _until(() => !repo.chatOnline('connector'));
      await _until(() => harness.sockets.length == 2);
      await _until(() => repo.chatOnline('connector'));
      expect(await repo.chatRequest('connector', 'chat.snapshot', {}), {
        'version': 1,
      });
    },
  );

  for (final transition in [
    'revocation-storage-failure',
    'key-change',
    'background',
    'logout',
  ]) {
    test('API drops native decrypt completing after $transition', () async {
      final harness = await _Harness.open();
      final repo = harness.repository;
      final events = <ChatEvent>[];
      final listener = repo.chatEvents.listen(events.add);
      addTearDown(listener.cancel);
      final opening = Completer<void>();
      final gate = Completer<void>();
      harness.opening = opening;
      harness.gate = gate;
      harness.sendEvent();
      await opening.future.timeout(const Duration(seconds: 5));
      if (transition == 'revocation-storage-failure') {
        harness.store.failWrite = true;
        await expectLater(
          repo.revokeConnection('connector'),
          throwsA(
            isA<ApiException>().having((e) => e.code, 'code', 'secure_storage'),
          ),
        );
        expect(repo.chatTrusted('connector'), isFalse);
      } else if (transition == 'key-change') {
        harness.api.identity = PublicIdentity.parse(harness.own).toJson();
        await repo.listConnections();
        expect(repo.chatTrusted('connector'), isFalse);
      } else if (transition == 'logout') {
        await harness.auth.logout();
        expect(repo.chatTrusted('connector'), isFalse);
      } else {
        repo.setActive(false);
      }
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(events, isEmpty);
      expect(repo.chatOnline('connector'), isFalse);
    });
  }
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 500; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Local relay test did not reach the expected state');
}

/// Like [_until], but with a longer budget for a renewal timer that must
/// clear `ApiConnectionsRepository`'s minimum renewal lead time to be
/// scheduled at all.
Future<void> _untilEventually(bool Function() ready) async {
  for (var i = 0; i < 2000; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Local relay test did not reach the expected state');
}

/// Real loopback WebSocket and production API repository; only auth HTTP,
/// secure storage and native HPKE are test adapters. No native app is launched.
final class _Harness {
  late final HttpServer server;
  late final AuthRepository auth;
  late final ApiConnectionsRepository repository;
  late final _Api api;
  final store = MemorySecureStore();
  late Map<String, dynamic> own, peer;
  Map<String, dynamic>? otherPeer;
  final sockets = <WebSocket>[];
  final operations = <String>[];
  final slots = <String, Set<String>>{};
  final revisions = <String, int>{};
  final held = <(String, Map<String, dynamic>)>[];
  bool holdChatResponses = false;
  int delayedOpens = 0;
  Completer<void>? opening, gate;
  bool closing = false;
  final connectorNonce = 'n' * 22;
  String? clientNonce;
  int sequence = 0;
  DateTime? authorizationExpiresAt;

  /// The same epoch the repository derives from the two hello nonces.
  String epochFor(Map<String, dynamic> connector) => deriveRelayEpoch(
    connectorKeyId: connector['keyId'] as String,
    connectorNonce: connectorNonce,
    clientKeyId: own['keyId'] as String,
    clientNonce: clientNonce!,
  );

  static Future<_Harness> open({
    bool twoConnectors = false,
    DateTime? authorizationExpiresAt,
  }) async {
    final h = _Harness();
    h.authorizationExpiresAt = authorizationExpiresAt;
    h.server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    h.peer = generateDeviceKey(null);
    if (twoConnectors) h.otherPeer = generateDeviceKey(null);
    h.api = _Api(
      PublicIdentity.parse(h.peer).toJson(),
      otherIdentity: h.otherPeer == null
          ? null
          : PublicIdentity.parse(h.otherPeer!).toJson(),
    );
    h.auth = AuthRepository(api: h.api, store: h.store);
    await h.auth.login(
      ServerEndpoint.parse(
        'http://127.0.0.1:${h.server.port}',
        allowLoopbackHttp: true,
      ),
      'person@example.test',
      'test-password',
    );
    final identities = DeviceIdentityStore(h.store, h.auth.session!.scope);
    final record = await identities.loadOrCreate();
    h.own = Map.from(record['identity'] as Map);
    await identities.save({
      ...record,
      'deviceId': 'device',
      'deviceCookie': 'device=test-only',
      'deviceExpiresAt': DateTime.now()
          .add(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
      'bindings': {
        'connector': {'identity': h.api.identity, 'deviceId': 'device'},
        if (twoConnectors)
          'other': {'identity': h.api.otherIdentity, 'deviceId': 'device'},
      },
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(NativeRelayCrypto.channel, (call) async {
      final args = call.arguments as Map;
      if (call.method == 'seal') {
        // Test-only codec stands in for native HPKE. Never used by application.
        return {
          'enc': Uint8List.fromList(List.filled(65, 1)),
          'ciphertext': args['content'],
        };
      }
      if (h.gate != null) {
        h.delayedOpens++;
        if (h.opening?.isCompleted == false) h.opening!.complete();
        await h.gate!.future;
      }
      return args['content'];
    });
    h.server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (_) => 'opencode-remote.v1',
      );
      h.sockets.add(socket);
      socket.listen((raw) {
        if (h.closing) return;
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (frame['type'] == 'client.hello') {
          h.clientNonce = frame['nonce'] as String;
          socket.add(
            jsonEncode({
              'protocolVersion': 2,
              'type': 'relay.ready',
              'role': 'client',
              'keyId': h.own['keyId'],
              if (h.authorizationExpiresAt case final expiresAt?)
                'authorizationExpiresAt': expiresAt.toUtc().toIso8601String(),
            }),
          );
          h.hello(h.api.identity);
          if (twoConnectors) h.hello(h.api.otherIdentity!);
          return;
        }
        final payload = jsonDecode(
          utf8.decode(decodeUrl(frame['ciphertext'] as String)),
        ) as Map<String, dynamic>;
        final operation = payload['operation'] as String;
        h.operations.add(operation);
        final from = frame['recipientKeyId'] == h.peer['keyId']
            ? h.peer
            : h.otherPeer!;
        if (operation == 'chat.snapshot' && h.holdChatResponses) {
          h.held.add((from['keyId'] as String, payload));
          return;
        }
        final body = payload['body'] as Map;
        var revision = 1;
        final slots = h.slots.putIfAbsent(
          from['keyId'] as String,
          () => <String>{},
        );
        if (operation == 'project.mcp.subscribe') {
          final id = body['subscriptionId'] as String;
          if (!slots.contains(id) && slots.length >= 4) {
            h.send({
              ...payload,
              'kind': 'response',
              'operation': 'protocol.error',
              'body': {'version': 1, 'code': 'context_expired'},
            }, from: from);
            return;
          }
          slots.add(id);
          revision = h.revisions.update(
            id,
            (value) => value + 2,
            ifAbsent: () => 1,
          );
          h.sendEvent(id: id, revision: revision + 1, from: from);
        } else if (operation == 'project.mcp.unsubscribe') {
          slots.remove(body['subscriptionId']);
        }
        h.send({
          ...payload,
          'kind': 'response',
          'operation': operation == 'project.mcp.snapshot'
              ? 'protocol.error'
              : operation,
          'body': switch (operation) {
            'project.mcp.subscribe' => {
              ...mcpFixture['update'] as Map,
              'subscriptionId': body['subscriptionId'],
              'revision': revision,
            },
            'project.mcp.unsubscribe' => {'version': 1, 'unsubscribed': true},
            'project.mcp.snapshot' => {'version': 1, 'code': 'unavailable'},
            _ => {'version': 1},
          },
        }, from: from);
      });
    });
    h.repository = ApiConnectionsRepository(h.auth);
    addTearDown(() async {
      h.closing = true;
      h.repository.dispose();
      h.auth.dispose();
      for (final socket in h.sockets) {
        await socket.close();
      }
      await h.server.close(force: true);
      messenger.setMockMethodCallHandler(NativeRelayCrypto.channel, null);
    });
    await h.repository.listConnections();
    h.repository.setActive(true);
    await _until(
      () =>
          h.repository.chatOnline('connector') &&
          (!twoConnectors || h.repository.chatOnline('other')),
    );
    return h;
  }

  void hello(Map<String, dynamic> identity) => sockets.last.add(
    jsonEncode({
      'protocolVersion': 2,
      'type': 'connector.hello',
      'identity': identity,
      'nonce': connectorNonce,
      'capabilities': [...McpSnapshot.capabilities, 'chat.snapshot'],
    }),
  );

  void sendEvent({String? id, int revision = 1, Map<String, dynamic>? from}) {
    final update = mcpFixture['update'] as Map<String, dynamic>;
    send({
      'protocolVersion': 2,
      'kind': 'event',
      'operation': 'project.mcp.updated',
      'requestId': id ?? update['subscriptionId'],
      'sentAt': DateTime.now().millisecondsSinceEpoch,
      'body': {
        ...update,
        'subscriptionId': id ?? update['subscriptionId'],
        'revision': revision,
      },
    }, from: from);
  }

  void send(Map<String, dynamic> payload, {Map<String, dynamic>? from}) {
    if (sockets.last.readyState != WebSocket.open) return;
    final sender = from ?? peer;
    sockets.last.add(
      jsonEncode({
        'protocolVersion': 2,
        'type': 'relay.envelope',
        'messageId': requestId(),
        'senderKeyId': sender['keyId'],
        'recipientKeyId': own['keyId'],
        'epoch': epochFor(sender),
        'sequence': sequence++,
        'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
        'suite': identitySuite,
        'encapsulatedKey': base64Url(List.filled(65, 1)),
        'ciphertext': base64Url(utf8.encode(jsonEncode(payload))),
      }),
    );
  }
}

final class _Api implements RemoteApi {
  _Api(this.identity, {this.otherIdentity});
  Map<String, dynamic> identity;
  final Map<String, dynamic>? otherIdentity;
  bool otherVisible = true;
  final auth = FakeRemoteApi();
  @override
  Future<ApiResponse> request(
    ServerEndpoint server,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? accessToken,
    String? cookie,
  }) async {
    if (path == '/v1/connectors') {
      return ApiResponse({
        'connectors': [
          {
            'id': 'connector',
            'name': 'Fixture connector',
            'identity': identity,
          },
          if (otherVisible && otherIdentity != null)
            {
              'id': 'other',
              'name': 'Other connector',
              'identity': otherIdentity,
            },
        ],
      });
    }
    if (path == '/v1/connectors/connector/revoke') return const ApiResponse({});
    if (path == '/v1/connectors/other/revoke') {
      otherVisible = false;
      return const ApiResponse({});
    }
    if (path == '/v1/relay/tickets') {
      return const ApiResponse({
        'webSocketUrl': '/relay',
        'ticket': 'test-ticket',
      });
    }
    return auth.request(
      server,
      path,
      method: method,
      body: body,
      accessToken: accessToken,
      cookie: cookie,
    );
  }
}
