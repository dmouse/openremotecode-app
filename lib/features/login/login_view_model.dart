import '../auth/auth_repository.dart';
import '../server_settings/server_settings_view_model.dart';

/// Form rules and authentication commands. Never stores entered passwords.
final class LoginViewModel {
  LoginViewModel({required this.auth, required this.serverSettings});
  final AuthRepository auth;
  final ServerSettingsViewModel serverSettings;
  bool get isBusy => auth.isBusy;
  String? get error => auth.error;
  String? get serverAddress => serverSettings.endpoint?.toString();

  /// Offered only where the build can complete the flow and a server is selected,
  /// so the action never appears in a state where tapping it cannot work.
  bool get canUseGoogle =>
      auth.supportsGoogleSignIn && serverSettings.endpoint != null;

  Future<bool> login(String email, String password) {
    final endpoint = serverSettings.endpoint;
    if (endpoint == null) return Future.value(false);
    return auth.login(endpoint, email, password);
  }

  Future<bool> signInWithGoogle() {
    final endpoint = serverSettings.endpoint;
    if (endpoint == null) return Future.value(false);
    return auth.signInWithGoogle(endpoint);
  }

  Future<void> restore() async {
    final endpoint = serverSettings.endpoint;
    if (endpoint != null) await auth.restore(endpoint);
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

  String? validatePassword(String? password) =>
      password == null || password.isEmpty
      ? 'Enter your password.'
      : password.length > 128
      ? 'Password is too long.'
      : null;

  String? validateDestination({required bool hasServer}) =>
      hasServer ? null : 'No remote server is configured.';
}
