import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/platform/remote_api.dart';

void main() {
  test('HTTP adapter surfaces safe errors without forwarding credentials on redirect', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var redirected = false;
    server.listen((request) async {
      await request.drain<void>();
      if (request.uri.path == '/v1/auth/login') {
        request.response.statusCode = 401;
        request.response.write(
          jsonEncode({
            'code': 'invalid_credentials',
            'message': 'unsafe server text',
          }),
        );
      } else if (request.uri.path == '/v1/redirect') {
        request.response.statusCode = 307;
        request.response.headers.set('location', '/v1/destination');
      } else {
        redirected = true;
        request.response.write('{}');
      }
      await request.response.close();
    });
    final endpoint = ServerEndpoint.parse(
      'http://127.0.0.1:${server.port}',
      allowLoopbackHttp: true,
    );
    const api = HttpRemoteApi();
    await expectLater(
      api.request(
        endpoint,
        '/v1/auth/login',
        method: 'POST',
        body: {'password': 'test'},
      ),
      throwsA(
        isA<ApiException>().having(
          (e) => e.message,
          'message',
          'Email or password is incorrect.',
        ),
      ),
    );
    await expectLater(
      api.request(endpoint, '/v1/redirect', accessToken: 'test-token'),
      throwsA(isA<ApiException>()),
    );
    expect(redirected, isFalse);
    await expectLater(
      WebSocket.connect(
        'ws://127.0.0.1:${server.port}/v1/redirect',
        customClient: NoRedirectHttpClient(),
      ),
      throwsA(isA<WebSocketException>()),
    );
    expect(redirected, isFalse);
  });

  test('network response size is bounded', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write(jsonEncode({'oversized': 'x' * (256 * 1024)}));
      await request.response.close();
    });
    final endpoint = ServerEndpoint.parse(
      'http://127.0.0.1:${server.port}',
      allowLoopbackHttp: true,
    );
    await expectLater(
      const HttpRemoteApi().request(endpoint, '/v1/account'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'invalid_response'),
      ),
    );
  });

  test(
    'loopback HTTP network errors mention Android port forwarding',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close(force: true);
      final endpoint = ServerEndpoint.parse(
        'http://127.0.0.1:$port',
        allowLoopbackHttp: true,
      );
      await expectLater(
        const HttpRemoteApi().request(endpoint, '/v1/account'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', 'network_loopback')
              .having((e) => e.message, 'message', contains('adb reverse')),
        ),
      );
    },
  );
}
