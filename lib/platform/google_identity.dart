import 'package:google_sign_in/google_sign_in.dart';

import '../app_config.dart';

/// The result of asking the platform for a Google identity assertion.
///
/// Cancellation is a distinct outcome rather than an error: the user closing the
/// account chooser is a normal thing to do, and must not leave an error banner on
/// the sign-in screen.
sealed class GoogleIdentityResult {
  const GoogleIdentityResult();
}

final class GoogleIdentityToken extends GoogleIdentityResult {
  const GoogleIdentityToken(this.idToken);

  /// An opaque assertion. Nothing on this side reads its claims: only the server
  /// can verify them, and a client-side reading would be a decision made on
  /// unverified input.
  final String idToken;
}

final class GoogleIdentityCancelled extends GoogleIdentityResult {
  const GoogleIdentityCancelled();
}

final class GoogleIdentityFailure extends GoogleIdentityResult {
  const GoogleIdentityFailure(this.message);
  final String message;
}

/// Narrow adapter over the native Google Sign-In SDK, kept behind an interface so
/// the authentication feature never imports the plugin and can be tested without a
/// platform channel.
abstract interface class GoogleIdentityProvider {
  /// Whether this build can complete a Google sign-in at all. The action is hidden
  /// when it cannot, rather than failing after the user taps it.
  bool get isAvailable;

  /// Runs the interactive flow and returns an ID token for the server to verify.
  Future<GoogleIdentityResult> requestIdToken();

  /// Forgets the account chosen on this device. It revokes nothing on the server —
  /// the session is revoked through logout — and only ensures the next sign-in
  /// asks which account to use instead of silently reusing the last one.
  Future<void> signOut();
}

/// The real adapter. Initialization is lazy and happens at most once, because the
/// plugin requires exactly one `initialize` call and the app must not pay for a
/// platform channel round trip on a screen nobody signs in from.
final class NativeGoogleIdentityProvider implements GoogleIdentityProvider {
  NativeGoogleIdentityProvider({
    GoogleSignIn? signIn,
    this.serverClientId = AppConfig.googleServerClientId,
    this.iosClientId = AppConfig.googleIosClientId,
  }) : _signIn = signIn ?? GoogleSignIn.instance;

  final GoogleSignIn _signIn;
  final String serverClientId;
  final String iosClientId;
  Future<void>? _initialization;

  @override
  bool get isAvailable =>
      serverClientId.isNotEmpty && _signIn.supportsAuthenticate();

  Future<void> _initialize() => _initialization ??= _signIn.initialize(
    clientId: iosClientId.isEmpty ? null : iosClientId,
    serverClientId: serverClientId,
  );

  @override
  Future<GoogleIdentityResult> requestIdToken() async {
    if (!isAvailable) {
      return const GoogleIdentityFailure(
        'Google sign-in is not available in this build.',
      );
    }
    try {
      await _initialize();
      final account = await _signIn.authenticate();
      final idToken = account.authentication.idToken;
      // A sign-in that produces no ID token proves nothing the server can check.
      // It usually means the OAuth client IDs do not match the ones registered
      // with Google, which is a configuration fault rather than a user error.
      if (idToken == null || idToken.isEmpty) {
        return const GoogleIdentityFailure(
          'Google did not return a sign-in token. Check the app configuration.',
        );
      }
      return GoogleIdentityToken(idToken);
    } on GoogleSignInException catch (error) {
      // A failed initialization is remembered as a completed future, so it must be
      // discarded or every later attempt would reuse the failure.
      _initialization = null;
      return switch (error.code) {
        GoogleSignInExceptionCode.canceled ||
        GoogleSignInExceptionCode.interrupted =>
          const GoogleIdentityCancelled(),
        // The plugin's description can name the account or the failure reason, so
        // it is deliberately not surfaced.
        _ => const GoogleIdentityFailure(
          'Could not sign in with Google. Please try again.',
        ),
      };
    } catch (_) {
      _initialization = null;
      return const GoogleIdentityFailure(
        'Could not sign in with Google. Please try again.',
      );
    }
  }

  @override
  Future<void> signOut() async {
    // Nothing here is load-bearing for security, so a failure is swallowed: the
    // server session is already revoked by the time this runs.
    if (_initialization == null) return;
    try {
      await _signIn.signOut();
    } catch (_) {}
  }
}
