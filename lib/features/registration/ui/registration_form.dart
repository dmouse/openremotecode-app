import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui/core/app_button.dart';
import '../../../ui/core/inline_notice.dart';
import '../../../ui/core/password_form_field.dart';
import '../../auth/ui/google_sign_in_button.dart';
import '../registration_view_model.dart';

class RegistrationForm extends StatefulWidget {
  const RegistrationForm({
    super.key,
    required this.viewModel,
    required this.hasServer,
    required this.onBackToSignIn,
  });

  final RegistrationViewModel viewModel;
  final bool hasServer;
  final VoidCallback onBackToSignIn;

  @override
  State<RegistrationForm> createState() => _RegistrationFormState();
}

class _RegistrationFormState extends State<RegistrationForm> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _obscurePassword = true;
  String? _submissionError;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
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
    final created = await widget.viewModel.register(
      _email.text,
      _password.text,
    );
    if (!created) return;
    // Commit before clearing, and before the pending challenge swaps this form
    // for the verification screen: the manager saves the new credential now,
    // rather than after the account is confirmed on another screen.
    TextInput.finishAutofillContext();
    if (mounted) {
      _email.clear();
      _password.clear();
      _confirmPassword.clear();
    }
  }

  /// Null when the server is the production default, alongside a real error
  /// state: nothing useful to tell a normal user in either case.
  String? get _serverStatusLabel {
    if (!widget.hasServer) return 'No server configured';
    final address = widget.viewModel.serverAddress;
    return address == null ? null : 'Creating an account on $address';
  }

  Future<void> _submitGoogle() async {
    if (widget.viewModel.isBusy) return;
    FocusScope.of(context).unfocus();
    // Google needs none of the form, so a half-filled one must not block it or
    // leave a stale validation error on screen.
    setState(() => _submissionError = null);
    final created = await widget.viewModel.signInWithGoogle();
    if (!created) return;
    // No password was chosen, so a half-filled form must not turn into a save
    // prompt for a credential the user never typed.
    TextInput.finishAutofillContext(shouldSave: false);
    if (mounted) {
      _email.clear();
      _password.clear();
      _confirmPassword.clear();
    }
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _formKey,
    // Groups the three fields into one new credential for the platform autofill
    // service, which is what external managers (Bitwarden, 1Password) read, and
    // is what lets them offer a generated password. Teardown cancels rather than
    // commits, so only a created account offers to save.
    child: AutofillGroup(
      onDisposeAction: AutofillContextAction.cancel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Create an account',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 20),
          TextFormField(
            enabled: !widget.viewModel.isBusy,
            controller: _email,
            validator: widget.viewModel.validateEmail,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            enableSuggestions: false,
            // Deliberately `username` and not `newUsername`: iOS maps only the
            // first hint, and only a username content type keeps this field in the
            // same password autofill context as the fields below.
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
            // `newPassword`, not `password`, so managers offer to generate one
            // instead of filling an existing credential.
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.next,
            helperText: 'At least 12 characters',
          ),
          const SizedBox(height: 16),
          TextFormField(
            enabled: !widget.viewModel.isBusy,
            controller: _confirmPassword,
            validator: (value) =>
                widget.viewModel.validateConfirmPassword(value, _password.text),
            obscureText: _obscurePassword,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.done,
            // Also `newPassword`: Android services fill both boxes from one
            // generated value. iOS populates only the focused field, so this field
            // still has to be filled by hand there.
            autofillHints: const [AutofillHints.newPassword],
            onFieldSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Confirm password',
              prefixIcon: Icon(Icons.lock_outline_rounded, size: 20),
            ),
          ),
          const SizedBox(height: 24),
          AppButton.primary(
            onPressed: _submit,
            label: 'Create account',
            icon: Icons.arrow_forward_rounded,
            iconAlignment: IconAlignment.end,
            isLoading: widget.viewModel.isBusy,
            loadingLabel: 'Creating account',
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
          ],
          if (_submissionError case final error?) ...[
            const SizedBox(height: 16),
            InlineNotice(message: error, isError: true),
          ],
          const SizedBox(height: 8),
          TextButton(
            onPressed: widget.viewModel.isBusy ? null : widget.onBackToSignIn,
            child: const Text('Already have an account? Sign in'),
          ),
        ],
      ),
    ),
  );
}
