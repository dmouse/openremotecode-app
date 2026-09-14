import 'dart:async';
import 'dart:io';

import 'package:openremotecode/features/auth/auth_repository.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/platform/google_identity.dart';
import 'package:openremotecode/platform/remote_api.dart';
import 'package:openremotecode/platform/secure_store.dart';

final class MemorySecureStore implements SecureStore {
  final Map<String, String> values = {};
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('locked');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('locked');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('locked');
    values.remove(key);
  }
}

final class FakeRemoteApi implements RemoteApi {
  final List<
    ({
      String origin,
      String path,
      Map<String, Object?>? body,
      String? token,
      String? cookie,
    })
  >
  calls = [];
  String accountId = 'usr_test_account_0123456789';
  ApiException? failure;
  Completer<void>? gate;
  int rotations = 0;
  Duration accessLifetime = const Duration(minutes: 10);

  // Verification is opt-in so existing tests see the original active-account
  // behavior by default.
  String verificationTicket = 'vft_test_ticket_0123456789';
  String correctVerificationCode = '123456';
  bool accountPending = false;
  int resends = 0;

  /// Rejects only the federated route, so a test can drive account_link_required
  /// without also breaking the password and refresh paths.
  ApiException? googleFailure;

  @override
  Future<ApiResponse> request(
    ServerEndpoint server,
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? accessToken,
    String? cookie,
  }) async {
    calls.add((
      origin: server.toString(),
      path: path,
      body: body,
      token: accessToken,
      cookie: cookie,
    ));
    if (gate case final pending?) await pending.future;
    if (failure case final error?) throw error;
    if (path == '/v1/auth/google' && googleFailure != null) {
      throw googleFailure!;
    }
    if (path == '/v1/auth/logout') return const ApiResponse({});
    if (path == '/v1/connectors') return const ApiResponse({'connectors': []});
    if (path == '/v1/account') return ApiResponse({'user': user});
    if (body?['password'] == 'incorrect') {
      throw const ApiException(401, 'invalid_credentials');
    }
    // Registering always yields a challenge, and so does signing in while the
    // account is still pending.
    if (path == '/v1/auth/register' ||
        (accountPending && path == '/v1/auth/login')) {
      return ApiResponse(challenge(server));
    }
    if (path == '/v1/auth/resend-verification') {
      if (body?['verificationTicket'] != verificationTicket) {
        throw const ApiException(400, 'invalid_verification_code');
      }
      resends++;
      verificationTicket = 'vft_test_ticket_rotated_$resends';
      return ApiResponse(challenge(server));
    }
    if (path == '/v1/auth/verify-email') {
      if (body?['verificationTicket'] != verificationTicket ||
          body?['code'] != correctVerificationCode) {
        throw const ApiException(400, 'invalid_verification_code');
      }
      // Verification is what activates the account.
      accountPending = false;
    }
    if (path == '/v1/auth/refresh') rotations++;
    return ApiResponse(
      {
        'accessToken': 'access_test_0123456789_$rotations',
        'accessTokenExpiresAt': DateTime.now()
            .add(accessLifetime)
            .toUtc()
            .toIso8601String(),
        'user': user,
      },
      cookies: [
        Cookie(
          server.uri.scheme == 'https'
              ? '__Host-opencode_remote_refresh'
              : 'opencode_remote_refresh',
          'refresh_test_0123456789_$rotations',
        )..expires = DateTime.now().add(const Duration(days: 30)),
      ],
    );
  }

  Map<String, Object> get user => {
    'id': accountId,
    'email': 'person@example.com',
    'status': 'active',
    'emailVerified': true,
    'emailBounced': false,
    'createdAt': '2026-01-01T00:00:00Z',
  };

  /// The verification-challenge shape: a pending account, a ticket, and
  /// deliberately no access token and no refresh cookie.
  Map<String, Object> challenge(ServerEndpoint server) => {
    'user': {
      'id': accountId,
      'email': 'person@example.com',
      'status': 'pending',
      'emailVerified': false,
      'emailBounced': false,
      'createdAt': '2026-01-01T00:00:00Z',
    },
    'verificationTicket': verificationTicket,
    'verificationTicketExpiresAt': DateTime.now()
        .add(const Duration(minutes: 10))
        .toUtc()
        .toIso8601String(),
  };
}

/// Stands in for the native Google SDK. Tests set the outcome the platform would
/// produce, so the repository's handling can be exercised without a plugin.
final class FakeGoogleIdentityProvider implements GoogleIdentityProvider {
  FakeGoogleIdentityProvider({
    this.isAvailable = true,
    this.result = const GoogleIdentityToken('header.payload.signature'),
  });

  @override
  bool isAvailable;
  GoogleIdentityResult result;
  int requests = 0;
  int signOuts = 0;

  @override
  Future<GoogleIdentityResult> requestIdToken() async {
    requests++;
    return result;
  }

  @override
  Future<void> signOut() async => signOuts++;
}

AuthRepository fakeAuth({FakeRemoteApi? api, GoogleIdentityProvider? google}) =>
    AuthRepository(
      api: api ?? FakeRemoteApi(),
      store: MemorySecureStore(),
      google: google,
    );
