import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/connections/connections_view_model.dart';
import 'package:openremotecode/features/connections/data/connections_repository.dart';
import 'package:openremotecode/features/connections/ui/connections_screen.dart';

import 'support/connections_fakes.dart';

void main() {
  test('deletion waits for revocation, blocks duplicates, and retains failures for retry', () async {
    final repository = FakeConnectionsRepository();
    repository.connections = [repository.connection];
    final model = ConnectionsViewModel(repository);
    addTearDown(model.dispose);
    await model.load();
    repository.gate = Completer<void>();
    final pending = model.deleteConnection(repository.connection.id);
    expect(model.connections, hasLength(1));
    expect(await model.deleteConnection(repository.connection.id), isFalse);
    expect(repository.revocations, 1);
    repository.failure = ConnectionFailure.network;
    repository.gate!.complete();
    expect(await pending, isFalse);
    expect(model.connections, hasLength(1));
    expect(model.error, contains('kept'));
    repository.failure = null;
    expect(await model.deleteConnection(repository.connection.id), isTrue);
    expect(model.connections, isEmpty);
  });

  testWidgets(
    'delete requires confirmation and cancel preserves the connection',
    (tester) async {
      final repository = FakeConnectionsRepository();
      repository.connections = [repository.connection];
      final model = ConnectionsViewModel(repository);
      addTearDown(model.dispose);
      await model.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectionsScreen(viewModel: model, onAddConnection: () {}),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Connection options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.textContaining('for every device'), findsOneWidget);
      expect(repository.revocations, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text(repository.connection.name), findsOneWidget);
      await tester.tap(find.byTooltip('Connection options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete and revoke'));
      await tester.pumpAndSettle();
      expect(repository.revocations, 1);
      expect(find.text(repository.connection.name), findsNothing);
      expect(find.text('Enter pairing code'), findsOneWidget);
    },
  );
}
