import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/app.dart';
import 'package:openremotecode/features/auth/auth_repository.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/platform/google_identity.dart';
import 'package:openremotecode/features/workspace/ui/workspace_screen.dart';
import 'package:openremotecode/platform/remote_api.dart';

import 'support/auth_fakes.dart';
import 'support/connections_fakes.dart';
import 'support/memory_server_settings_repository.dart';

void main() {
  final server = ServerEndpoint.parse('https://remote.example.com');
  late MemorySecureStore store;
  late FakeRemoteApi api;
  late FakeGoogleIdentityProvider google;
  late AuthRepository auth;

  setUp(() {
    store = MemorySecureStore();
    api = FakeRemoteApi();
    google = FakeGoogleIdentityProvider();
    auth = AuthRepository(api: api, store: store, google: google);
  });
  tearDown(() => auth.dispose());

  test('google sign-in establishes a session and persists only the refresh credential', () async {
    expect(await auth.signInWithGoogle(server), isTrue);

    expect(auth.session, isNotNull);
    expect(auth.error, isNull);
    final call = api.calls.single;
    expect(call.path, '/v1/auth/google');
    expect(call.body?['idToken'], 'header.payload.signature');
    expect(call.body?['clientName'], 'Open Remote Code Mobile');

    // The assertion is a credential in its own right and must not outlive the
    // request, and the federated path must store exactly what login stores.
    final record = jsonDecode(store.values.values.single) as Map;
    expect(
      record.keys,
      unorderedEquals([
        'version',
        'origin',
        'accountId',
        'cookie',
        'expiresAt',
      ]),
    );
    expect(
      store.values.values.single.contains('header.payload.signature'),
      isFalse,
    );
  });

  test('a google session refreshes through the same rotation as a password session', () async {
    await auth.signInWithGoogle(server);
    final restored = AuthRepository(api: api, store: store, google: google);
    addTearDown(restored.dispose);

    await restored.restore(server);

    expect(restored.session!.accountId, auth.session!.accountId);
    expect(api.rotations, 1);
  });

  test('google sign-in never yields a verification challenge', () async {
    // Even against a server that would answer a password sign-in with one.
    api.accountPending = true;

    expect(await auth.signInWithGoogle(server), isTrue);

    expect(auth.pendingVerification, isNull);
    expect(auth.session, isNotNull);
  });

  test('cancelling google sign-in reports no error', () async {
    google.result = const GoogleIdentityCancelled();

    expect(await auth.signInWithGoogle(server), isFalse);

    expect(auth.session, isNull);
    // Closing the account chooser is a normal thing to do; an error banner would
    // read as a failure the user did not cause.
    expect(auth.error, isNull);
    expect(api.calls, isEmpty);
  });

  test('a platform failure is reported and never reaches the server', () async {
    google.result = const GoogleIdentityFailure('Google is unavailable.');

    expect(await auth.signInWithGoogle(server), isFalse);

    expect(auth.error, 'Google is unavailable.');
    expect(api.calls, isEmpty);
  });

  test('a rejected assertion forgets the chosen account so a retry can pick another', () async {
    api.googleFailure = const ApiException(409, 'account_link_required');

    expect(await auth.signInWithGoogle(server), isFalse);

    expect(auth.session, isNull);
    expect(auth.error, contains('Sign in with your password'));
    expect(store.values, isEmpty);
    // Otherwise the next attempt would silently resubmit the same rejected
    // account, and the user could never reach the one the server would accept.
    expect(google.signOuts, 1);
  });

  test('a server without google sign-in says so', () async {
    api.googleFailure = const ApiException(503, 'google_signin_unavailable');

    expect(await auth.signInWithGoogle(server), isFalse);

    expect(auth.error, contains('does not offer Google sign-in'));
  });

  test('an unverifiable assertion is reported without leaking why', () async {
    api.googleFailure = const ApiException(401, 'invalid_google_token');

    expect(await auth.signInWithGoogle(server), isFalse);

    expect(
      auth.error,
      'Google sign-in could not be verified. Please try again.',
    );
  });

  test('a build without google configuration offers nothing to call', () async {
    final withoutGoogle = AuthRepository(api: api, store: store);
    addTearDown(withoutGoogle.dispose);

    expect(withoutGoogle.supportsGoogleSignIn, isFalse);
    expect(await withoutGoogle.signInWithGoogle(server), isFalse);
    expect(api.calls, isEmpty);
  });

  test('an unavailable platform is not offered', () {
    expect(
      AuthRepository(
        api: api,
        store: store,
        google: FakeGoogleIdentityProvider(isAvailable: false),
      ).supportsGoogleSignIn,
      isFalse,
    );
    expect(auth.supportsGoogleSignIn, isTrue);
  });

  test('google sign-in is refused while a session is already held', () async {
    await auth.signInWithGoogle(server);
    final calls = api.calls.length;

    expect(await auth.signInWithGoogle(server), isFalse);

    expect(api.calls.length, calls);
    expect(google.requests, 1);
  });

  test('signing out forgets the device google account', () async {
    await auth.signInWithGoogle(server);

    expect(await auth.logout(), isTrue);

    expect(auth.session, isNull);
    expect(store.values, isEmpty);
    expect(google.signOuts, 1);
  });

  uiTests();
}

/// UI coverage for the action itself: it appears only where it can work, and
/// tapping it reaches the repository rather than the password form.
void uiTests() {
  Future<FakeGoogleIdentityProvider> pumpLogin(
    WidgetTester tester, {
    bool available = true,
  }) async {
    final google = FakeGoogleIdentityProvider(isAvailable: available);
    final auth = fakeAuth(google: google);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MainApp(
        serverSettingsRepository: MemoryServerSettingsRepository(),
        authRepository: auth,
        connectionsRepositoryFactory: (_) => FakeConnectionsRepository(),
      ),
    );
    await tester.pumpAndSettle();
    return google;
  }

  testWidgets('the google action is offered on sign-in and signs in', (
    tester,
  ) async {
    final google = await pumpLogin(tester);

    expect(find.text('Continue with Google'), findsOneWidget);
    await tester.ensureVisible(find.text('Continue with Google'));
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();

    expect(google.requests, 1);
    // A completed sign-in lands in the workspace, exactly as a password one does.
    expect(find.byType(WorkspaceScreen), findsOneWidget);
  });

  testWidgets('an empty sign-in form does not block the google action', (
    tester,
  ) async {
    final google = await pumpLogin(tester);

    await tester.ensureVisible(find.text('Continue with Google'));
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();

    // The password validators must not have run: they belong to a different path.
    expect(find.text('Enter your email address.'), findsNothing);
    expect(find.text('Enter your password.'), findsNothing);
    expect(google.requests, 1);
  });

  testWidgets('a build without google support offers no google action', (
    tester,
  ) async {
    await pumpLogin(tester, available: false);

    expect(find.text('Continue with Google'), findsNothing);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('the google action is offered on the create-account screen too', (
    tester,
  ) async {
    final google = await pumpLogin(tester);
    await tester.ensureVisible(find.text("Don't have an account? Create one"));
    await tester.tap(find.text("Don't have an account? Create one"));
    await tester.pumpAndSettle();

    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    await tester.ensureVisible(find.text('Continue with Google'));
    await tester.tap(find.text('Continue with Google'));
    await tester.pumpAndSettle();

    // Creating an account with Google produces a session directly, never the
    // verification screen the mailed-code flow goes through.
    expect(google.requests, 1);
    expect(find.text('Check your email'), findsNothing);
    expect(find.byType(WorkspaceScreen), findsOneWidget);
  });
}
