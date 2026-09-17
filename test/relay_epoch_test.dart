import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/data/relay_crypto.dart';

void main() {
  test('epoch derivation matches the shared cross-language fixture', () {
    // The plugin derives epochs from the same fixture; if either side drifts the
    // two peers silently stop agreeing on what connection they are in.
    final fixture =
        jsonDecode(
              File(
                '../packages/protocol/test/fixtures/relay-epoch-v2.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(fixture['version'], relayProtocolVersion);
    for (final testCase in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      expect(
        deriveRelayEpoch(
          connectorKeyId: testCase['connectorKeyId'] as String,
          connectorNonce: testCase['connectorNonce'] as String,
          clientKeyId: testCase['clientKeyId'] as String,
          clientNonce: testCase['clientNonce'] as String,
        ),
        testCase['epoch'],
      );
    }
  });

  test('both peers agree, and any fresh nonce ends the epoch', () {
    final peers = {
      'connectorKeyId': 'c' * 43,
      'connectorNonce': relayNonce(),
      'clientKeyId': 'b' * 43,
      'clientNonce': relayNonce(),
    };
    String derive(Map<String, String> input) => deriveRelayEpoch(
      connectorKeyId: input['connectorKeyId']!,
      connectorNonce: input['connectorNonce']!,
      clientKeyId: input['clientKeyId']!,
      clientNonce: input['clientNonce']!,
    );

    final epoch = derive(peers);
    expect(derive(peers), epoch);
    expect(RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(epoch), isTrue);
    for (final field in ['connectorNonce', 'clientNonce']) {
      expect(derive({...peers, field: relayNonce()}), isNot(epoch));
    }
    expect(
      () => derive({...peers, 'clientNonce': 'too-short'}),
      throwsFormatException,
    );
  });

  test('nonces are unique and correctly shaped', () {
    final nonces = {for (var i = 0; i < 64; i++) relayNonce()};
    expect(nonces, hasLength(64));
    for (final nonce in nonces) {
      expect(RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(nonce), isTrue);
    }
  });

  test('the replay window accepts progress and reordering but never a repeat', () {
    final window = ReplayWindow(64);

    expect(window.accept(0), isTrue);
    expect(window.accept(0), isFalse);
    expect(window.accept(1), isTrue);

    // Envelopes seal concurrently, so they can arrive out of order.
    expect(window.accept(5), isTrue);
    expect(window.accept(3), isTrue);
    expect(window.accept(4), isTrue);
    expect(window.accept(3), isFalse);
    expect(window.accept(5), isFalse);

    // Anything older than the window is refused rather than re-accepted.
    expect(window.accept(200), isTrue);
    expect(window.accept(5), isFalse);
    expect(window.accept(136), isFalse);
    expect(window.accept(137), isTrue);

    // A jump past the window width clears it without stranding later sequences.
    expect(window.accept(10000), isTrue);
    expect(window.accept(9999), isTrue);
    expect(window.accept(9999), isFalse);

    expect(window.accept(-1), isFalse);
  });
}
