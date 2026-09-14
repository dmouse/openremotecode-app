import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/data/relay_crypto.dart';
import 'package:openremotecode/features/connections/data/device_identity.dart';

import 'support/mcp_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final duringSeal in [false, true]) {
    for (final operation in ['chat.snapshot', 'chat.rename']) {
      test(
        'peer disconnect fails only its $operation request ${duringSeal ? 'during sealing' : 'after send'}',
        () async {
          final crypto = _Crypto();
          if (duringSeal) crypto.sealing = Completer<Map<String, dynamic>>();
          final relay = RelayRequests(crypto: crypto);
          addTearDown(relay.disconnect);
          const other = PublicIdentity(keyId: 'other-key', publicKey: 'unused');
          final sent = <String>[];
          var healthyCompleted = false;
          final healthy = relay
              .request(
                operation: 'chat.snapshot',
                body: {},
                identity: _own,
                peer: _peer,
                send: (_) => sent.add('healthy'),
              )
              .then((value) {
                healthyCompleted = true;
                return value;
              });
          final payload = crypto.sealed;
          final affected = relay.request(
            operation: operation,
            body: {},
            identity: _own,
            peer: other,
            send: (_) => sent.add('affected'),
          );
          final failed = expectLater(
            affected,
            throwsA(
              operation == 'chat.rename'
                  ? ChatFailure.uncertain
                  : ChatFailure.offline,
            ),
          );
          await Future<void>.delayed(Duration.zero);
          relay.disconnect(peerKeyId: other.keyId);
          await failed;
          expect(healthyCompleted, isFalse);
          if (duringSeal) crypto.sealing!.complete(_envelope());
          await Future<void>.delayed(Duration.zero);
          expect(sent, duringSeal ? ['healthy'] : ['healthy', 'affected']);
          crypto.opened = {
            ...payload,
            'kind': 'response',
            'body': {'version': 1},
          };
          await relay.receive(_envelope(), _own, _peer);
          expect(await healthy, {'version': 1});
        },
      );
    }
  }

  for (final failure in [false, true]) {
    test(
      'peer invalidation drops late decrypt ${failure ? 'failure' : 'event'} without invalidating healthy peer',
      () async {
        final crypto = _Crypto();
        final relay = RelayRequests(crypto: crypto);
        const other = PublicIdentity(keyId: 'other-key', publicKey: 'unused');
        final healthyGeneration = relay.generation(_peer.keyId);
        final affectedGeneration = relay.generation(other.keyId);
        final healthyGate = Completer<Map<String, dynamic>>();
        final affectedGate = Completer<Map<String, dynamic>>();
        final delivered = <String>[];
        crypto.opening = healthyGate;
        final healthyEnvelope = _envelope();
        final healthy = relay.receive(
          healthyEnvelope,
          _own,
          _peer,
          onEvent: (_, _, _) => delivered.add('healthy'),
        );
        crypto.opening = affectedGate;
        final affected = relay.receive(
          {..._envelope(), 'senderKeyId': other.keyId},
          _own,
          other,
          onEvent: (_, _, _) => delivered.add('affected'),
        );
        relay.disconnect(peerKeyId: other.keyId);
        expect(relay.generation(_peer.keyId), same(healthyGeneration));
        expect(relay.generation(other.keyId), isNot(same(affectedGeneration)));
        if (failure) {
          affectedGate.completeError(const FormatException());
        } else {
          affectedGate.complete(_event);
        }
        healthyGate.complete(_event);
        await Future.wait([healthy, affected]);
        expect(delivered, ['healthy']);
        crypto.opening = null;
        crypto.opened = _event;
        await relay.receive(
          healthyEnvelope,
          _own,
          _peer,
          onEvent: (_, _, _) => delivered.add('replay'),
        );
        expect(delivered, ['healthy']);
        final currentOther = relay.generation(other.keyId);
        relay.disconnect();
        expect(relay.generation(_peer.keyId), isNot(same(healthyGeneration)));
        expect(relay.generation(other.keyId), isNot(same(currentOther)));
      },
    );
  }

  for (final topic in ['snapshot', 'subscribe', 'unsubscribe']) {
    test(
      'encrypted project.mcp.$topic uses its separate shared contract',
      () async {
        final fixture = mcpFixture;
        final crypto = _Crypto();
        final relay = RelayRequests(crypto: crypto);
        addTearDown(relay.disconnect);
        final sent = Completer<String>();
        final request = Map<String, dynamic>.from(
          fixture[topic == 'snapshot' ? 'snapshotRequest' : 'subscribeRequest']
              as Map,
        );
        final response = topic == 'snapshot'
            ? fixture['snapshotResponse']
            : topic == 'subscribe'
            ? fixture['update']
            : {'version': 1, 'unsubscribed': true};
        final result = relay.request(
          operation: 'project.mcp.$topic',
          body: request,
          identity: _own,
          peer: _peer,
          send: sent.complete,
        );
        await sent.future;
        expect(crypto.sealed['body'], request);
        expect(crypto.sealed['kind'], 'request');
        expect(crypto.sealed['operation'], 'project.mcp.$topic');
        expect(crypto.sealed['body'], isNot(contains('includeMcp')));
        crypto.opened = {
          ...crypto.sealed,
          'kind': 'response',
          'body': response,
        };
        await relay.receive(_envelope(), _own, _peer);
        expect(await result, response);
      },
    );
  }

  test('event/response kind separation prevents pending request completion on ID collision', () async {
    final crypto = _Crypto();
    final relay = RelayRequests(crypto: crypto);
    addTearDown(relay.disconnect);
    final sent = Completer<String>();
    var completed = false;
    final result = relay
        .request(
          operation: 'project.mcp.subscribe',
          body: mcpFixture['subscribeRequest'] as Map<String, dynamic>,
          identity: _own,
          peer: _peer,
          send: sent.complete,
        )
        .then((value) {
          completed = true;
          return value;
        });
    await sent.future;
    final events = <Map<String, dynamic>>[];
    crypto.opened = {
      ...crypto.sealed,
      'kind': 'event',
      'operation': 'project.mcp.updated',
      'body': mcpFixture['update'],
    };
    await relay.receive(
      _envelope(),
      _own,
      _peer,
      onEvent: (op, id, body) {
        expect(op, 'project.mcp.updated');
        expect(id, crypto.sealed['requestId']);
        events.add(body);
      },
    );
    expect(events.single, mcpFixture['update']);
    expect(completed, isFalse);
    // Neither an event with the response operation nor an event error is a reply.
    for (final operation in ['project.mcp.subscribe', 'protocol.error']) {
      crypto.opened = {
        ...crypto.opened,
        'operation': operation,
        'body': {'version': 1, 'code': 'access_denied'},
      };
      await relay.receive(_envelope(), _own, _peer);
      expect(completed, isFalse);
    }
    crypto.opened = {
      ...crypto.sealed,
      'kind': 'response',
      'body': mcpFixture['update'],
    };
    await relay.receive(_envelope(), _own, _peer);
    expect(await result, mcpFixture['update']);
  });

  test('wrong peer cannot answer a request; authenticated errors stay request-local', () async {
    final crypto = _Crypto();
    final relay = RelayRequests(crypto: crypto);
    addTearDown(relay.disconnect);
    final sent = Completer<String>();
    var completed = false;
    final result = relay.request(
      operation: 'project.mcp.subscribe',
      body: mcpFixture['subscribeRequest'] as Map<String, dynamic>,
      identity: _own,
      peer: _peer,
      send: sent.complete,
    );
    final checked = expectLater(
      result.then((r) {
        completed = true;
        return r;
      }),
      throwsA(ChatFailure.unsupported),
    );
    await sent.future;
    crypto.opened = {
      ...crypto.sealed,
      'kind': 'response',
      'operation': 'protocol.error',
      'body': {'version': 1, 'code': 'unsupported_operation'},
    };
    const other = PublicIdentity(keyId: 'other-key', publicKey: 'unused');
    await expectLater(
      relay.receive(_envelope(), _own, other),
      throwsFormatException,
    );
    await relay.receive(
      {..._envelope(), 'senderKeyId': other.keyId},
      _own,
      other,
    );
    expect(completed, isFalse);
    await relay.receive(_envelope(), _own, _peer);
    await checked;
    final nextSent = Completer<String>();
    final conversation = relay.request(
      operation: 'chat.snapshot',
      body: {},
      identity: _own,
      peer: _peer,
      send: nextSent.complete,
    );
    await nextSent.future;
    crypto.opened = {
      ...crypto.sealed,
      'kind': 'response',
      'body': {'version': 1},
    };
    await relay.receive(_envelope(), _own, _peer);
    expect(await conversation, {'version': 1});
  });

  test(
    'replayed encrypted events are dropped, including across reconnect',
    () async {
      final crypto = _Crypto()..opened = _event;
      final relay = RelayRequests(crypto: crypto);
      final envelope = _envelope();
      var count = 0;
      void event(String op, String id, Map<String, dynamic> body) => count++;
      await relay.receive(envelope, _own, _peer, onEvent: event);
      await relay.receive(envelope, _own, _peer, onEvent: event);
      relay.disconnect();
      await relay.receive(envelope, _own, _peer, onEvent: event);
      expect(count, 1);
      expect(crypto.opens, 1);
      await expectLater(
        relay.receive(
          {..._envelope(), 'expiresAt': 0},
          _own,
          _peer,
          onEvent: event,
        ),
        throwsFormatException,
      );
      await expectLater(
        relay.receive(
          {..._envelope(), 'recipientKeyId': 'wrong'},
          _own,
          _peer,
          onEvent: event,
        ),
        throwsFormatException,
      );
      expect(count, 1);
    },
  );

  for (final transition in ['generation', 'trust/source']) {
    test(
      'late async decryption after $transition is discarded before event dispatch',
      () async {
        final crypto = _Crypto()..opening = Completer<Map<String, dynamic>>();
        final relay = RelayRequests(crypto: crypto);
        var current = true, delivered = false;
        final opening = relay.receive(
          _envelope(),
          _own,
          _peer,
          isCurrent: () => current,
          onEvent: (_, _, _) => delivered = true,
        );
        if (transition == 'generation') {
          relay.disconnect();
        } else {
          current = false;
        }
        crypto.opening!.complete(_event);
        await opening;
        expect(delivered, isFalse);
      },
    );
  }

  test('native crypto keeps MCP inside HPKE content, authenticates routing, narrowly allows updated events', () async {
    // The platform boundary is mocked here; native HPKE interoperability remains
    // a separate isolated-device integration check, not a claim of this test.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var opened = _event;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(NativeRelayCrypto.channel, (call) async {
      calls.add(call);
      if (call.method == 'seal') {
        return {
          'enc': Uint8List.fromList(List.filled(65, 1)),
          'ciphertext': Uint8List.fromList([7, 8, 9]),
        };
      }
      return Uint8List.fromList(utf8.encode(jsonEncode(opened)));
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(NativeRelayCrypto.channel, null),
    );
    final own = {
      ..._own,
      'privateKey': base64Url(List.filled(32, 1)),
      'publicKey': base64Url(List.filled(65, 2)),
    };
    final peer = PublicIdentity(
      keyId: _peer.keyId,
      publicKey: base64Url(List.filled(65, 3)),
    );
    const crypto = NativeRelayCrypto();
    final request = {
      ..._event,
      'kind': 'request',
      'operation': 'project.mcp.subscribe',
      'body': mcpFixture['subscribeRequest'],
    };
    final envelope = await crypto.seal(own, peer, request, 7);
    final seal = calls.single.arguments as Map;
    expect(jsonDecode(utf8.decode(seal['content'] as Uint8List)), request);
    expect(jsonEncode(envelope), isNot(contains('project.mcp')));
    expect(jsonEncode(envelope), isNot(contains(mcpProject)));
    expect(jsonDecode(utf8.decode(seal['aad'] as Uint8List)), [
      'opencode-remote-relay',
      1,
      'relay.envelope',
      envelope['messageId'],
      _own['keyId'],
      peer.keyId,
      7,
      envelope['expiresAt'],
      identitySuite,
    ]);
    expect(await crypto.open(own, peer, _envelope()), opened);
    expect((calls.last.arguments as Map)['peerKey'], decodeUrl(peer.publicKey));
    for (final invalid in [
      {..._event, 'kind': 'request'},
      {..._event, 'operation': 'chat.snapshot'},
      {..._event, 'operation': 'protocol.error'},
      {..._event, 'requestId': 'not-a-uuid'},
      {..._event, 'extra': true},
    ]) {
      opened = invalid;
      await expectLater(
        crypto.open(own, peer, _envelope()),
        throwsFormatException,
      );
    }
    opened = {
      ..._event,
      'kind': 'response',
      'operation': 'project.mcp.subscribe',
    };
    expect(await crypto.open(own, peer, _envelope()), opened);
  });
}

