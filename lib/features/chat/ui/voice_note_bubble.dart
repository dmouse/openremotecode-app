import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../domain/voice_note.dart';
import '../voice_playback_view_model.dart';

class VoiceNoteBubble extends StatefulWidget {
  const VoiceNoteBubble({
    super.key,
    required this.transcript,
    this.note,
    this.playback,
    this.preview = false,
    this.statusLabel,
  });
  final String? statusLabel;
  final String transcript;
  final VoiceNote? note;
  final VoicePlaybackViewModel? playback;
  final bool preview;
  @override
  State<VoiceNoteBubble> createState() => _VoiceNoteBubbleState();
}

class _VoiceNoteBubbleState extends State<VoiceNoteBubble> {
  bool _transcriptVisible = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.playback ?? const AlwaysStoppedAnimation(0),
    builder: (context, _) {
      final note = widget.note?.transcript == widget.transcript
          ? widget.note
          : null;
      final player = widget.playback;
      final playing =
          note != null && player?.id == note.id && player?.playing == true;
      final duration = note?.duration;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.of(context).codeSurface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: playing ? 'Pause voice note' : 'Play voice note',
                  onPressed:
                      note == null ||
                          player == null ||
                          player.busy ||
                          !player.canPlay
                      ? null
                      : () => player.toggle(note),
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.statusLabel ??
                            (widget.preview
                                ? 'Voice note · Not sent'
                                : 'Voice note'),
                      ),
                      if (duration != null)
                        Text(
                          '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}',
                        ),
                      if (note == null)
                        const Text('Audio unavailable on this device'),
                      if (note != null && player?.id == note.id)
                        LinearProgressIndicator(
                          value:
                              (player!.position /
                                      duration!.inMilliseconds.clamp(1, 60000))
                                  .clamp(0, 1),
                          semanticsLabel: 'Voice playback progress',
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (player?.error != null)
              Text(
                player!.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            TextButton(
              onPressed: () =>
                  setState(() => _transcriptVisible = !_transcriptVisible),
              child: Text(
                _transcriptVisible ? 'Hide transcript' : 'Transcribe',
              ),
            ),
            if (_transcriptVisible) SelectableText(widget.transcript),
          ],
        ),
      );
    },
  );
}
