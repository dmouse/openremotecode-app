import 'package:flutter/material.dart';

/// Shared shell for the login, registration, and verify-email screens: a
/// centered, keyboard-safe column capped at the 460px content width used
/// across the app (see docs/design.md).
class AuthScreenScaffold extends StatelessWidget {
  const AuthScreenScaffold({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: child,
          ),
        ),
      ),
    ),
  );
}
