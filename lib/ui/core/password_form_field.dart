import 'package:flutter/material.dart';

/// A password [TextFormField] with a show/hide toggle. The obscured state is
/// owned by the caller (not this widget) so a confirm-password field elsewhere
/// in the same form can share it without getting a toggle of its own.
class PasswordFormField extends StatelessWidget {
  const PasswordFormField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.validator,
    required this.obscureText,
    required this.onToggleObscureText,
    required this.autofillHints,
    required this.textInputAction,
    this.helperText,
    this.onFieldSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final String? Function(String?) validator;
  final bool obscureText;
  final VoidCallback onToggleObscureText;
  final Iterable<String> autofillHints;
  final TextInputAction textInputAction;
  final String? helperText;
  final ValueChanged<String>? onFieldSubmitted;

  @override
  Widget build(BuildContext context) => TextFormField(
    enabled: enabled,
    controller: controller,
    validator: validator,
    obscureText: obscureText,
    autocorrect: false,
    enableSuggestions: false,
    keyboardType: TextInputType.visiblePassword,
    textInputAction: textInputAction,
    autofillHints: autofillHints,
    onFieldSubmitted: onFieldSubmitted,
    decoration: InputDecoration(
      labelText: 'Password',
      helperText: helperText,
      prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
      suffixIcon: IconButton(
        tooltip: obscureText ? 'Show password' : 'Hide password',
        onPressed: enabled ? onToggleObscureText : null,
        icon: Icon(
          obscureText
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
          size: 20,
        ),
      ),
    ),
  );
}
