import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../domain/voice_note.dart';

/// Voice-origin text, not a playable recording. The transcript is already sent.
class VoiceNoteBubble extends StatefulWidget {
  const VoiceNoteBubble({
    super.key,
    required this.note,
    this.preview = false,
    this.statusLabel,
  });
  final VoiceNote note;
  final String? statusLabel;
  final bool preview;

  @override
  State<VoiceNoteBubble> createState() => _VoiceNoteBubbleState();
}

class _VoiceNoteBubbleState extends State<VoiceNoteBubble> {
  bool _transcriptVisible = false;

  @override
  void didUpdateWidget(VoiceNoteBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.id != widget.note.id ||
        oldWidget.note.transcript != widget.note.transcript) {
      _transcriptVisible = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.note.duration;
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.mic_none, semanticLabel: 'Sent using voice'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.statusLabel ??
                          (widget.preview
                              ? 'Voice message · Not sent'
                              : 'Voice message'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (duration != null)
                      Text(
                        '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}',
                        semanticsLabel:
                            'Recording duration ${duration.inSeconds} seconds',
                      ),
                    Text(
                      widget.preview
                          ? 'Audio not saved'
                          : 'Sent as text · Audio not saved',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          TextButton(
            onPressed: () =>
                setState(() => _transcriptVisible = !_transcriptVisible),
            child: Text(
              _transcriptVisible ? 'Hide transcript' : 'Show transcript',
            ),
          ),
          if (_transcriptVisible) SelectableText(widget.note.transcript),
        ],
      ),
    );
  }
}
