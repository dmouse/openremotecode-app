import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../platform/google_identity.dart';
import '../../platform/remote_api.dart';
import '../../platform/secure_store.dart';
import '../server_settings/domain/server_endpoint.dart';
import 'auth_session.dart';
import 'verification_challenge.dart';

final class AuthRepository extends ChangeNotifier {
  AuthRepository({required this.api, required this.store, this.google});

  final RemoteApi api;
  final SecureStore store;

  /// Null in a build with no Google configuration, which is what hides the action.
  final GoogleIdentityProvider? google;
  bool get supportsGoogleSignIn => google?.isAvailable ?? false;
  AuthSession? _session;
  // Held in memory only. See VerificationChallenge for why it is never persisted.
  VerificationChallenge? _pendingVerification;
  bool _busy = false;
  bool _disposed = false;
  String? _error;
  Future<void>? _refreshing;
  int _generation = 0;

  AuthSession? get session => _session;
  VerificationChallenge? get pendingVerification => _pendingVerification;
  bool get isBusy => _busy;
  String? get error => _error;
  static String storageKey(ServerEndpoint server) =>
      'session_v1_${sha256.convert(utf8.encode(server.toString()))}';

  Future<bool> login(
    ServerEndpoint server,
    String email,
    String password,
  ) async {
    if (_busy || _disposed || _session != null) return false;
    _busy = true;
    _error = null;
    _notify();
    try {
      final response = await api.request(
        server,
        '/v1/auth/login',
        method: 'POST',
        body: {
          'email': email.trim(),
          'password': password,
          'clientName': 'Open Remote Code Mobile',
        },
      );
      // A pending account is answered with a verification challenge and no
      // cookie, so there is nothing to persist and no session to enter.
      if (VerificationChallenge.isChallenge(response.body)) {
        _pendingVerification = VerificationChallenge.parse(
          server,
          response.body,
        );
        return false;
      }
      final session = AuthSession.parse(server, response.body);
      final refresh = response.credential('refresh', server);
      await _persist(session, refresh);
      if (_disposed) return false;
      _session = session;
      _generation++;
      return true;
    } catch (error) {
      _error = _message(error);
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Signs in with Google, creating the account if this is the first time. There is
  /// no separate registration path: the server decides whether the assertion
  /// reaches an existing account or makes a new one, and either way the address is
  /// already verified, so this never yields a verification challenge.
  ///
  /// Returns false for a cancelled sign-in exactly as it does for a failed one; the
  /// difference is that cancelling leaves no error to display.
  Future<bool> signInWithGoogle(ServerEndpoint server) async {
    final provider = google;
    if (provider == null || _busy || _disposed || _session != null) {
      return false;
    }
    _busy = true;
    _error = null;
    _notify();
    try {
      final result = await provider.requestIdToken();
      switch (result) {
        case GoogleIdentityCancelled():
          return false;
        case GoogleIdentityFailure(:final message):
          _error = message;
          return false;
        case GoogleIdentityToken(:final idToken):
          final response = await api.request(
            server,
            '/v1/auth/google',
            method: 'POST',
            body: {'idToken': idToken, 'clientName': 'Open Remote Code Mobile'},
          );
          final session = AuthSession.parse(server, response.body);
          final refresh = response.credential('refresh', server);
          await _persist(session, refresh);
          if (_disposed) return false;
          _session = session;
          _generation++;
          return true;
      }
    } catch (error) {
      _error = _message(error);
      // The chosen account did not get in. Forgetting it locally means retrying
      // offers the account chooser again rather than silently repeating the
      // rejected choice, which matters most for account_link_required.
      unawaited(provider.signOut());
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Creates an account. Always yields a verification challenge rather than a
  /// session: the server answers an address that is already registered exactly as
  /// it answers a new one, so this cannot report whether an account exists.
  Future<bool> register(
    ServerEndpoint server,
    String email,
    String password,
  ) async {
    if (_busy || _disposed || _session != null) return false;
    _busy = true;
    _error = null;
    _notify();
    try {
      final response = await api.request(
        server,
        '/v1/auth/register',
        method: 'POST',
        body: {
          'email': email.trim(),
          'password': password,
          'clientName': 'Open Remote Code Mobile',
        },
      );
      final challenge = VerificationChallenge.parse(server, response.body);
      if (_disposed) return false;
      _pendingVerification = challenge;
      return true;
    } catch (error) {
      _error = _message(error);
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Exchanges the outstanding challenge and its code for a real session. This is
  /// the only path that turns a pending account into a usable one.
  Future<bool> submitVerificationCode(String code) async {
    final challenge = _pendingVerification;
    if (challenge == null || _busy || _disposed) return false;
    _busy = true;
    _error = null;
    _notify();
    try {
      final response = await api.request(
        challenge.server,
        '/v1/auth/verify-email',
        method: 'POST',
        body: {'verificationTicket': challenge.ticket, 'code': code.trim()},
      );
      final session = AuthSession.parse(challenge.server, response.body);
      final refresh = response.credential('refresh', challenge.server);
      await _persist(session, refresh);
      if (_disposed) return false;
      _pendingVerification = null;
      _session = session;
      _generation++;
      return true;
    } catch (error) {
      _error = _message(error);
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Asks for a new code. The server rotates both the ticket and the code, so the
  /// challenge it returns replaces the one held here.
  Future<bool> resendVerificationCode() async {
    final challenge = _pendingVerification;
    if (challenge == null || _busy || _disposed) return false;
    _busy = true;
    _error = null;
    _notify();
    try {
      final response = await api.request(
        challenge.server,
        '/v1/auth/resend-verification',
        method: 'POST',
        body: {'verificationTicket': challenge.ticket},
      );
      final rotated = VerificationChallenge.parse(
        challenge.server,
        response.body,
      );
      if (_disposed) return false;
      _pendingVerification = rotated;
      return true;
    } catch (error) {
      _error = _message(error);
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Abandons verification locally. No request is needed: the ticket is not
  /// stored anywhere, and signing in again reissues a challenge.
  void cancelVerification() {
    if (_busy || _disposed || _pendingVerification == null) return;
    _pendingVerification = null;
    _error = null;
    _notify();
  }

  Future<void> restore(ServerEndpoint server) async {
    if (_busy || _session != null || _disposed) return;
    _busy = true;
    _error = null;
    _notify();
    try {
      final saved = await _read(server);
      if (saved == null) return;
      await _rotate(server, saved, restoring: true);
    } catch (error) {
      _error = _message(error);
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<ApiResponse> request(
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? cookie,
  }) async {
    final initial = _session;
    if (initial == null || _busy || _disposed) {
      throw const ApiException(401, 'unauthorized');
    }
    await refreshIfNeeded();
    final session = _session;
    if (session == null || session.scope != initial.scope) {
      throw const ApiException(401, 'unauthorized');
    }
    try {
      return await api.request(
        session.server,
        path,
        method: method,
        body: body,
        accessToken: session.accessToken,
        cookie: cookie,
      );
    } on ApiException catch (error) {
      if (error.status == 401 && path != '/v1/relay/tickets') {
        await _invalidate();
      }
      rethrow;
    }
  }

  Future<void> refreshIfNeeded({bool force = false}) async {
    final session = _session;
    if (session == null) return;
    if (_busy || _disposed) throw const ApiException(401, 'unauthorized');
    if (!force &&
        session.expiresAt.isAfter(
          DateTime.now().add(const Duration(seconds: 30)),
        )) {
      return;
    }
    if (_refreshing case final existing?) return existing;
    final generation = _generation;
    final future = () async {
      final saved = await _read(session.server);
      if (saved == null) {
        await _invalidate();
        throw const ApiException(401, 'invalid_refresh');
      }
      await _rotate(session.server, saved, expectedGeneration: generation);
    }();
    _refreshing = future;
    try {
      await future;
    } finally {
      _refreshing = null;
    }
  }

  Future<void> validateOnResume() async {
    if (_session == null || _busy) return;
    try {
      final response = await request('/v1/account');
      if (requiredMap(response.body, 'user')['id'] != _session?.accountId) {
        throw const ApiException(401, 'unauthorized');
      }
    } on ApiException catch (error) {
      if (error.status == 401) {
        await _invalidate();
      }
    } catch (_) {
      // A temporary network or storage error never authorizes a new session.
    }
  }

  Future<bool> logout() async {
    if (_busy) return false;
    _busy = true;
    _error = null;
    _notify();
    try {
      // Wait for rotation so logout revokes the newest credential.
      try {
        await _refreshing;
      } catch (_) {}
      final session = _session;
      if (session == null) return true;
      final saved = await _read(session.server);
      try {
        await store.delete(storageKey(session.server));
      } catch (_) {
        throw const ApiException(0, 'secure_storage');
      }
      _session = null;
      _generation++;
      _notify();
      // Forget the device's Google account too, so signing out and back in offers
      // the chooser rather than silently returning to the same account.
      await google?.signOut();
      if (saved != null) {
        try {
          await api.request(
            session.server,
            '/v1/auth/logout',
            method: 'POST',
            cookie: saved['cookie'] as String,
          );
        } catch (_) {
          _error = 'Signed out on this device. The server could not be reached to revoke the session.';
        }
      }
      return true;
    } catch (error) {
      _error = _message(error);
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<Map<String, dynamic>?> _read(ServerEndpoint server) async {
    String? raw;
    try {
      raw = await store.read(storageKey(server));
    } catch (_) {
      throw const ApiException(0, 'secure_storage');
    }
    if (raw == null) return null;
    try {
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      if (saved['version'] != 1 || saved['origin'] != server.toString()) {
        throw const FormatException();
      }
      requiredString(saved, 'accountId', max: 64);
      final cookie = requiredString(saved, 'cookie', max: 600);
      final name = server.uri.scheme == 'https'
          ? '__Host-opencode_remote_refresh'
          : 'opencode_remote_refresh';
      if (!RegExp('^$name=[A-Za-z0-9_-]{20,512}\$').hasMatch(cookie)) {
        throw const FormatException();
      }
      if (!requiredDate(saved, 'expiresAt').isAfter(DateTime.now())) {
        await store.delete(storageKey(server));
        return null;
      }
      return saved;
    } catch (_) {
      await store.delete(storageKey(server));
      throw const ApiException(401, 'invalid_refresh');
    }
  }

  Future<void> _rotate(
    ServerEndpoint server,
    Map<String, dynamic> saved, {
    bool restoring = false,
    int? expectedGeneration,
  }) async {
    try {
      final response = await api.request(
        server,
        '/v1/auth/refresh',
        method: 'POST',
        cookie: saved['cookie'] as String,
      );
      final next = AuthSession.parse(server, response.body);
      if (next.accountId != saved['accountId']) {
        throw const ApiException(401, 'invalid_refresh');
      }
      final refresh = response.credential('refresh', server);
      await _persist(next, refresh);
      if (_disposed ||
          (expectedGeneration != null && expectedGeneration != _generation)) {
        return;
      }
      _session = next;
      if (restoring) _generation++;
      _notify();
    } on ApiException catch (error) {
      if (error.status == 401 || error.code == 'secure_storage') {
        _session = null;
        _generation++;
        _error = error.message;
        _notify();
        try {
          await store.delete(storageKey(server));
        } catch (_) {
          // The gate is already closed. An undeletable stale token still needs
          // server validation and rotation before it can admit a future session.
        }
      }
      rethrow;
    }
  }

  Future<void> _persist(AuthSession session, Cookie refresh) async {
    try {
      await store.write(
        storageKey(session.server),
        jsonEncode({
          'version': 1,
          'origin': session.server.toString(),
          'accountId': session.accountId,
          'cookie': '${refresh.name}=${refresh.value}',
          'expiresAt': refresh.expires!.toUtc().toIso8601String(),
        }),
      );
    } catch (_) {
      try {
        await api.request(
          session.server,
          '/v1/auth/logout',
          method: 'POST',
          cookie: '${refresh.name}=${refresh.value}',
        );
      } catch (_) {}
      throw const ApiException(0, 'secure_storage');
    }
  }

  Future<void> _invalidate() async {
    final session = _session;
    _session = null;
    _generation++;
    _error = 'Your session has expired. Sign in again.';
    _notify();
    if (session != null) {
      try {
        await store.delete(storageKey(session.server));
      } catch (_) {}
    }
  }

  String _message(Object error) => error is ApiException
      ? error.message
      : 'Could not complete sign-in. Please try again.';
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
