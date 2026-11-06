import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../voice_view_model.dart';

class VoiceNoteButton extends StatelessWidget {
  const VoiceNoteButton({
    super.key,
    required this.voice,
    required this.enabled,
  });
  final VoiceViewModel voice;
  final bool enabled;
  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('voice-note'),
    tooltip: voice.isNote
        ? 'Stop recording and use text'
        : 'Record a voice note',
    onPressed: voice.isNote && voice.phase == VoicePhase.listening
        ? () => unawaited(voice.finishNote())
        : enabled && voice.canStart
        ? () => unawaited(voice.start(VoiceMode.note))
        : null,
    style: IconButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: voice.isNote
          ? Theme.of(context).colorScheme.error
          : AppTheme.of(context).ink,
    ),
    icon: Icon(voice.isNote ? Icons.stop_circle_outlined : Icons.mic_none),
  );
}

class VoiceCallButton extends StatelessWidget {
  const VoiceCallButton({
    super.key,
    required this.voice,
    required this.onStart,
    required this.enabled,
  });
  final VoiceViewModel voice;
  final VoidCallback onStart;
  final bool enabled;
  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('voice-call'),
    tooltip: voice.isCall
        ? 'End voice call'
        : 'Start voice call · send speech automatically',
    onPressed: voice.isCall
        ? () => unawaited(voice.cancel())
        : enabled && voice.canStart
        ? onStart
        : null,
    style: IconButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: voice.isCall
          ? Theme.of(context).colorScheme.error
          : AppTheme.of(context).ink,
    ),
    icon: Icon(voice.isCall ? Icons.call_end : Icons.call_outlined),
  );
}

class VoiceStatusBar extends StatelessWidget {
  const VoiceStatusBar({super.key, required this.voice});
  final VoiceViewModel voice;
  @override
  Widget build(BuildContext context) {
    if (!voice.active && voice.error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                voice.error ?? voice.status,
                key: const ValueKey('voice-status'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: voice.error != null
                      ? Theme.of(context).colorScheme.error
                      : AppTheme.of(context).ink,
                ),
              ),
            ),
          ),
          if (voice.isCall)
            IconButton(
              tooltip: voice.muted ? 'Unmute microphone' : 'Mute microphone',
              onPressed: voice.phase == VoicePhase.listening
                  ? () => unawaited(voice.toggleMute())
                  : null,
              icon: Icon(voice.muted ? Icons.mic_off : Icons.mic),
            ),
          IconButton(
            tooltip: voice.active
                ? 'Discard recording and stop voice'
                : 'Dismiss voice message',
            onPressed: voice.active
                ? () => unawaited(voice.cancel())
                : voice.dismissError,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
