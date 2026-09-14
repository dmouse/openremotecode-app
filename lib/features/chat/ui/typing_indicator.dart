import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import 'activity_animation.dart';

class TypingIndicator extends StatelessWidget {
  const TypingIndicator({
    super.key,
    required this.animate,
    this.sending = false,
  });
  final bool animate, sending;
  @override
  Widget build(BuildContext context) => Semantics(
    label: sending ? 'Sending message' : 'Agent is working',
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppTheme.codeSurface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: ActivityPulse(
              kind: ActivityPulseKind.dots,
              running: true,
              animate: animate,
              color: AppTheme.muted,
            ),
          ),
        ),
      ),
    ),
  );
}
