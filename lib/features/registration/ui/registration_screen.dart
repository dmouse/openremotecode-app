import 'package:flutter/material.dart';

import '../../../ui/core/auth_screen_scaffold.dart';
import '../../../ui/core/inline_notice.dart';
import '../../auth/auth_repository.dart';
import '../../server_settings/server_settings_view_model.dart';
import '../../server_settings/ui/server_settings_loading_indicator.dart';
import '../registration_view_model.dart';
import 'registration_form.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({
    super.key,
    required this.serverSettings,
    required this.auth,
    required this.onBackToSignIn,
  });

  final ServerSettingsViewModel serverSettings;
  final AuthRepository auth;
  final VoidCallback onBackToSignIn;

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  late final _viewModel = RegistrationViewModel(
    auth: widget.auth,
    serverSettings: widget.serverSettings,
  );

  @override
  Widget build(BuildContext context) => AuthScreenScaffold(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Set up your\nworkspace.',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 16),
        const Text(
          'We will email you a six-digit code to confirm your address.',
        ),
        const SizedBox(height: 32),
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
                RegistrationForm(
                  // Changing origin destroys all form state.
                  key: ValueKey(settings.endpoint?.toString()),
                  viewModel: _viewModel,
                  hasServer: settings.endpoint != null,
                  onBackToSignIn: widget.onBackToSignIn,
                ),
                if (settings.loadError case final error?) ...[
                  const SizedBox(height: 16),
                  InlineNotice(message: error, isError: true),
                ],
              ],
            );
          },
        ),
      ],
    ),
  );
}
