import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/app.dart';
import 'package:openremotecode/features/login/ui/login_header.dart';
import 'package:openremotecode/features/server_settings/ui/server_settings_sheet.dart';
import 'package:openremotecode/features/workspace/ui/workspace_screen.dart';

import 'support/memory_server_settings_repository.dart';
import 'support/auth_fakes.dart';
import 'support/connections_fakes.dart';

MainApp testApp({
  required MemoryServerSettingsRepository serverSettingsRepository,
}) {
  final auth = fakeAuth();
  addTearDown(auth.dispose);
  return MainApp(
    serverSettingsRepository: serverSettingsRepository,
    authRepository: auth,
    connectionsRepositoryFactory: (_) => FakeConnectionsRepository(),
  );
}

Future<void> openSettings(WidgetTester tester) async {
  await tester.ensureVisible(find.byType(LoginHeader));
  for (var i = 0; i < 6; i++) {
    await tester.tap(find.text('Open Remote Code'));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('configuration stays hidden and login controls cannot open it', (
    tester,
  ) async {
    await tester.pumpWidget(
      testApp(
        serverSettingsRepository: MemoryServerSettingsRepository()
          ..failRead = true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Choose your server'), findsNothing);
    expect(find.text('REMOTE SERVER'), findsNothing);
    expect(find.bySemanticsLabel('Change remote server'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email address'),
      'person@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'draft',
    );
    await tester.ensureVisible(find.text('Sign in'));
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.text('Sign in'));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('No remote server is configured.'), findsOneWidget);
    expect(find.byType(ServerSettingsSheet), findsNothing);
    await tester.ensureVisible(find.text('Open Remote Code'));
    await tester.longPress(find.text('Open Remote Code'));
    await tester.pumpAndSettle();
    expect(find.byType(ServerSettingsSheet), findsNothing);
  });

  testWidgets('debug app accepts and restores a local HTTP server', (
    tester,
  ) async {
    final repository = MemoryServerSettingsRepository();
    await tester.pumpWidget(testApp(serverSettingsRepository: repository));
    await tester.pumpAndSettle();
    await openSettings(tester);
    // Fresh debug installs already point at the local development server.
    expect(find.text('http://127.0.0.1:8080'), findsOneWidget);
    expect(repository.writes, 0);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server address'),
      'http://127.0.0.1:8080',
    );
    await tester.ensureVisible(find.text('Save server'));
    await tester.tap(find.text('Save server'));
    await tester.pumpAndSettle();
    expect(find.byType(ServerSettingsSheet), findsNothing);
    expect(repository.value, 'http://127.0.0.1:8080');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(testApp(serverSettingsRepository: repository));
    await tester.pumpAndSettle();
    expect(find.text('http://127.0.0.1:8080'), findsNothing);
    await openSettings(tester);
    expect(find.text('http://127.0.0.1:8080'), findsOneWidget);
  });

  Future<void> mount(
    WidgetTester tester,
    MemoryServerSettingsRepository repository,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(testApp(serverSettingsRepository: repository));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'sixth background tap opens a single editor; cancel keeps origin',
    (tester) async {
      final repository = MemoryServerSettingsRepository(
        value: 'https://old.example.com',
      );
      await mount(tester, repository);
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.text('Open Remote Code'));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(ServerSettingsSheet), findsNothing);
      await tester.tap(find.text('Open Remote Code'));
      await tester.pumpAndSettle();
      expect(find.byType(ServerSettingsSheet), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Server address'),
        'https://new.example.com',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repository.value, 'https://old.example.com');
      expect(repository.writes, 0);
      await tester.tap(find.text('Open Remote Code'));
      await tester.pumpAndSettle();
      expect(find.byType(ServerSettingsSheet), findsNothing);
    },
  );

  testWidgets('saving changes origin and clears login credentials', (
    tester,
  ) async {
    final repository = MemoryServerSettingsRepository(
      value: 'https://old.example.com',
    );
    await mount(tester, repository);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email address'),
      'person@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'local-draft',
    );
    await openSettings(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server address'),
      'https://new.example.com/',
    );
    await tester.tap(find.text('Save server'));
    await tester.pumpAndSettle();
    expect(find.byType(ServerSettingsSheet), findsNothing);
    expect(find.text('https://new.example.com'), findsNothing);
    expect(find.text('person@example.com'), findsNothing);
    expect(find.text('local-draft'), findsNothing);
    expect(repository.value, 'https://new.example.com');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(testApp(serverSettingsRepository: repository));
    await tester.pumpAndSettle();
    expect(find.text('https://new.example.com'), findsNothing);
    await openSettings(tester);
    expect(find.text('https://new.example.com'), findsOneWidget);
  });

  testWidgets(
    'invalid URLs stay in the editor and a failed save is recoverable',
    (tester) async {
      final repository = MemoryServerSettingsRepository()..failWrite = true;
      await mount(tester, repository);
      await openSettings(tester);
      final field = find.widgetWithText(TextFormField, 'Server address');
      await tester.enterText(field, 'http://unsafe.example.com');
      await tester.tap(find.text('Save server'));
      await tester.pumpAndSettle();
      expect(repository.writes, 0);
      expect(find.textContaining('Use a valid HTTPS'), findsOneWidget);
      await tester.enterText(field, 'https://remote.example.com');
      await tester.tap(find.text('Save server'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not save the server. Please try again.'),
        findsOneWidget,
      );
      expect(find.byType(ServerSettingsSheet), findsOneWidget);
      repository.failWrite = false;
      await tester.tap(find.text('Save server'));
      await tester.pumpAndSettle();
      expect(find.byType(ServerSettingsSheet), findsNothing);
    },
  );

  testWidgets('form validates, authenticates, and opens Connections', (
    tester,
  ) async {
    await mount(
      tester,
      MemoryServerSettingsRepository(value: 'https://remote.example.com'),
    );
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email address'),
      'person@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'draft',
    );
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(find.byTooltip('Hide password'), findsOneWidget);
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceScreen), findsOneWidget);
    expect(find.byType(LoginHeader), findsNothing);
    expect(find.text('draft'), findsNothing);
    expect(
      Navigator.of(tester.element(find.byType(WorkspaceScreen))).canPop(),
      isFalse,
    );
  });

  testWidgets('credential fields are offered to platform password managers', (
    tester,
  ) async {
    await mount(
      tester,
      MemoryServerSettingsRepository(value: 'https://remote.example.com'),
    );
    final group = find.ancestor(
      of: find.widgetWithText(TextFormField, 'Email address'),
      matching: find.byType(AutofillGroup),
    );
    expect(group, findsOneWidget);
    // Cancelling on teardown stops an abandoned form becoming a save prompt.
    expect(
      tester.widget<AutofillGroup>(group).onDisposeAction,
      AutofillContextAction.cancel,
    );
    List<String>? hintsOf(String label) => tester
        .widget<TextField>(
          find.descendant(
            of: find.widgetWithText(TextFormField, label),
            matching: find.byType(TextField),
          ),
        )
        .autofillHints
        ?.toList();
    // Username leads: iOS maps only the first hint, and it is the one that pairs
    // this field with the password.
    expect(hintsOf('Email address'), [
      AutofillHints.username,
      AutofillHints.email,
    ]);
    expect(hintsOf('Password'), [AutofillHints.password]);
  });

  testWidgets('small screens, large text, and keyboard remain scrollable', (
    tester,
  ) async {
    await mount(tester, MemoryServerSettingsRepository());
    tester.view.physicalSize = const Size(320, 568);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await openSettings(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save server'));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(ServerSettingsSheet), findsNothing);
  });

  testWidgets('controls meet accessibility label and target guidelines', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await mount(tester, MemoryServerSettingsRepository());
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await openSettings(tester);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });
}
