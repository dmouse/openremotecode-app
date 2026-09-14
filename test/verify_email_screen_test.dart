import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/app.dart';
import 'package:openremotecode/features/login/ui/login_screen.dart';
import 'package:openremotecode/features/verify_email/ui/verify_email_screen.dart';
import 'package:openremotecode/features/verify_email/verify_email_view_model.dart';
import 'package:openremotecode/features/workspace/ui/workspace_screen.dart';

import 'support/auth_fakes.dart';
import 'support/connections_fakes.dart';
import 'support/memory_server_settings_repository.dart';

void main() {
  /// Reaches the verification screen the way a user does: by registering.
  Future<FakeRemoteApi> pumpVerification(WidgetTester tester) async {
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
    final create = find.text("Don't have an account? Create one");
    await tester.ensureVisible(create);
    await tester.tap(create);
    await tester.pumpAndSettle();
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
    expect(find.byType(VerifyEmailScreen), findsOne);
    api.calls.clear();
    return api;
  }

  Future<void> enterCode(WidgetTester tester, String code) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Verification code'),
      code,
    );
    await tester.ensureVisible(find.text('Verify and continue'));
    await tester.tap(find.text('Verify and continue'));
    await tester.pumpAndSettle();
  }

  testWidgets('the copy does not confirm that an account was created', (
    tester,
  ) async {
    await pumpVerification(tester);
    // Registration answers an already-registered address identically, so the
    // screen must not state that a code was definitely sent.
    expect(
      find.textContaining('If person@example.com is not already registered'),
      findsOne,
    );
    // And it offers the way out for someone who already had an account.
    expect(find.text('Already have an account? Sign in'), findsOne);
  });

  testWidgets('the field accepts only six digits', (tester) async {
    final api = await pumpVerification(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Verification code'),
      'abc123def456',
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(TextFormField),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller!.text, '123456');

    // A short code is rejected before any request is made.
    await enterCode(tester, '123');
    expect(find.text('The code is six digits.'), findsOne);
    expect(api.calls, isEmpty);
  });

  testWidgets('the right code verifies and enters the workspace', (
    tester,
  ) async {
    final api = await pumpVerification(tester);
    await enterCode(tester, api.correctVerificationCode);

    expect(api.calls.first.path, '/v1/auth/verify-email');
    expect(find.byType(WorkspaceScreen), findsOne);
    expect(find.byType(VerifyEmailScreen), findsNothing);
  });

  testWidgets('a wrong code keeps the user on the screen with an error', (
    tester,
  ) async {
    final api = await pumpVerification(tester);
    await enterCode(tester, '000000');

    expect(find.byType(VerifyEmailScreen), findsOne);
    expect(find.textContaining('incorrect or has expired'), findsOne);
    // The right code still works afterwards.
    await enterCode(tester, api.correctVerificationCode);
    expect(find.byType(WorkspaceScreen), findsOne);
  });

  testWidgets('resend is held back by the client cooldown, then works', (
    tester,
  ) async {
    final api = await pumpVerification(tester);
    // A code was just sent to get here, so resend starts disabled.
    expect(
      tester
          .widget<TextButton>(
            find.ancestor(
              of: find.textContaining('Send a new code in'),
              matching: find.byType(TextButton),
            ),
          )
          .onPressed,
      isNull,
    );

    await tester.pump(VerifyEmailViewModel.resendCooldown);
    await tester.pumpAndSettle();
    final resend = find.text('Send a new code');
    expect(resend, findsOne);
    await tester.ensureVisible(resend);
    await tester.tap(resend);
    await tester.pumpAndSettle();

    expect(api.calls.single.path, '/v1/auth/resend-verification');
    expect(find.byType(VerifyEmailScreen), findsOne);
    // The rotated code is the one that now works.
    await enterCode(tester, api.correctVerificationCode);
    expect(find.byType(WorkspaceScreen), findsOne);
  });

  testWidgets('signing out of verification returns to the login screen', (
    tester,
  ) async {
    final api = await pumpVerification(tester);
    final back = find.text('Already have an account? Sign in');
    await tester.ensureVisible(back);
    await tester.tap(back);
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOne);
    expect(find.byType(VerifyEmailScreen), findsNothing);
    // Cancelling is local: it must not call the server.
    expect(api.calls, isEmpty);
  });

  testWidgets('signing in to a still-pending account reopens verification', (
    tester,
  ) async {
    final api = FakeRemoteApi()..accountPending = true;
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

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email address'),
      'person@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'a long enough password',
    );
    await tester.ensureVisible(find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    // Not an error screen and not the workspace: the code entry, with no
    // credentials issued.
    expect(find.byType(VerifyEmailScreen), findsOne);
    expect(auth.session, isNull);
  });
}
