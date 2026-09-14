import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/auth/auth_repository.dart';
import 'package:openremotecode/features/connections/data/api_connections_repository.dart';
import 'package:openremotecode/features/connections/data/device_identity.dart';
import 'package:openremotecode/features/connections/domain/remote_connection.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/platform/remote_api.dart';

import 'support/auth_fakes.dart';

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/pairing_v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final transcript = requiredMap(fixture, 'transcript');
  final original = requiredMap(transcript, 'connectorIdentity');
  final changed = requiredMap(transcript, 'deviceIdentity');

  for (final scenario in ['unpaired', 'verified', 'changed']) {
    test(
      'existing connector is classified correctly when $scenario on this device',
      () async {
        final api = _InventoryApi(original);
        final store = MemorySecureStore();
        final auth = AuthRepository(api: api, store: store);
        addTearDown(auth.dispose);
        await auth.login(
          ServerEndpoint.parse('https://remote.example.test'),
          'person@example.com',
          'password',
        );
        final identityStore = DeviceIdentityStore(store, auth.session!.scope);
        final record = await identityStore.loadOrCreate();
        if (scenario != 'unpaired') {
          await identityStore.save({
            ...record,
            'bindings': {
              'con_existing': {
                'identity': original,
                'deviceId': 'dev_existing',
              },
            },
          });
        }
        if (scenario == 'changed') api.identity = changed;
        final before = Map<String, String>.from(store.values);
        final repository = ApiConnectionsRepository(auth);
        addTearDown(repository.dispose);
        final connection = (await repository.listConnections()).single;
        expect(connection.status, switch (scenario) {
          'unpaired' => ConnectionStatus.verificationRequired,
          'changed' => ConnectionStatus.identityChanged,
          _ => ConnectionStatus.unknown,
        });
        expect(
          store.values,
          before,
          reason: 'Listing cannot create or replace trust',
        );
        if (scenario == 'unpaired') {
          expect(
            connection.verificationMessage,
            contains('another browser or device'),
          );
        }
        if (scenario == 'changed') {
          expect(connection.verificationMessage, contains('no longer matches'));
        }
      },
    );
  }
}

final class _InventoryApi implements RemoteApi {
  _InventoryApi(this.identity);
  Map<String, dynamic> identity;
  final auth = FakeRemoteApi();
  @override
  Future<ApiResponse> request(
    ServerEndpoint server,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? accessToken,
    String? cookie,
  }) async {
    if (path == '/v1/connectors') {
      return ApiResponse({
        'connectors': [
          {
            'id': 'con_existing',
            'name': 'Existing laptop',
            'identity': identity,
          },
        ],
      });
    }
    return auth.request(
      server,
      path,
      method: method,
      body: body,
      accessToken: accessToken,
      cookie: cookie,
    );
  }
}
