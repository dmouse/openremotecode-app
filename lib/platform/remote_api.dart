import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../features/server_settings/domain/server_endpoint.dart';
import 'access_tag.dart';

final class ApiResponse {
  const ApiResponse(this.body, {this.cookies = const []});
  final Map<String, dynamic> body;
  final List<Cookie> cookies;

  Cookie credential(String suffix, ServerEndpoint server) {
    final expected = server.uri.scheme == 'https'
        ? '__Host-opencode_remote_$suffix'
        : 'opencode_remote_$suffix';
    final matches = cookies.where((cookie) => cookie.name == expected).toList();
    if (matches.length != 1 ||
        !RegExp(r'^[A-Za-z0-9_-]{20,512}$').hasMatch(matches.single.value) ||
        matches.single.expires == null ||
        !matches.single.expires!.isAfter(DateTime.now())) {
      throw const ApiException(0, 'invalid_response');
    }
    return matches.single;
  }
}

final class ApiException implements Exception {
  const ApiException(this.status, this.code);
  final int status;
  final String code;

  String get message => switch (code) {
    'invalid_credentials' => 'Email or password is incorrect.',
    'disposable_email' =>
      'Temporary email addresses are not accepted. Use a permanent address.',
    'invalid_verification_code' =>
      'That code is incorrect or has expired. Request a new one.',
    'invalid_google_token' =>
      'Google sign-in could not be verified. Please try again.',
    // The one federated failure with a recovery path, so the copy names it.
    'account_link_required' => 'An account already uses this email address. Sign in with your password to link Google to it.',
    'account_identity_conflict' => 'That account is already linked to a different Google account. Sign in with the Google account you linked, or use your password.',
    'google_signin_unavailable' =>
      'This server does not offer Google sign-in. Use your email and password.',
    'invalid_refresh' ||
    'unauthorized' => 'Your session has expired. Sign in again.',
    'network' =>
      'Could not reach your server. Check your connection and try again.',
    'network_loopback' => 'Could not reach your local server. Make sure it is running; for Android local testing, run adb reverse tcp:8080 tcp:8080 and retry.',
    'timeout' => 'The server took too long to respond. Please try again.',
    'secure_storage' => 'Could not access secure device storage. Unlock your device and try again.',
    'invalid_response' => 'The server returned an unexpected response.',
    _ =>
      status == 429
          ? 'Too many attempts. Wait a moment and try again.'
          : 'The request could not be completed. Please try again.',
  };
}

abstract interface class RemoteApi {
  Future<ApiResponse> request(
    ServerEndpoint server,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? accessToken,
    String? cookie,
  });
}

/// WebSocket.connect uses openUrl internally. Stop its upgrade request from
/// forwarding even a single-use relay ticket to a redirect destination.
final class NoRedirectHttpClient implements HttpClient {
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = await _client.openUrl(method, url);
    request.followRedirects = false;
    return request;
  }

  @override
  void close({bool force = false}) => _client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No cookie jar, automatic redirects, logging, or implicit credential forwarding.
final class HttpRemoteApi implements RemoteApi {
  const HttpRemoteApi();

  @override
  Future<ApiResponse> request(
    ServerEndpoint server,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? accessToken,
    String? cookie,
  }) async {
    if (!path.startsWith('/v1/') || path.contains('..') || path.contains('?')) {
      throw const ApiException(0, 'invalid_request');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    Future<ApiResponse> send() async {
      final request = await client.openUrl(
        method,
        server.uri.replace(path: path),
      );
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.headers.set(accessTagHeader, accessTagValue);
      if (accessToken != null) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $accessToken',
        );
      }
      if (cookie != null) request.headers.set(HttpHeaders.cookieHeader, cookie);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 256 * 1024) {
          throw const ApiException(0, 'invalid_response');
        }
        bytes.addAll(chunk);
      }
      Map<String, dynamic> document = {};
      if (bytes.isNotEmpty) {
        try {
          final decoded = jsonDecode(utf8.decode(bytes));
          if (decoded is! Map<String, dynamic>) throw const FormatException();
          document = decoded;
        } catch (_) {
          throw const ApiException(0, 'invalid_response');
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          response.statusCode,
          document['code'] is String
              ? document['code'] as String
              : 'request_failed',
        );
      }
      return ApiResponse(document, cookies: response.cookies);
    }

    try {
      return await send().timeout(const Duration(seconds: 15));
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(0, 'timeout');
    } on IOException {
      final loopbackHttp =
          server.uri.scheme == 'http' &&
          const {'127.0.0.1', 'localhost', '::1'}.contains(server.uri.host);
      throw ApiException(0, loopbackHttp ? 'network_loopback' : 'network');
    } finally {
      client.close(force: true);
    }
  }
}

String requiredString(Map<String, dynamic> json, String key, {int max = 512}) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > max) {
    throw const ApiException(0, 'invalid_response');
  }
  return value;
}

DateTime requiredDate(Map<String, dynamic> json, String key) {
  final date = DateTime.tryParse(requiredString(json, key));
  if (date == null) throw const ApiException(0, 'invalid_response');
  return date.toUtc();
}

Map<String, dynamic> requiredMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map<String, dynamic>) {
    throw const ApiException(0, 'invalid_response');
  }
  return value;
}
