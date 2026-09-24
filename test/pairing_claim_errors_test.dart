import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/auth/auth_repository.dart';
import 'package:openremotecode/features/connections/data/api_connections_repository.dart';
import 'package:openremotecode/features/connections/data/connections_repository.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/platform/remote_api.dart';

import 'support/auth_fakes.dart';

void main() {
  Future<(ApiConnectionsRepository, AuthRepository)> setUp(
    ApiException claimFailure,
  ) async {
    final api = _ClaimApi(claimFailure);
    final auth = AuthRepository(api: api, store: MemorySecureStore());
    addTearDown(auth.dispose);
    await auth.login(
      ServerEndpoint.parse('https://remote.example.test'),
      'person@example.com',
      'password',
    );
    final repository = ApiConnectionsRepository(auth);
    addTearDown(repository.dispose);
    return (repository, auth);
  }

  // The server used to answer a mistyped code with 401, which the auth layer treats as a
  // lost session: a typo signed the user out.
  test('a wrong code is reported as not found and keeps the session', () async {
    final (repository, auth) = await setUp(
      const ApiException(404, 'invalid_code'),
    );
    await expectLater(
      repository.reviewPairing('ZZZZ-ZZZZ'),
      throwsA(ConnectionFailure.invalidCode),
    );
    expect(
      auth.session,
      isNotNull,
      reason: 'a typo must not sign the user out',
    );
  });

  test('too many incorrect codes asks the user to wait', () async {
    final (repository, auth) = await setUp(
      const ApiException(429, 'too_many_attempts'),
    );
    await expectLater(
      repository.reviewPairing('ZZZZ-ZZZZ'),
      throwsA(ConnectionFailure.tooManyAttempts),
    );
    expect(auth.session, isNotNull);
    expect(ConnectionFailure.tooManyAttempts.message, contains('Wait'));
  });
}

final class _ClaimApi implements RemoteApi {
  _ClaimApi(this.claimFailure);

  final ApiException claimFailure;
  final _inner = FakeRemoteApi();

  @override
  Future<ApiResponse> request(
    ServerEndpoint server,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? accessToken,
    String? cookie,
  }) async {
    if (path == '/v1/devices/challenge') {
      return ApiResponse({
        'challenge': 'A' * 43,
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 2))
            .toIso8601String(),
      });
    }
    if (path == '/v1/connector-pairings/claim') throw claimFailure;
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
