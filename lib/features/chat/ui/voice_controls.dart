import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../voice_view_model.dart';
import 'voice_note_bubble.dart';

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
        ? 'Stop recording and preview'
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
    icon: ValueListenableBuilder<double>(
      valueListenable: voice.level,
      builder: (context, level, _) => AnimatedScale(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 100),
        scale: voice.isNote && !MediaQuery.disableAnimationsOf(context)
            ? 1 + level * .3
            : 1,
        child: Icon(voice.isNote ? Icons.mic : Icons.mic_none),
      ),
    ),
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
    if (voice.pendingNote case final note?) {
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .45,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              VoiceNoteBubble(
                note: note,
                preview: true,
                statusLabel: voice.noteDeliveryUnconfirmed
                    ? 'Voice message · Delivery unconfirmed'
                    : voice.phase == VoicePhase.sending
                    ? 'Voice message · Sending…'
                    : null,
              ),
              if (voice.error != null)
                Text(
                  voice.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: voice.phase == VoicePhase.sending
                        ? null
                        : () async {
                            await voice.cancel();
                          },
                    child: const Text('Discard'),
                  ),
                  FilledButton(
                    onPressed: voice.canSendNote ? voice.submitNote : null,
                    child: Text(
                      voice.phase == VoicePhase.sending
                          ? 'Sending…'
                          : 'Send voice message',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    if (voice.isNote && voice.phase == VoicePhase.listening) {
      return _RecordingBar(voice: voice);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              liveRegion: true,
              label: voice.error ?? voice.status,
              excludeSemantics: true,
              child: ValueListenableBuilder<int>(
                valueListenable: voice.recordedDuration,
                builder: (context, _, _) => Text(
                  voice.error ??
                      (voice.isNote && voice.phase == VoicePhase.listening
                          ? '${voice.status} · ${(voice.recordedMilliseconds ~/ 1000)}s'
                          : voice.status),
                  key: const ValueKey('voice-status'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: voice.error != null
                        ? Theme.of(context).colorScheme.error
                        : AppTheme.of(context).ink,
                  ),
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

class _RecordingBar extends StatelessWidget {
  const _RecordingBar({required this.voice});
  final VoiceViewModel voice;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.of(context).codeSurface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: ValueListenableBuilder<double>(
                    valueListenable: voice.level,
                    builder: (context, level, _) => AnimatedContainer(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 100),
                      padding: EdgeInsets.all(
                        8 +
                            (MediaQuery.disableAnimationsOf(context)
                                ? 0
                                : level * 4),
                      ),
                      decoration: const BoxDecoration(
                        color: AppTheme.lime,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.mic, color: AppTheme.ink),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  label: 'Microphone on. Recording voice message',
                  liveRegion: true,
                  child: const ExcludeSemantics(
                    child: Text(
                      'Recording voice message',
                      key: ValueKey('voice-status'),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<int>(
            valueListenable: voice.recordedDuration,
            builder: (context, milliseconds, _) {
              final seconds = milliseconds ~/ 1000;
              return Text(
                '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')} / 1:00',
                key: const ValueKey('voice-duration'),
                semanticsLabel: 'Recorded $seconds seconds. Maximum 60 seconds',
              );
            },
          ),
          const SizedBox(height: 8),
          ExcludeSemantics(
            child: SizedBox(
              height: 32,
              child: ValueListenableBuilder<List<double>>(
                valueListenable: voice.waveform,
                builder: (context, levels, _) => Row(
                  key: const ValueKey('voice-live-waveform'),
                  children: [
                    for (var i = 0; i < 24; i++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1),
                          child: Center(
                            child: AnimatedContainer(
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 100),
                              height: MediaQuery.disableAnimationsOf(context)
                                  ? 4
                                  : 4 +
                                        (i < 24 - levels.length
                                                ? 0
                                                : levels[i -
                                                      (24 - levels.length)]) *
                                            28,
                              decoration: BoxDecoration(
                                color: AppTheme.of(context).ink,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              TextButton(onPressed: voice.cancel, child: const Text('Cancel')),
              TextButton(
                onPressed: voice.finishNote,
                child: const Text('Stop'),
              ),
              FilledButton.icon(
                onPressed: () => voice.finishNote(send: true),
                icon: const Icon(Icons.send),
                label: const Text('Send'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
