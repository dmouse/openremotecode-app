import 'package:flutter/material.dart';

import '../../../ui/core/app_button.dart';
import '../../../ui/core/inline_notice.dart';
import '../../auth/auth_repository.dart';
import '../../settings/settings_view_model.dart';
import '../../settings/ui/chat_display_section.dart';

class WorkspaceSettingsView extends StatelessWidget {
  const WorkspaceSettingsView({
    super.key,
    required this.auth,
    required this.settings,
    required this.onDeleteAccount,
  });

  final AuthRepository auth;
  final SettingsViewModel settings;
  final VoidCallback onDeleteAccount;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: auth,
    builder: (context, _) => ListView(
      key: const ValueKey('settings-content'),
      padding: const EdgeInsets.all(24),
      children: [
        ChatDisplaySection(settings: settings),
        const SizedBox(height: 32),
        const Divider(),
        const SizedBox(height: 16),
        Text('Account', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Text(auth.session?.email ?? ''),
        const SizedBox(height: 24),
        if (auth.error case final error?) ...[
          InlineNotice(message: error, isError: true),
          const SizedBox(height: 16),
        ],
        AppButton.secondary(
          onPressed: auth.logout,
          isLoading: auth.isBusy,
          loadingLabel: 'Signing out',
          icon: Icons.logout,
          label: 'Sign out',
        ),
        const SizedBox(height: 32),
        const Divider(),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const ValueKey('delete-account'),
            onPressed: auth.isBusy ? null : onDeleteAccount,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('Delete account'),
          ),
        ),
      ],
    ),
  );
}