const _own = <String, dynamic>{'keyId': 'client-key'};
const _peer = PublicIdentity(keyId: 'connector-key', publicKey: 'unused');
Map<String, dynamic> get _event => {
  'protocolVersion': 1,
  'kind': 'event',
  'requestId': mcpFixture['subscribeRequest']['subscriptionId'],
  'sentAt': 100,
  'operation': 'project.mcp.updated',
  'body': mcpFixture['update'],
};
Map<String, dynamic> _envelope() => {
  'protocolVersion': 1,
  'type': 'relay.envelope',
  'messageId': requestId(),
  'senderKeyId': _peer.keyId,
  'recipientKeyId': _own['keyId'],
  'sequence': 1,
  'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
  'suite': identitySuite,
  'encapsulatedKey': base64Url(List.filled(65, 1)),
  'ciphertext': base64Url([1, 2, 3]),
};

final class _Crypto implements RelayCrypto {
  Map<String, dynamic> sealed = {}, opened = {};
  Completer<Map<String, dynamic>>? opening, sealing;
  int opens = 0;
  @override
  Future<Map<String, dynamic>> seal(
    Map<String, dynamic> own,
    PublicIdentity peer,
    Map<String, dynamic> payload,
    int sequence,
  ) async {
    sealed = payload;
    return sealing?.future ?? _envelope();
  }

  @override
  Future<Map<String, dynamic>> open(
    Map<String, dynamic> own,
    PublicIdentity peer,
    Map<String, dynamic> envelope,
  ) async {
    opens++;
    return opening?.future ?? opened;
  }
}
