import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../domain/chat_models.dart';
import 'activity_row.dart';
import 'activity_presentation.dart';

class ThoughtView extends StatelessWidget {
  const ThoughtView({super.key, required this.part, required this.active});
  final ChatMessagePart part;
  final bool active;

  String get _preview {
    // A bounded excerpt of provider text, never an invented reasoning summary.
    final line = part.text.trimLeft().split('\n').first.trim();
    final plain = line
        .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
        .replaceAll('**', '')
        .replaceAll('`', '');
    return plain.length > 100 ? '${plain.substring(0, 100)}…' : plain;
  }

  String? get _duration {
    final ms = part.durationMs;
    if (ms == null) return null;
    if (ms < 1000) return '${ms}ms';
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    return '${ms ~/ 60000}m ${(ms % 60000) ~/ 1000}s';
  }

  @override
  Widget build(BuildContext context) {
    // Execution state is independent from whether visibility/transport currently
    // permits animation. A known running thought never becomes "Thought" merely
    // because a session-wide busy snapshot lags behind its start event.
    final thinking =
        part.activity?.running ??
        (active && part.start != null && part.end == null);
    final preview = _preview;
    final failed = part.activity?.state == 'failed';
    final label = failed
        ? 'Thought failed'
        : part.activity?.state == 'cancelled'
        ? 'Thought cancelled'
        : thinking
        ? 'Thinking'
        : 'Thought';
    final color = failed
        ? Theme.of(context).colorScheme.error
        : AppTheme.warning;
    final duration = _duration;
    return ActivityRow(
      icon: failed ? Icons.error_outline : Icons.psychology_outlined,
      running: thinking,
      animate: active,
      color: color,
      title: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (preview.isNotEmpty)
              TextSpan(
                text: ': $preview',
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            if (duration != null)
              TextSpan(
                text: ' · $duration',
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            if (thinking) const TextSpan(text: '…'),
            if (thinking && !active) const TextSpan(text: ' · last known'),
          ],
        ),
        style: ActivityPresentation.style(context, color),
      ),
    );
  }
}
