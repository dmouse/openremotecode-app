import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/app.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/features/workspace/ui/workspace_screen.dart';

import 'support/auth_fakes.dart';
import 'support/connections_fakes.dart';
import 'support/memory_server_settings_repository.dart';

void main() {
  testWidgets(
    'bad password stays on login; restored auth gates home and logout clears it',
    (tester) async {
      final auth = fakeAuth();
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        MainApp(
          authRepository: auth,
          serverSettingsRepository: MemoryServerSettingsRepository(),
          connectionsRepositoryFactory: (_) => FakeConnectionsRepository(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email address'),
        'person@example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'incorrect',
      );
      await tester.ensureVisible(find.text('Sign in'));
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Email or password is incorrect.'), findsOneWidget);
      expect(find.byType(WorkspaceScreen), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'correct-password',
      );
      await tester.ensureVisible(find.text('Sign in'));
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceScreen), findsOneWidget);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceScreen), findsNothing);
      expect(find.text('Sign in'), findsOneWidget);
    },
  );

  testWidgets(
    'one code field leads to explicit safety confirmation and a real list update',
    (tester) async {
      final auth = fakeAuth();
      addTearDown(auth.dispose);
      await auth.login(
        ServerEndpoint.parse('https://remote.example.test'),
        'person@example.com',
        'password',
      );
      final repository = FakeConnectionsRepository();
      await tester.pumpWidget(
        MainApp(
          authRepository: auth,
          serverSettingsRepository: MemoryServerSettingsRepository(),
          connectionsRepositoryFactory: (_) => repository,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enter pairing code'));
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'abcd-efgh');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Check the safety code'), findsOneWidget);
      expect(repository.confirmations, 0);
      await tester.tap(find.text('Codes match — confirm'));
      await tester.pumpAndSettle();
      expect(repository.confirmations, 1);
      expect(find.text('Development laptop'), findsOneWidget);
      expect(find.text('Check the safety code'), findsNothing);
    },
  );
}
