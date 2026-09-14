import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../domain/chat_models.dart';
import 'activity_row.dart';
import 'shell_view.dart';
import '../domain/activity.dart';
import 'activity_presentation.dart';

class ToolView extends StatelessWidget {
  const ToolView({
    super.key,
    required this.tool,
    required this.online,
    required this.active,
    this.expanded = false,
    this.onToggle,
    this.activity,
  });
  final ChatTool tool;
  final bool online, active;
  final bool expanded;
  final VoidCallback? onToggle;
  final AgentActivity? activity;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = ActivityPresentation.forKind(
      activity?.kind ?? tool.operation,
    );
    final running =
        online && active && (activity?.running ?? (tool.status == 'running'));
    final state =
        activity?.state ?? (tool.status == 'error' ? 'failed' : tool.status);
    final status = switch (state) {
      'pending' => 'Pending',
      'running' => 'Running',
      'completed' => 'Completed',
      'failed' => 'Failed',
      'cancelled' => 'Cancelled',
      _ => 'Status unavailable',
    };
    final unfinished = ['pending', 'running'].contains(state);
    final duration = tool.durationMs;
    final detail = [
      if (unfinished && !online)
        'Offline · last known: ${status.toLowerCase()}'
      else if (unfinished && !active)
        'Last known: ${status.toLowerCase()}'
      else
        status,
      if (!unfinished && duration != null)
        if (duration < 1000)
          '${duration}ms'
        else if (duration < 60000)
          '${(duration / 1000).toStringAsFixed(1)}s'
        else
          '${duration ~/ 60000}m ${(duration % 60000) ~/ 1000}s',
    ].join(' · ');
    final error = state == 'failed';
    if (tool.shell case final shell?) {
      return ShellView(
        shell: shell,
        detail: detail,
        waiting: unfinished,
        failed: error,
        expanded: expanded,
        onToggle: onToggle,
        description: ActivityPresentation.preview(tool.description, label),
        running: running,
      );
    }
    final title =
        tool.description ??
        (activity != null || tool.operation == 'execute' ? label : '');
    return Semantics(
      label:
          '$label${title.isEmpty || title == label ? '' : ' $title'}. $detail',
      child: ExcludeSemantics(
        child: ActivityRow(
          icon: error ? Icons.error_outline : icon,
          running: running,
          color: error
              ? Theme.of(context).colorScheme.error
              : AppTheme.subtaskTitle,
          title: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: title),
                if (state != 'completed')
                  TextSpan(
                    text: title.isEmpty ? detail : ' ($detail)',
                    style: TextStyle(
                      fontSize: ActivityPresentation.detailSize,
                      color: error
                          ? Theme.of(context).colorScheme.error
                          : AppTheme.muted,
                    ),
                  ),
              ],
            ),
            style: ActivityPresentation.style(context, AppTheme.subtaskTitle),
          ),
        ),
      ),
    );
  }
}
