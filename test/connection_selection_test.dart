import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/connections/connections_view_model.dart';
import 'package:openremotecode/features/connections/domain/remote_connection.dart';
import 'package:openremotecode/features/connections/ui/connection_card.dart';
import 'package:openremotecode/features/connections/ui/connections_screen.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

import 'support/connections_fakes.dart';

void main() {
  const laptop = RemoteConnection(
    id: 'laptop',
    name: 'Laptop',
    status: ConnectionStatus.online,
  );
  const desktop = RemoteConnection(
    id: 'desktop',
    name: 'Desktop',
    status: ConnectionStatus.offline,
  );

  test('selection follows IDs and clears only after removal', () async {
    final repository = FakeConnectionsRepository()
      ..connections = [laptop, desktop];
    final model = ConnectionsViewModel(repository);
    addTearDown(model.dispose);
    await model.load();
    model.selectConnection(laptop.id);
    model.selectConnection('missing');
    expect(model.selectedId, laptop.id);
    await model.renameConnection(laptop.id, 'Work laptop');
    await model.load();
    expect(model.selectedId, laptop.id);
    repository.failure = Exception('Unavailable');
    await model.deleteConnection(laptop.id);
    expect(model.selectedId, laptop.id);
    repository.failure = null;
    await model.deleteConnection(laptop.id);
    expect(model.selectedId, isNull);
    model.selectConnection(desktop.id);
    repository.connections = [];
    await model.load();
    expect(model.selectedId, isNull);
  });

  testWidgets('card taps select one connection; options keep selection', (
    tester,
  ) async {
    final repository = FakeConnectionsRepository()
      ..connections = [laptop, desktop];
    final model = ConnectionsViewModel(repository);
    addTearDown(model.dispose);
    await model.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ConnectionsScreen(viewModel: model, onAddConnection: () {}),
        ),
      ),
    );
    Border borderFor(String id) {
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byKey(ValueKey(id)),
              matching: find.byType(Container),
            )
            .first,
      );
      return (container.decoration! as BoxDecoration).border! as Border;
    }

    expect(borderFor(laptop.id).top.color, AppTheme.border);
    expect(borderFor(desktop.id).top.color, AppTheme.muted);
    await tester.tap(find.text('Laptop'));
    await tester.pumpAndSettle();
    expect(model.selectedId, laptop.id);
    expect(borderFor(laptop.id).top.color, AppTheme.selectedBorder);
    expect(borderFor(laptop.id).top.width, 2);
    await tester.tap(find.text('Desktop'));
    await tester.pumpAndSettle();
    expect(model.selectedId, desktop.id);
    expect(borderFor(desktop.id).top.color, AppTheme.muted);
    expect(borderFor(desktop.id).top.width, 2);
    expect(find.text('Selected'), findsOneWidget);
    expect(borderFor(laptop.id).top.color, AppTheme.border);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ConnectionCard, 'Laptop'),
        matching: find.byTooltip('Connection options'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    expect(model.selectedId, desktop.id);
    expect(repository.revocations, 0);
    expect(repository.confirmations, 0);
    // A presence update changes the outline without losing selection.
    repository.connections = [
      laptop,
      RemoteConnection(
        id: desktop.id,
        name: desktop.name,
        status: ConnectionStatus.online,
      ),
    ];
    await model.load();
    await tester.pumpAndSettle();
    expect(model.selectedId, desktop.id);
    expect(borderFor(desktop.id).top.color, AppTheme.selectedBorder);
    repository.connections = [laptop, desktop];
    await model.load();
    await tester.pumpAndSettle();
    expect(model.selectedId, desktop.id);
    expect(borderFor(desktop.id).top.color, AppTheme.muted);
    expect(borderFor(desktop.id).top.width, 2);
    expect(tester.takeException(), isNull);
  });
}
