import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/data/relay_crypto.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              '../packages/protocol/test/fixtures/connector-credential-v1.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  test('the event operation is accepted by the transport allowlist', () {
    // Registered in one place now, but the connector still has to be able to reach the UI:
    // an operation missing here is dropped before anything can render it.
    expect(
      connectorEventOperations.contains(fixture['operation']),
      isTrue,
      reason: 'the connector event would be discarded before dispatch',
    );
  });

  test('both outcomes from the shared fixture render a message', () {
    for (final outcome in ['renewed', 'failed']) {
      final body = fixture[outcome] as Map<String, dynamic>;
      final message = credentialNoticeMessage(body);
      expect(message, isNotNull, reason: 'no message for $outcome');
      expect(message, isNot(contains('orc_')));
      expect(message, isNot(isEmpty));
    }
    expect(
      credentialNoticeMessage(fixture['renewed'] as Map<String, dynamic>),
      isNot(credentialNoticeMessage(fixture['failed'] as Map<String, dynamic>)),
      reason: 'a renewal and a failure must not read the same',
    );
  });

  test('a body this build does not understand renders nothing', () {
    // The body crosses the relay boundary, so an unknown shape is ignored rather than
    // rendered as a half-formed notice.
    for (final body in [
      <String, dynamic>{},
      {'version': 2, 'outcome': 'renewed', 'occurredAt': 0},
      {'version': 1, 'outcome': 'rotated', 'occurredAt': 0},
      {'version': 1, 'occurredAt': 0},
      {'version': 1, 'outcome': 42, 'occurredAt': 0},
    ]) {
      expect(credentialNoticeMessage(body), isNull, reason: '$body');
    }
  });
}
