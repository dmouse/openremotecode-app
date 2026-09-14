import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_config.dart';
import 'features/login/ui/login_screen.dart';
import 'features/registration/ui/registration_screen.dart';
import 'features/verify_email/ui/verify_email_screen.dart';
import 'features/auth/auth_repository.dart';
import 'features/connections/data/api_connections_repository.dart';
import 'features/connections/data/connections_repository.dart';
import 'features/workspace/ui/workspace_screen.dart';
import 'platform/google_identity.dart';
import 'platform/remote_api.dart';
import 'platform/secure_store.dart';
import 'features/server_settings/data/server_settings_repository.dart';
import 'features/server_settings/server_settings_view_model.dart';
import 'ui/core/app_theme.dart';

class MainApp extends StatefulWidget {
  const MainApp({
    super.key,
    this.serverSettingsRepository,
    this.authRepository,
    this.connectionsRepositoryFactory,
  });

  final ServerSettingsRepository? serverSettingsRepository;
  final AuthRepository? authRepository;
  final ConnectionsRepository Function(AuthRepository)?
  connectionsRepositoryFactory;

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  late final ServerSettingsViewModel _serverSettings;
  late final AuthRepository _auth;
  bool _ready = false;
  bool _showRegistration = false;
  final _navigatorKey = GlobalKey<NavigatorState>();
  String? _lastScope;
  ConnectionsRepository? _connections;

  void _sessionChanged() {
    final scope = _auth.session?.scope;
    if (_lastScope != null && scope != _lastScope) {
      _connections = null;
      // Signing out returns to sign-in, not to whichever auth screen was last
      // open. Guarded by _lastScope so entering registration, which happens with
      // no session at all, is unaffected.
      _showRegistration = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _navigatorKey.currentState?.popUntil((route) => route.isFirst);
        }
      });
    }
    _lastScope = scope;
  }

  @override
  void initState() {
    super.initState();
    _serverSettings = ServerSettingsViewModel(
      widget.serverSettingsRepository ?? PreferencesServerSettingsRepository(),
      defaultServer: AppConfig.defaultServer,
      allowLoopbackHttp: kDebugMode,
    );
    _auth =
        widget.authRepository ??
        AuthRepository(
          api: const HttpRemoteApi(),
          store: const NativeSecureStore(),
          // Left out entirely when the build carries no Google configuration, so
          // the action is absent rather than present and unusable.
          google: AppConfig.googleSignInConfigured
              ? NativeGoogleIdentityProvider()
              : null,
        );
    _auth.addListener(_sessionChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await _serverSettings.load();
    final endpoint = _serverSettings.endpoint;
    if (endpoint != null) await _auth.restore(endpoint);
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _serverSettings.dispose();
    _auth.removeListener(_sessionChanged);
    if (widget.authRepository == null) _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Open Remote Code',
    navigatorKey: _navigatorKey,
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light,
    home: !_ready
        ? const Scaffold(
            body: Center(
              child: CircularProgressIndicator(
                semanticsLabel: 'Restoring session',
              ),
            ),
          )
        : ListenableBuilder(
            listenable: _auth,
            builder: (context, _) {
              final session = _auth.session;
              if (session != null) {
                return WorkspaceScreen(
                  key: ValueKey(session.scope),
                  repository: _connections ??=
                      widget.connectionsRepositoryFactory?.call(_auth) ??
                      ApiConnectionsRepository(_auth),
                  auth: _auth,
                );
              }
              // An outstanding challenge takes precedence over both auth screens:
              // the account exists but cannot be used until it is verified.
              if (_auth.pendingVerification != null) {
                return VerifyEmailScreen(
                  auth: _auth,
                  onSignIn: () {
                    _auth.cancelVerification();
                    // Leaving registration behind as well, so asking to sign in
                    // does not drop back onto the registration form.
                    setState(() => _showRegistration = false);
                  },
                );
              }
              // A local flag rather than Navigator.push, to stay consistent with
              // how `home` is already swapped reactively and to avoid interacting
              // with the cross-account popUntil reset in _sessionChanged.
              return _showRegistration
                  ? RegistrationScreen(
                      serverSettings: _serverSettings,
                      auth: _auth,
                      onBackToSignIn: () =>
                          setState(() => _showRegistration = false),
                    )
                  : LoginScreen(
                      serverSettings: _serverSettings,
                      auth: _auth,
                      onCreateAccount: () =>
                          setState(() => _showRegistration = true),
                    );
            },
          ),
  );
}
