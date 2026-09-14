import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/auth/auth_repository.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/platform/remote_api.dart';

import 'support/auth_fakes.dart';

void main() {
  final server = ServerEndpoint.parse('https://remote.example.com');
  late MemorySecureStore store;
  late FakeRemoteApi api;
  late AuthRepository auth;
  setUp(() {
    store = MemorySecureStore();
    api = FakeRemoteApi();
    auth = AuthRepository(api: api, store: store);
  });
  tearDown(() => auth.dispose());

  test(
    'successful login securely persists only refresh and binding metadata',
    () async {
      expect(
        await auth.login(server, 'person@example.com', 'private-password'),
        isTrue,
      );
      final record = jsonDecode(store.values.values.single) as Map;
      expect(record['origin'], server.toString());
      expect(record['accountId'], auth.session!.accountId);
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
      expect(store.values.values.single.contains('private-password'), isFalse);
      expect(
        store.values.values.single.contains(auth.session!.accessToken),
        isFalse,
      );
    },
  );

  test(
    'cold restoration rotates refresh credentials before admitting session',
    () async {
      await auth.login(server, 'person@example.com', 'password');
      final old = store.values.values.single;
      final restored = AuthRepository(api: api, store: store);
      addTearDown(restored.dispose);
      await restored.restore(server);
      expect(restored.session!.accountId, auth.session!.accountId);
      expect(api.rotations, 1);
      expect(store.values.values.single, isNot(old));
    },
  );

  test(
    'another server cannot read or send a saved refresh credential',
    () async {
      await auth.login(server, 'person@example.com', 'password');
      final restored = AuthRepository(api: api, store: store);
      addTearDown(restored.dispose);
      await restored.restore(ServerEndpoint.parse('https://other.example.com'));
      expect(restored.session, isNull);
      expect(api.calls.length, 1);
    },
  );

  test(
    'restore rejects changed account identity and deletes saved session',
    () async {
      await auth.login(server, 'person@example.com', 'password');
      api.accountId = 'usr_other_account';
      final restored = AuthRepository(api: api, store: store);
      addTearDown(restored.dispose);
      await restored.restore(server);
      expect(restored.session, isNull);
      expect(store.values, isEmpty);
    },
  );

  test(
    'bad passwords and storage failures cannot open an authenticated session',
    () async {
      expect(
        await auth.login(server, 'person@example.com', 'incorrect'),
        isFalse,
      );
      expect(store.values, isEmpty);
      store.failWrite = true;
      expect(
        await auth.login(server, 'person@example.com', 'correct'),
        isFalse,
      );
      expect(auth.session, isNull);
      expect(api.calls.last.path, '/v1/auth/logout');
      expect(auth.error, contains('secure device storage'));
    },
  );

  test('concurrent login submissions are ignored', () async {
    api.gate = Completer<void>();
    final first = auth.login(server, 'person@example.com', 'password');
    expect(await auth.login(server, 'person@example.com', 'password'), isFalse);
    api.gate!.complete();
    expect(await first, isTrue);
    expect(api.calls.length, 1);
  });

  test(
    'concurrent refreshes rotate once and logout revokes the newest token',
    () async {
      await auth.login(server, 'person@example.com', 'password');
      api.gate = Completer<void>();
      final first = auth.refreshIfNeeded(force: true);
      final second = auth.refreshIfNeeded(force: true);
      api.gate!.complete();
      await Future.wait([first, second]);
      expect(api.rotations, 1);
      expect(await auth.logout(), isTrue);
      expect(api.calls.last.cookie, endsWith('_1'));
      expect(store.values, isEmpty);
      expect(auth.session, isNull);
    },
  );

  test('expired access triggers refresh before protected operations', () async {
    api.accessLifetime = const Duration(seconds: 10);
    await auth.login(server, 'person@example.com', 'password');
    api.accessLifetime = const Duration(minutes: 10);
    await auth.request('/v1/connectors');
    expect(api.rotations, 1);
    expect(api.calls.last.token, endsWith('_1'));
  });

  test(
    'failed rotation persistence closes the gate even when deletion fails',
    () async {
      await auth.login(server, 'person@example.com', 'password');
      store.failWrite = true;
      store.failDelete = true;
      await expectLater(
        auth.refreshIfNeeded(force: true),
        throwsA(isA<ApiException>()),
      );
      expect(auth.session, isNull);
      expect(auth.error, contains('secure device storage'));
      expect(api.calls.last.path, '/v1/auth/logout');
    },
  );

  test(
    'offline restoration retains refresh for retry without admitting user',
    () async {
      await auth.login(server, 'person@example.com', 'password');
      api.failure = const ApiException(0, 'network');
      final restored = AuthRepository(api: api, store: store);
      addTearDown(restored.dispose);
      await restored.restore(server);
      expect(restored.session, isNull);
      expect(store.values, isNotEmpty);
      api.failure = null;
      await restored.restore(server);
      expect(restored.session, isNotNull);
    },
  );

  test('revoked session fails closed on a protected request', () async {
    await auth.login(server, 'person@example.com', 'password');
    api.failure = const ApiException(401, 'unauthorized');
    await expectLater(
      auth.request('/v1/connectors'),
      throwsA(isA<ApiException>()),
    );
    expect(auth.session, isNull);
    expect(store.values, isEmpty);
  });

  test('logout deletion failure is reported; offline logout still clears local data', () async {
    await auth.login(server, 'person@example.com', 'password');
    store.failDelete = true;
    expect(await auth.logout(), isFalse);
    expect(auth.session, isNotNull);
    store.failDelete = false;
    api.failure = const ApiException(0, 'network');
    expect(await auth.logout(), isTrue);
    expect(auth.session, isNull);
    expect(store.values, isEmpty);
    expect(auth.error, contains('Signed out on this device'));
  });

  test(
    'registration yields a pending challenge and no session or stored secret',
    () async {
      expect(
        await auth.register(
          server,
          'person@example.com',
          'a long enough password',
        ),
        isTrue,
      );
      expect(auth.session, isNull);
      expect(auth.pendingVerification, isNotNull);
      expect(auth.pendingVerification!.email, 'person@example.com');
      expect(auth.pendingVerification!.ticket, api.verificationTicket);
      // The ticket is memory-only: nothing about it may reach secure storage.
      expect(store.values, isEmpty);
    },
  );

  test(
    'signing in to a pending account returns a challenge rather than a session',
    () async {
      api.accountPending = true;
      expect(
        await auth.login(
          server,
          'person@example.com',
          'a long enough password',
        ),
        isFalse,
      );
      expect(auth.session, isNull);
      expect(auth.pendingVerification, isNotNull);
      expect(store.values, isEmpty);
      // A challenge is not a failure, so it must not surface as an error.
      expect(auth.error, isNull);
    },
  );

  test(
    'the right code activates the account and starts a real session',
    () async {
      await auth.register(
        server,
        'person@example.com',
        'a long enough password',
      );
      expect(
        await auth.submitVerificationCode(api.correctVerificationCode),
        isTrue,
      );
      expect(auth.pendingVerification, isNull);
      expect(auth.session, isNotNull);
      expect(auth.session!.accountId, api.accountId);
      // Only now is a refresh credential persisted.
      expect(store.values, isNotEmpty);
    },
  );

  test('a wrong code keeps the challenge and reports the failure', () async {
    await auth.register(server, 'person@example.com', 'a long enough password');
    final ticket = auth.pendingVerification!.ticket;
    expect(await auth.submitVerificationCode('000000'), isFalse);
    expect(auth.session, isNull);
    expect(auth.pendingVerification!.ticket, ticket);
    expect(auth.error, contains('incorrect or has expired'));
    // The user can still succeed with the right code.
    expect(
      await auth.submitVerificationCode(api.correctVerificationCode),
      isTrue,
    );
    expect(auth.session, isNotNull);
  });

  test('resending replaces the held challenge with the rotated one', () async {
    await auth.register(server, 'person@example.com', 'a long enough password');
    final original = auth.pendingVerification!.ticket;
    expect(await auth.resendVerificationCode(), isTrue);
    final rotated = auth.pendingVerification!.ticket;
    expect(rotated, isNot(original));
    expect(auth.session, isNull);
    // The superseded ticket is dead; the rotated one works.
    expect(
      await auth.submitVerificationCode(api.correctVerificationCode),
      isTrue,
    );
    expect(auth.session, isNotNull);
  });

  test(
    'cancelling verification clears local state without a request',
    () async {
      await auth.register(
        server,
        'person@example.com',
        'a long enough password',
      );
      final callsBefore = api.calls.length;
      auth.cancelVerification();
      expect(auth.pendingVerification, isNull);
      expect(auth.session, isNull);
      expect(api.calls.length, callsBefore);
    },
  );

  test(
    'verification commands are inert without an outstanding challenge',
    () async {
      expect(await auth.submitVerificationCode('123456'), isFalse);
      expect(await auth.resendVerificationCode(), isFalse);
      expect(api.calls, isEmpty);
    },
  );
}
