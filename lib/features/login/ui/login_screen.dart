import 'package:flutter/material.dart';

import '../../../ui/core/auth_screen_scaffold.dart';
import '../../../ui/core/inline_notice.dart';
import '../../../ui/core/tap_sequence.dart';
import '../../server_settings/server_settings_view_model.dart';
import '../../server_settings/ui/server_settings_loading_indicator.dart';
import '../../server_settings/ui/server_settings_sheet.dart';
import '../../auth/auth_repository.dart';
import '../login_view_model.dart';
import 'login_form.dart';
import 'login_header.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.serverSettings,
    required this.auth,
    this.onCreateAccount,
  });

  final ServerSettingsViewModel serverSettings;
  final AuthRepository auth;

  /// Omitted where registration is not offered, which keeps existing callers and
  /// tests unchanged.
  final VoidCallback? onCreateAccount;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with WidgetsBindingObserver {
  final _tapSequence = TapSequence();
  final _clock = Stopwatch()..start();
  late final _loginViewModel = LoginViewModel(
    auth: widget.auth,
    serverSettings: widget.serverSettings,
  );
  bool _settingsOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _tapSequence.reset();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.stop();
    super.dispose();
  }

  void _onBackgroundTap() {
    if (_settingsOpen ||
        widget.serverSettings.isLoading ||
        widget.auth.isBusy) {
      return;
    }
    if (_tapSequence.register(_clock.elapsed)) _openServerSettings();
  }

  Future<void> _openServerSettings() async {
    if (_settingsOpen ||
        widget.serverSettings.isLoading ||
        widget.auth.isBusy) {
      return;
    }
    _settingsOpen = true;
    _tapSequence.reset();
    widget.serverSettings.clearSaveError();
    FocusScope.of(context).unfocus();
    try {
      await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        isDismissible: false,
        enableDrag: false,
        showDragHandle: false,
        constraints: const BoxConstraints(maxWidth: 520),
        builder: (_) => ServerSettingsSheet(viewModel: widget.serverSettings),
      );
    } finally {
      _settingsOpen = false;
      _tapSequence.reset();
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    onTap: _onBackgroundTap,
    child: AuthScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LoginHeader(),
          const SizedBox(height: 36),
          ListenableBuilder(
            listenable: widget.serverSettings,
            builder: (context, _) {
              final settings = widget.serverSettings;
              if (settings.isLoading) {
                return const ServerSettingsLoadingIndicator();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LoginForm(
                    // Changing origin destroys all form state and credentials.
                    key: ValueKey(settings.endpoint?.toString()),
                    viewModel: _loginViewModel,
                    hasServer: settings.endpoint != null,
                  ),
                  if (settings.loadError case final error?) ...[
                    const SizedBox(height: 16),
                    InlineNotice(message: error, isError: true),
                  ],
                  if (widget.onCreateAccount case final create?)
                    TextButton(
                      onPressed: widget.auth.isBusy ? null : create,
                      child: const Text("Don't have an account? Create one"),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          const Text(
            'LOCAL WORKSPACE. OPEN POSSIBILITIES.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, letterSpacing: 1.3),
          ),
        ],
      ),
    ),
  );
}
