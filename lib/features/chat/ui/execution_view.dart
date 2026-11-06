import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import 'activity_row.dart';
import 'activity_presentation.dart';

/// Passive execution history. Hiding details removes them from both the widget and
/// semantics trees; it does not erase the encrypted snapshot from memory.
class ExecutionView extends StatelessWidget {
  const ExecutionView({
    super.key,
    required this.source,
    required this.output,
    required this.truncated,
    this.isCode = false,
    required this.detail,
    required this.waiting,
    required this.failed,
    required this.expanded,
    required this.onToggle,
    required this.description,
    required this.running,
  });

  final String source, output;
  final bool truncated, isCode;
  final String detail;
  final bool waiting, failed, expanded;
  final VoidCallback? onToggle;
  final String description;
  final bool running;

  static String _plain(String text) => text
      .replaceAll(RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\|$)'), '')
      .replaceAll(RegExp(r'(?:\x1b\[|\x9b)[0-?]*[ -/]*[@-~]'), '')
      .replaceAll(RegExp(r'\x1b[@-_]'), '')
      .replaceAll(RegExp(r'\r\n?'), '\n')
      .replaceAll(
        RegExp(
          r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',
        ),
        '',
      );

  @override
  Widget build(BuildContext context) {
    final color = failed
        ? Theme.of(context).colorScheme.error
        : AppTheme.of(context).subtaskTitle;
    final codeStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.4,
      color: AppTheme.of(context).ink,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: expanded,
          child: TextButton(
            onPressed: onToggle,
            style: TextButton.styleFrom(
              foregroundColor: color,
              minimumSize: const Size(48, ActivityPresentation.rowHeight),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: EdgeInsets.zero,
            ),
            child: ActivityRow(
              icon: failed
                  ? Icons.error_outline
                  : isCode
                  ? Icons.code
                  : Icons.terminal,
              color: color,
              running: running,
              title: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: description),
                    TextSpan(
                      text: ' · $detail',
                      style: const TextStyle(
                        fontSize: ActivityPresentation.detailSize,
                      ),
                    ),
                  ],
                ),
                style: ActivityPresentation.style(context, color),
              ),
              trailing: Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: ActivityPresentation.iconSize,
                applyTextScaling: true,
              ),
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: EdgeInsets.only(
              left: ActivityPresentation.gutterFor(context),
              bottom: 8,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppTheme.of(context).codeSurface,
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(isCode ? 'Code' : 'Command'),
                    SelectableText(
                      minLines: 3,
                      source.isEmpty
                          ? (isCode
                                ? 'Code unavailable'
                                : 'Command unavailable')
                          : _plain(source),
                      style: codeStyle,
                    ),
                    const SizedBox(height: 12),
                    const Text('Output'),
                    SelectableText(
                      minLines: 3,
                      output.isNotEmpty
                          ? _plain(output)
                          : truncated
                          ? 'Output shortened for display.'
                          : waiting
                          ? 'Waiting for output…'
                          : 'No output',
                      style: codeStyle,
                    ),
                    if (truncated)
                      Text(
                        '${isCode ? 'Code' : 'Shell'} details shortened for display.',
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
