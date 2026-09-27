import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/auth/auth_repository.dart';
import 'package:openremotecode/features/connections/data/device_identity.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/platform/google_identity.dart';
import 'package:openremotecode/platform/remote_api.dart';

import 'support/auth_fakes.dart';

void main() {
  final server = ServerEndpoint.parse('https://remote.example.com');
  late MemorySecureStore store;
  late FakeRemoteApi api;
  late FakeGoogleIdentityProvider google;
  late AuthRepository auth;

  setUp(() async {
    store = MemorySecureStore();
    api = FakeRemoteApi();
    google = FakeGoogleIdentityProvider();
    auth = AuthRepository(api: api, store: store, google: google);
    await auth.login(server, 'person@example.com', 'password');
  });
  tearDown(() => auth.dispose());

  test('deleting with the password removes every local secret', () async {
    final scope = auth.session!.scope;
    final accessToken = auth.session!.accessToken;
    store.values[DeviceIdentityStore.keyFor(scope)] = '{"device":"key"}';
    store.values['unrelated'] = 'kept';

    expect(await auth.deleteAccount(password: 'private-password'), isTrue);

    final call = api.calls.last;
    expect(call.path, '/v1/account/delete');
    expect(call.body, {'password': 'private-password'});
    expect(call.token, accessToken);
    expect(auth.session, isNull);
    expect(auth.error, isNull);
    expect(store.values.keys, ['unrelated']);
    expect(google.signOuts, 1);
  });

  test('a wrong password keeps the session and says why', () async {
    expect(await auth.deleteAccount(password: 'incorrect'), isFalse);
    expect(auth.session, isNotNull);
    expect(auth.deletionError, 'That password is incorrect.');
    expect(auth.error, isNull);
    expect(store.values, isNotEmpty);
    expect(auth.isBusy, isFalse);
  });

  test('an ended session signs out rather than retrying', () async {
    api.failure = const ApiException(401, 'unauthorized');
    expect(await auth.deleteAccount(password: 'private-password'), isFalse);
    expect(auth.session, isNull);
    expect(auth.isBusy, isFalse);
  });

  test(
    'Google confirmation sends the assertion, and cancelling sends nothing',
    () async {
      google.result = const GoogleIdentityCancelled();
      final before = api.calls.length;
      expect(await auth.deleteAccount(), isFalse);
      expect(api.calls.length, before);
      expect(auth.deletionError, isNull);
      expect(auth.session, isNotNull);

      google.result = const GoogleIdentityToken('another.google.account');
      expect(await auth.deleteAccount(), isFalse);
      expect(
        auth.deletionError,
        'That Google account is not the one linked to this account.',
      );

      google.result = const GoogleIdentityToken('header.payload.signature');
      expect(await auth.deleteAccount(), isTrue);
      expect(api.calls.last.body, {'idToken': 'header.payload.signature'});
      expect(auth.session, isNull);
    },
  );
}
