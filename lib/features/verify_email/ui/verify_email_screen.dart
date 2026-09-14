import 'package:flutter/material.dart';

import '../../../ui/core/auth_screen_scaffold.dart';
import '../../auth/auth_repository.dart';
import '../verify_email_view_model.dart';
import 'verify_email_form.dart';

class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({
    super.key,
    required this.auth,
    required this.onSignIn,
  });

  final AuthRepository auth;
  final VoidCallback onSignIn;

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  late final _viewModel = VerifyEmailViewModel(auth: widget.auth);

  @override
  Widget build(BuildContext context) {
    final email = _viewModel.email;
    return AuthScreenScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.mark_email_unread_outlined, size: 40),
          const SizedBox(height: 24),
          Text(
            'Check your email.',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 16),
          // Deliberately conditional: the server answers an
          // already-registered address exactly as it answers a new one,
          // so this copy must not imply that an account was created.
          Text(
            email == null
                ? 'If that address is not already registered, we sent it a six-digit code. It expires in 10 minutes.'
                : 'If $email is not already registered, we sent it a six-digit code. It expires in 10 minutes.',
          ),
          const SizedBox(height: 32),
          VerifyEmailForm(viewModel: _viewModel, onSignIn: widget.onSignIn),
        ],
      ),
    );
  }
}
