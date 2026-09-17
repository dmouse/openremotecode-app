import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui/core/app_button.dart';
import '../../../ui/core/inline_notice.dart';
import '../../../ui/core/password_form_field.dart';
import '../../auth/ui/google_sign_in_button.dart';
import '../login_view_model.dart';

class LoginForm extends StatefulWidget {
  const LoginForm({
    super.key,
    required this.viewModel,
    required this.hasServer,
  });

  final LoginViewModel viewModel;
  final bool hasServer;

  @override
  State<LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<LoginForm> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscurePassword = true;
  String? _submissionError;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.viewModel.isBusy) return;
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final error = widget.viewModel.validateDestination(
      hasServer: widget.hasServer,
    );
    setState(() => _submissionError = error);
    if (error != null) return;
    final success = await widget.viewModel.login(_email.text, _password.text);
    if (!success) return;
    // Commit before clearing, and before the successful sign-in tears this form
    // down: the manager saves whatever the fields hold at this moment.
    TextInput.finishAutofillContext();
    if (mounted) {
      _email.clear();
      _password.clear();
    }
  }

  /// Null when the server is the production default, alongside a real error
  /// state: nothing useful to tell a normal user in either case.
  String? get _serverStatusLabel {
    if (!widget.hasServer) return 'No server configured';
    final address = widget.viewModel.serverAddress;
    return address == null ? null : 'Signing in to $address';
  }

  Future<void> _submitGoogle() async {
    if (widget.viewModel.isBusy) return;
    FocusScope.of(context).unfocus();
    // Google sign-in does not use the form, so a half-filled one must not block it
    // or leave stale validation errors behind.
    setState(() => _submissionError = null);
    final success = await widget.viewModel.signInWithGoogle();
    if (!success) return;
    // No password was entered, so a half-filled form must not turn into a save
    // prompt for a credential the user never typed.
    TextInput.finishAutofillContext(shouldSave: false);
    if (mounted) {
      _email.clear();
      _password.clear();
    }
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _formKey,
    // Groups both fields into one credential for the platform autofill service,
    // which is what external managers (Bitwarden, 1Password) read. Teardown
    // cancels rather than commits, so only a successful sign-in offers to save.
    child: AutofillGroup(
      onDisposeAction: AutofillContextAction.cancel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Welcome back', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 20),
          TextFormField(
            enabled: !widget.viewModel.isBusy,
            controller: _email,
            validator: widget.viewModel.validateEmail,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            enableSuggestions: false,
            // `username` leads: iOS maps only the first recognised hint, and it is
            // the one that pairs this field with the password below. `email` is
            // kept after it for Android services that match on it.
            autofillHints: const [AutofillHints.username, AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Email address',
              prefixIcon: Icon(Icons.alternate_email_rounded, size: 20),
            ),
          ),
          const SizedBox(height: 16),
          PasswordFormField(
            controller: _password,
            enabled: !widget.viewModel.isBusy,
            validator: widget.viewModel.validatePassword,
            obscureText: _obscurePassword,
            onToggleObscureText: () =>
                setState(() => _obscurePassword = !_obscurePassword),
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 24),
          AppButton.primary(
            onPressed: _submit,
            label: 'Sign in',
            icon: Icons.arrow_forward_rounded,
            iconAlignment: IconAlignment.end,
            isLoading: widget.viewModel.isBusy,
            loadingLabel: 'Signing in',
          ),
          if (widget.viewModel.canUseGoogle) ...[
            const SizedBox(height: 20),
            GoogleSignInButton(
              onPressed: _submitGoogle,
              isBusy: widget.viewModel.isBusy,
            ),
          ],
          if (_serverStatusLabel case final label?) ...[
            const SizedBox(height: 12),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ],
          if (widget.viewModel.error case final error?) ...[
            const SizedBox(height: 16),
            InlineNotice(message: error, isError: true),
            TextButton(
              onPressed: widget.viewModel.isBusy
                  ? null
                  : widget.viewModel.restore,
              child: const Text('Restore saved session'),
            ),
          ],
          if (_submissionError case final error?) ...[
            const SizedBox(height: 16),
            InlineNotice(message: error, isError: true),
          ],
        ],
      ),
    ),
  );
}
