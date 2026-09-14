import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/connections/connections_view_model.dart';
import 'package:openremotecode/features/connections/data/connections_repository.dart';
import 'package:openremotecode/features/connections/domain/connection_name.dart';
import 'package:openremotecode/features/connections/ui/connections_screen.dart';

import 'support/connections_fakes.dart';

void main() {
  test('name validation follows the server UTF8 limit and trims input', () {
    expect(ConnectionName.parse('  Laptop  '), 'Laptop');
    for (final value in ['', '  ', 'a' * 65, 'é' * 33]) {
      expect(() => ConnectionName.parse(value), throwsFormatException);
    }
    expect(ConnectionName.parse('é' * 32), 'é' * 32);
  });

  test('rename waits for persistence, blocks conflicting actions and keeps old name on failure', () async {
    final repository = FakeConnectionsRepository();
    repository.connections = [repository.connection];
    final model = ConnectionsViewModel(repository);
    addTearDown(model.dispose);
    await model.load();
    repository.gate = Completer<void>();
    final pending = model.renameConnection(
      repository.connection.id,
      'Workstation',
    );
    expect(model.connections.single.name, repository.connection.name);
    expect(await model.deleteConnection(repository.connection.id), isFalse);
    expect(
      await model.renameConnection(repository.connection.id, 'Duplicate'),
      isFalse,
    );
    repository.failure = ConnectionFailure.network;
    repository.gate!.complete();
    expect(await pending, isFalse);
    expect(model.connections.single.name, repository.connection.name);
    repository.failure = null;
    expect(
      await model.renameConnection(repository.connection.id, '  Workstation  '),
      isTrue,
    );
    expect(model.connections.single.name, 'Workstation');
    await model.load();
    expect(model.connections.single.name, 'Workstation');
  });

  testWidgets(
    'three-dot menu opens rename; validation and cancel preserve the saved name',
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
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      await tester.tap(find.byTooltip('Connection options'));
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        repository.connection.name,
      );
      await tester.enterText(find.byType(TextFormField), ' ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a name.'), findsOneWidget);
      expect(repository.renames, 0);
      await tester.enterText(find.byType(TextFormField), 'Workstation');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repository.renames, 1);
      expect(find.text('Workstation'), findsOneWidget);
    },
  );
}
