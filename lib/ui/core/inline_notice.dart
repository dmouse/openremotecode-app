import 'package:flutter/material.dart';

class InlineNotice extends StatelessWidget {
  const InlineNotice({super.key, required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isError ? colors.errorContainer : colors.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          message,
          style: TextStyle(
            color: isError
                ? colors.onErrorContainer
                : colors.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
