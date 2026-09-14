import 'package:flutter/material.dart';

/// The Google action shared by the sign-in and create-account screens.
///
/// It is one widget with one label on both, because it is one operation: the
/// server creates the account if the assertion reaches no existing one, so
/// offering "sign in with Google" and "sign up with Google" as separate choices
/// would be a distinction the product does not make.
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({
    super.key,
    required this.onPressed,
    required this.isBusy,
  });

  final VoidCallback? onPressed;
  final bool isBusy;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _OrDivider(),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: isBusy ? null : onPressed,
        // The wordmark is deliberately not reproduced: shipping Google's asset
        // brings brand-guideline obligations, and a neutral mark is honest about
        // what the button does without imitating Google's own control.
        icon: const Icon(Icons.account_circle_outlined, size: 20),
        label: const Text('Continue with Google'),
      ),
    ],
  );
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Expanded(child: Divider()),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text('or', style: Theme.of(context).textTheme.bodySmall),
      ),
      const Expanded(child: Divider()),
    ],
  );
}
