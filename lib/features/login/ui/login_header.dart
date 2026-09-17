import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';

class LoginHeader extends StatelessWidget {
  const LoginHeader({super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          Icon(Icons.terminal_rounded, size: 26, color: AppTheme.ink),
          Text(
            'Open Remote Code',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
              color: AppTheme.ink,
            ),
          ),
        ],
      ),
      const SizedBox(height: 44),
      Text(
        'Your workspace.\nWithin reach.',
        style: Theme.of(context).textTheme.headlineLarge,
      ),
      const SizedBox(height: 16),
      const Text(
        'Sign in to pick up where you left off.\nYour local OpenCode, wherever you are.',
      ),
    ],
  );
}
