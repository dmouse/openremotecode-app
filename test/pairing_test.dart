import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/connections/connections_view_model.dart';
import 'package:openremotecode/features/connections/data/connections_repository.dart';
import 'package:openremotecode/features/connections/domain/pairing_code.dart';
import 'package:openremotecode/features/connections/domain/remote_connection.dart';
import 'package:openremotecode/features/connections/pairing_view_model.dart';

import 'support/connections_fakes.dart';

void main() {
  test(
    'short code accepts typed/pasted code without dropping invalid letters',
    () {
      expect(PairingCode.parse(' abcd efgh\n').value, 'ABCD-EFGH');
      expect(PairingCode.parse('1234-5678').value, '1234-5678');
      for (final value in [
        '',
        'ABCD',
        'ABCD-EFGHI',
        'ABCD-EFG!',
        'ABCD-EFGI',
        'ABCD-EFGO',
        'ABCD-EFGU',
      ]) {
        expect(() => PairingCode.parse(value), throwsFormatException);
      }
    },
  );

  test(
    'review alone never confirms; mismatch discards trust material',
    () async {
      final repo = FakeConnectionsRepository();
      final model = PairingViewModel(repo);
      addTearDown(model.dispose);
      await model.checkCode('abcdefgh');
      expect(repo.code, 'ABCD-EFGH');
      expect(model.review, isNotNull);
      expect(repo.confirmations, 0);
      model.reject();
      expect(await model.confirm(), isNull);
      expect(repo.confirmations, 0);
      expect(model.error, contains('did not match'));
    },
  );

  test('expired and used codes surface distinct recoverable errors', () async {
    for (final failure in [
      ConnectionFailure.expiredCode,
      ConnectionFailure.usedCode,
      ConnectionFailure.invalidCode,
    ]) {
      final model = PairingViewModel(
        FakeConnectionsRepository()..failure = failure,
      );
      await model.checkCode('ABCD-EFGH');
      expect(model.error, failure.message);
      expect(model.review, isNull);
      model.dispose();
    }
  });

  test(
    'expiry between review and confirmation cannot authorize a device',
    () async {
      var now = DateTime.now();
      final repo = FakeConnectionsRepository();
      final model = PairingViewModel(repo, now: () => now);
      addTearDown(model.dispose);
      await model.checkCode('ABCD-EFGH');
      now = now.add(const Duration(minutes: 6));
      expect(await model.confirm(), isNull);
      expect(repo.confirmations, 0);
    },
  );

  test(
    'duplicate requests and completion after disposal are harmless',
    () async {
      final repo = FakeConnectionsRepository()..gate = Completer<void>();
      final model = PairingViewModel(repo);
      final first = model.checkCode('ABCD-EFGH');
      await model.checkCode('1234-5678');
      expect(repo.claims, 1);
      model.dispose();
      repo.gate!.complete();
      await first;
    },
  );

  test(
    'confirmation can be explicitly retried when connector has not polled',
    () async {
      final repo = FakeConnectionsRepository();
      final model = PairingViewModel(repo);
      addTearDown(model.dispose);
      await model.checkCode('ABCD-EFGH');
      repo.failure = ConnectionFailure.connectorNotReady;
      expect(await model.confirm(), isNull);
      expect(model.review, isNotNull);
      repo.failure = null;
      expect(await model.confirm(), repo.connection);
      expect(repo.confirmations, 2);
    },
  );

  test(
    'connection list keeps offline entries and sorts online first',
    () async {
      final repo = FakeConnectionsRepository()
        ..connections = [
          const RemoteConnection(
            id: 'a',
            name: 'A laptop',
            status: ConnectionStatus.offline,
          ),
          const RemoteConnection(
            id: 'z',
            name: 'Z desktop',
            status: ConnectionStatus.online,
          ),
        ];
      final model = ConnectionsViewModel(repo);
      addTearDown(model.dispose);
      await model.load();
      expect(model.connections.map((item) => item.id), ['z', 'a']);
      expect(() => model.connections.clear(), throwsUnsupportedError);
      repo.gate = Completer<void>();
      final loading = model.load();
      model.addConfirmed(repo.connection);
      repo.gate!.complete();
      await loading;
      expect(model.connections.length, 3);
    },
  );
}
