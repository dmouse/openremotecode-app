import 'package:flutter/material.dart';

/// Shown wherever a screen gates its content on [ServerSettingsViewModel]
/// finishing its initial load.
class ServerSettingsLoadingIndicator extends StatelessWidget {
  const ServerSettingsLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    child: CircularProgressIndicator(semanticsLabel: 'Loading server settings'),
  );
}
