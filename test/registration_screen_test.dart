import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/app.dart';
import 'package:openremotecode/features/login/ui/login_screen.dart';
import 'package:openremotecode/features/registration/ui/registration_screen.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/features/verify_email/ui/verify_email_screen.dart';
import 'package:openremotecode/features/workspace/ui/workspace_screen.dart';

import 'support/auth_fakes.dart';
import 'support/connections_fakes.dart';
import 'support/memory_server_settings_repository.dart';

void main() {
  Future<FakeRemoteApi> pumpApp(WidgetTester tester) async {
    final api = FakeRemoteApi();
    final auth = fakeAuth(api: api);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MainApp(
        serverSettingsRepository: MemoryServerSettingsRepository(
          value: 'https://remote.example.com',
        ),
        authRepository: auth,
        connectionsRepositoryFactory: (_) => FakeConnectionsRepository(),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  Future<void> openRegistration(WidgetTester tester) async {
    final link = find.text("Don't have an account? Create one");
    await tester.ensureVisible(link);
    await tester.tap(link);
    await tester.pumpAndSettle();
  }

  testWidgets('the login screen offers registration and can return from it', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.byType(LoginScreen), findsOne);

    await openRegistration(tester);
    expect(find.byType(RegistrationScreen), findsOne);
    expect(find.byType(LoginScreen), findsNothing);

    final back = find.text('Already have an account? Sign in');
    await tester.ensureVisible(back);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOne);
  });

  testWidgets(
    'the form rejects a short password and a mismatched confirmation',
    (tester) async {
      final api = await pumpApp(tester);
      await openRegistration(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email address'),
        'person@example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'short',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'),
        'short',
      );
      await tester.ensureVisible(find.text('Create account'));
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();

      expect(find.text('Use at least 12 characters.'), findsOne);
      // Nothing may reach the server until the client-side rules pass.
      expect(api.calls, isEmpty);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'a long enough password',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'),
        'a different password',
      );
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();

      expect(find.text('Passwords do not match.'), findsOne);
      expect(api.calls, isEmpty);
    },
  );

  testWidgets('registering lands on the verification screen', (tester) async {
    final api = await pumpApp(tester);
    await openRegistration(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email address'),
      'person@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'a long enough password',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Confirm password'),
      'a long enough password',
    );
    await tester.ensureVisible(find.text('Create account'));
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(api.calls.single.path, '/v1/auth/register');
    expect(find.byType(VerifyEmailScreen), findsOne);
    expect(find.byType(RegistrationScreen), findsNothing);
  });

  testWidgets('signing out returns to sign-in, not the registration form', (
    tester,
  ) async {
    final api = FakeRemoteApi();
    final auth = fakeAuth(api: api);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MainApp(
        serverSettingsRepository: MemoryServerSettingsRepository(
          value: 'https://remote.example.com',
        ),
        authRepository: auth,
        connectionsRepositoryFactory: (_) => FakeConnectionsRepository(),
      ),
    );
    await tester.pumpAndSettle();

    // Open registration, then go back and sign in normally, so the flag is set.
    await openRegistration(tester);
    final back = find.text('Already have an account? Sign in');
    await tester.ensureVisible(back);
    await tester.tap(back);
    await tester.pumpAndSettle();
    await auth.login(
      ServerEndpoint.parse('https://remote.example.com'),
      'person@example.com',
      'a long enough password',
    );
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceScreen), findsOne);

    await auth.logout();
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOne);
    expect(find.byType(RegistrationScreen), findsNothing);
  });

  testWidgets('the entered password never appears in the request twice over', (
    tester,
  ) async {
    final api = await pumpApp(tester);
    await openRegistration(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email address'),
      '  Person@Example.com  ',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'a long enough password',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Confirm password'),
      'a long enough password',
    );
    await tester.ensureVisible(find.text('Create account'));
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    final body = api.calls.single.body!;
    // The address is trimmed client-side; the confirmation field is local only.
    expect(body['email'], 'Person@Example.com');
    expect(body.containsKey('confirmPassword'), isFalse);
    expect(body['clientName'], 'Open Remote Code Mobile');
  });

  testWidgets('the new credential is offered to platform password managers', (
    tester,
  ) async {
    await pumpApp(tester);
    await openRegistration(tester);

    final group = find.ancestor(
      of: find.widgetWithText(TextFormField, 'Email address'),
      matching: find.byType(AutofillGroup),
    );
    expect(group, findsOne);
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
    // Username leads: iOS maps only the first hint, and it is the one that keeps
    // this field in the same password context as the two below.
    expect(hintsOf('Email address'), [
      AutofillHints.username,
      AutofillHints.email,
    ]);
    // newPassword on both, so managers offer to generate rather than to fill an
    // existing credential, and can populate the confirmation too.
    expect(hintsOf('Password'), [AutofillHints.newPassword]);
    expect(hintsOf('Confirm password'), [AutofillHints.newPassword]);
  });
}
