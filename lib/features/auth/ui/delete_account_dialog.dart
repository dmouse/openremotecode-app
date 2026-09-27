import 'package:flutter/material.dart';

import '../../../ui/core/inline_notice.dart';
import '../../../ui/core/password_form_field.dart';
import '../auth_repository.dart';

/// Confirms permanent account deletion. The server requires a fresh proof of the
/// account's credential, so the dialog asks for the password, or offers Google
/// confirmation for an account that signs in with Google.
///
/// On success the session ends, and the app returns to sign-in on its own; the
/// dialog pops with `true` only if it is still on screen by then.
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({super.key, required this.auth});

  final AuthRepository auth;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _obscurePassword = true;
  // An error from an attempt in an earlier opening of the dialog is stale, so
  // errors appear only once the user has tried to delete from this one.
  bool _attempted = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _deleteWithPassword() async {
    if (widget.auth.isBusy || !_formKey.currentState!.validate()) return;
    setState(() => _attempted = true);
    _finish(await widget.auth.deleteAccount(password: _password.text));
  }

  Future<void> _deleteWithGoogle() async {
    if (widget.auth.isBusy) return;
    setState(() => _attempted = true);
    _finish(await widget.auth.deleteAccount());
  }

  void _finish(bool deleted) {
    if (!mounted) return;
    if (deleted) {
      Navigator.pop(context, true);
    } else {
      _password.clear();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.auth,
    builder: (context, _) {
      final auth = widget.auth;
      final busy = auth.isBusy;
      final error = _attempted ? auth.deletionError : null;
      return AlertDialog(
        scrollable: true,
        title: const Text('Delete account?'),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'This permanently deletes ${auth.session?.email ?? 'your account'} '
                'and signs you out everywhere. Your connections and trusted '
                'devices are removed, and each computer must be paired again '
                'to use remote access. This cannot be undone.',
              ),
              const SizedBox(height: 12),
              const Text(
                'Your conversations stay in OpenCode on your computers. The '
                'server never stored them.',
              ),
              const SizedBox(height: 20),
              PasswordFormField(
                controller: _password,
                enabled: !busy,
                obscureText: _obscurePassword,
                onToggleObscureText: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                validator: (value) => value == null || value.isEmpty
                    ? 'Enter your password to confirm.'
                    : null,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _deleteWithPassword(),
              ),
              if (auth.supportsGoogleSignIn) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: busy ? null : _deleteWithGoogle,
                    icon: const Icon(Icons.account_circle_outlined, size: 20),
                    label: const Text(
                      'Signed up with Google? Confirm with Google',
                    ),
                  ),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                InlineNotice(message: error, isError: true),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: busy ? null : _deleteWithPassword,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      semanticsLabel: 'Deleting account',
                    ),
                  )
                : const Text('Delete account'),
          ),
        ],
      );
    },
  );
}
