import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/auth/auth_repository.dart';
import 'package:openremotecode/features/connections/data/api_connections_repository.dart';
import 'package:openremotecode/features/connections/data/device_identity.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/platform/remote_api.dart';

import 'support/auth_fakes.dart';

const _cookieName = '__Host-opencode_remote_device';
const _current = '$_cookieName=ord_current';
const _issued = 'ord_replacement';

void main() {
  Future<(ApiConnectionsRepository, DeviceIdentityStore, _RotationApi)> setUp({
    required Duration remaining,
    Map<String, dynamic> pending = const {},
    Object? activateFailure,
    Object? rotateFailure,
  }) async {
    final api = _RotationApi()
      ..activateFailure = activateFailure
      ..rotateFailure = rotateFailure;
    final store = MemorySecureStore();
    final auth = AuthRepository(api: api, store: store);
    addTearDown(auth.dispose);
    await auth.login(
      ServerEndpoint.parse('https://remote.example.test'),
      'person@example.com',
      'password',
    );
    final identities = DeviceIdentityStore(store, auth.session!.scope);
    final record = await identities.loadOrCreate();
    await identities.save({
      ...record,
      'deviceId': 'dev_a',
      'deviceCookie': _current,
      'deviceExpiresAt': DateTime.now()
          .toUtc()
          .add(remaining)
          .toIso8601String(),
      ...pending,
    });
    final repository = ApiConnectionsRepository(auth);
    addTearDown(repository.dispose);
    return (repository, identities, api);
  }

  Future<Map<String, dynamic>> settle(
    ApiConnectionsRepository repository,
    DeviceIdentityStore identities,
  ) async {
    repository.maintainDeviceCredential();
    for (var attempt = 0; attempt < 40; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return identities.loadOrCreate();
  }

  test('a credential outside its final third is left alone', () async {
    final (repository, identities, api) = await setUp(
      remaining: const Duration(days: 300),
    );
    final record = await settle(repository, identities);

    expect(api.rotations, 0, reason: 'renewal ran too early');
    expect(record['deviceCookie'], _current);
  });

  test('renewal persists the replacement before activating it', () async {
    final (repository, identities, api) = await setUp(
      remaining: const Duration(days: 30),
    );
    final record = await settle(repository, identities);

    expect(api.rotations, 1);
    // The staged write must land before activation, or a process death in between loses
    // the credential the server is about to commit.
    expect(
      api.pendingCookieWhenActivated,
      '$_cookieName=$_issued',
      reason: 'activation used a credential that was never persisted',
    );
    expect(record['deviceCookie'], '$_cookieName=$_issued');
    expect(record['pendingDeviceCookie'], isNull);
    expect(record['version'], 2);
  });

  test('a death between persisting and activating resolves on the next run', () async {
    // The previous run wrote the pending credential and then the app was killed.
    final (repository, identities, api) = await setUp(
      remaining: const Duration(days: 300),
      pending: {
        'pendingDeviceCookie': '$_cookieName=$_issued',
        'pendingActivateBy': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 10))
            .toIso8601String(),
      },
    );
    final record = await settle(repository, identities);

    // Pending is tried first: a rotation committed just before the kill leaves it as the
    // only working credential.
    expect(api.activations, 1);
    expect(api.rotations, 0, reason: 'settling should not also rotate');
    expect(record['deviceCookie'], '$_cookieName=$_issued');
    expect(record['pendingDeviceCookie'], isNull);
  });

  test('an unactivated rotation inside its deadline is kept, not discarded', () async {
    final (repository, identities, _) = await setUp(
      remaining: const Duration(days: 300),
      pending: {
        'pendingDeviceCookie': '$_cookieName=$_issued',
        'pendingActivateBy': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 5))
            .toIso8601String(),
      },
      activateFailure: const ApiException(0, 'network'),
    );
    final record = await settle(repository, identities);

    // The failure is ambiguous: the server may already have committed this credential, so
    // discarding it here is what would cause a lockout.
    expect(record['pendingDeviceCookie'], '$_cookieName=$_issued');
    expect(record['deviceCookie'], _current);
  });

  test('a pending credential is dropped once its own deadline has passed', () async {
    final (repository, identities, _) = await setUp(
      remaining: const Duration(days: 300),
      pending: {
        'pendingDeviceCookie': '$_cookieName=$_issued',
        'pendingActivateBy': DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
      },
      activateFailure: const ApiException(401, 'unauthorized'),
    );
    final record = await settle(repository, identities);

    expect(record['pendingDeviceCookie'], isNull);
    expect(
      record['deviceCookie'],
      _current,
      reason: 'dropping a lapsed rotation disturbed the live credential',
    );
  });

  test('a failed rotation leaves a usable credential and no half-written state', () async {
    final (repository, identities, _) = await setUp(
      remaining: const Duration(days: 30),
      rotateFailure: const ApiException(503, 'unavailable'),
    );
    final record = await settle(repository, identities);

    expect(record['deviceCookie'], _current);
    expect(record['pendingDeviceCookie'], isNull);
  });

  test('an already expired credential is not rotated', () async {
    final (repository, identities, api) = await setUp(
      remaining: const Duration(days: -1),
    );
    await settle(repository, identities);

    expect(api.rotations, 0, reason: 'an expired credential was used to rotate');
  });
}

// FakeRemoteApi is final, so the rotation routes are intercepted here and everything else
// delegates to it.
final class _RotationApi implements RemoteApi {
  final _inner = FakeRemoteApi();
  int rotations = 0;
  int activations = 0;
  String? pendingCookieWhenActivated;
  Object? rotateFailure;
  Object? activateFailure;

  @override
  Future<ApiResponse> request(
    ServerEndpoint server,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? accessToken,
    String? cookie,
  }) async {
    if (path == '/v1/devices/self/rotate') {
      rotations++;
      if (rotateFailure case final error?) throw error;
      return ApiResponse({
        'credential': _issued,
        'activateBy': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 15))
            .toIso8601String(),
      });
    }
    if (path == '/v1/devices/self/rotate/activate') {
      activations++;
      pendingCookieWhenActivated = cookie;
      if (activateFailure case final error?) throw error;
      return ApiResponse({
        'credentialExpiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(days: 365))
            .toIso8601String(),
      });
    }
    return _inner.request(
      server,
      path,
      method: method,
      body: body,
      accessToken: accessToken,
      cookie: cookie,
    );
  }
}
