import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/connections/data/connection_color_store.dart';
import 'package:openremotecode/features/connections/domain/connection_color.dart';
import 'package:openremotecode/features/connections/domain/remote_connection.dart';
import 'package:openremotecode/features/connections/data/connections_repository.dart';
import 'package:openremotecode/features/connections/connections_view_model.dart';
import 'package:openremotecode/features/connections/ui/connections_screen.dart';
import 'package:openremotecode/ui/core/chat_avatar.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

import 'support/auth_fakes.dart';
import 'support/connections_fakes.dart';

class ColorsRepository implements ConnectionsRepository, ConnectionAppearance {
  final base = FakeConnectionsRepository();
  ConnectionColor saved = ConnectionColor.blue;
  bool fail = false;
  @override
  Future<ConnectionColor> readConnectionColor(String id) async => saved;
  @override
  Future<void> writeConnectionColor(String id, ConnectionColor color) async {
    if (fail) throw StateError('Storage unavailable');
    saved = color;
  }

  @override
  Future<List<RemoteConnection>> listConnections() async => [base.connection];
  @override
  Future<String> renameConnection(String id, String name) async => name;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('colors persist with server/account/connector isolation and reset removes the record', () async {
    final secure = MemorySecureStore();
    final store = ConnectionColorStore(secure, 'server|account');
    await store.write('remote', ConnectionColor.purple);
    expect(
      await ConnectionColorStore(secure, 'server|account').read('remote'),
      ConnectionColor.purple,
    );
    expect(await store.read('other-remote'), ConnectionColor.lime);
    expect(
      await ConnectionColorStore(secure, 'other-server|account').read('remote'),
      ConnectionColor.lime,
    );
    expect(
      await ConnectionColorStore(secure, 'server|other-account').read('remote'),
      ConnectionColor.lime,
    );
    await store.write('remote', ConnectionColor.lime);
    expect(secure.values, isEmpty);
  });
  test('rename preserves color and failed saves preserve the last acknowledged choice', () async {
    final repository = ColorsRepository();
    final model = ConnectionsViewModel(repository);
    await model.load();
    expect(model.colorFor('con_test'), ConnectionColor.blue);
    await model.renameConnection('con_test', 'New name');
    expect(model.colorFor('con_test'), ConnectionColor.blue);
    repository.fail = true;
    expect(await model.setColor('con_test', ConnectionColor.rose), isFalse);
    expect(model.colorFor('con_test'), ConnectionColor.blue);
    expect(model.error, contains('could not be saved'));
    model.dispose();
  });
  testWidgets('connection menu changes a named color in both themes', (
    tester,
  ) async {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      final repository = ColorsRepository();
      final model = ConnectionsViewModel(repository);
      await model.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: ConnectionsScreen(viewModel: model, onAddConnection: () {}),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Connection options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Color'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Purple'));
      await tester.pumpAndSettle();
      expect(model.colorFor('con_test'), ConnectionColor.purple);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    }
  });
  test(
    'all avatar colors retain dark-icon contrast in light and dark modes',
    () {
      for (final color in ConnectionColor.values) {
        final contrast =
            (connectionAccent(color).computeLuminance() + .05) /
            (AppTheme.ink.computeLuminance() + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
    },
  );
}
