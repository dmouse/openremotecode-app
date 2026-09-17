import '../../app_config.dart';
import '../auth/auth_repository.dart';
import '../server_settings/server_settings_view_model.dart';

/// Form rules and the registration command. Never stores entered passwords.
final class RegistrationViewModel {
  RegistrationViewModel({required this.auth, required this.serverSettings});
  final AuthRepository auth;
  final ServerSettingsViewModel serverSettings;
  bool get isBusy => auth.isBusy;
  String? get error => auth.error;

  /// Null both when no server is configured and when it's the production
  /// default, so the registration screen doesn't call out the address a
  /// normal user never had to think about.
  String? get serverAddress {
    final endpoint = serverSettings.endpoint;
    if (endpoint == null ||
        endpoint.uri.host == AppConfig.productionServerHost) {
      return null;
    }
    return endpoint.toString();
  }

  bool get canUseGoogle =>
      auth.supportsGoogleSignIn && serverSettings.endpoint != null;

  Future<bool> register(String email, String password) {
    final endpoint = serverSettings.endpoint;
    if (endpoint == null) return Future.value(false);
    return auth.register(endpoint, email, password);
  }

  /// The same command the sign-in screen runs. The server creates the account when
  /// the assertion reaches no existing one, so there is no separate sign-up call
  /// and, unlike register, this returns a usable session rather than a challenge.
  Future<bool> signInWithGoogle() {
    final endpoint = serverSettings.endpoint;
    if (endpoint == null) return Future.value(false);
    return auth.signInWithGoogle(endpoint);
  }

  String? validateEmail(String? input) {
    final email = input?.trim() ?? '';
    if (email.isEmpty) return 'Enter your email address.';
    if (email.length > 254) return 'Email address is too long.';
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  /// Enforces both bounds the server enforces. Signing in only needs the upper
  /// bound, but registration must reject a password the server would refuse
  /// rather than let the user discover it from a failed request.
  String? validatePassword(String? password) {
    if (password == null || password.isEmpty) return 'Choose a password.';
    if (password.length < 12) {
      return 'Use at least 12 characters.';
    }
    if (password.length > 128) return 'Password is too long.';
    return null;
  }

  String? validateConfirmPassword(String? confirmation, String password) {
    if (confirmation == null || confirmation.isEmpty) {
      return 'Re-enter your password.';
    }
    if (confirmation != password) return 'Passwords do not match.';
    return null;
  }

  String? validateDestination({required bool hasServer}) =>
      hasServer ? null : 'No remote server is configured.';
}
