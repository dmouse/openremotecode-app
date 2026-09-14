import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../domain/chat_models.dart';
import 'activity_row.dart';
import 'activity_presentation.dart';

class SubtaskView extends StatelessWidget {
  const SubtaskView({
    super.key,
    required this.task,
    required this.online,
    this.onOpen,
  });
  final ChatSubtask task;
  final bool online;
  final VoidCallback? onOpen;

  String get _detail {
    final active = task.active;
    final status = switch (task.status) {
      'pending' => 'Pending',
      'running' => 'Running',
      'retry' => 'Retrying',
      'completed' => 'Completed',
      'error' => 'Failed',
      _ => 'Status unavailable',
    };
    final count = task.toolCalls;
    final duration = task.durationMs;
    final seconds = duration == null ? null : duration ~/ 1000;
    return [
      if (active && !online)
        'Offline · last known: ${status.toLowerCase()}'
      else
        status,
      if (count != null)
        '$count${task.statsComplete == false ? '+' : ''} toolcall${count == 1 && task.statsComplete != false ? '' : 's'}',
      if (!active && seconds != null)
        if (seconds < 60)
          '${seconds}s'
        else
          '${seconds ~/ 60}m ${seconds % 60}s',
      if (task.sessionId == null && task.status != 'pending')
        'Chat unavailable',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final row = ActivityRow(
      running: online && task.status == 'running',
      minHeight: onOpen == null ? 32 : 48,
      icon: task.status == 'completed'
          ? Icons.check
          : task.status == 'error'
          ? Icons.error_outline
          : Icons.account_tree_outlined,
      color: task.status == 'error'
          ? Theme.of(context).colorScheme.error
          : AppTheme.subtaskTitle,
      title: Text(
        task.label,
        style: ActivityPresentation.style(context, AppTheme.subtaskTitle),
      ),
      metadata: Text(
        detail,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppTheme.muted,
          fontSize: ActivityPresentation.detailSize,
        ),
      ),
      trailing: onOpen == null
          ? null
          : const Icon(
              Icons.chevron_right,
              size: ActivityPresentation.iconSize,
              applyTextScaling: true,
              color: AppTheme.muted,
            ),
    );
    return Semantics(
      label: '${task.label}. $detail',
      button: onOpen != null,
      onTap: onOpen,
      child: ExcludeSemantics(
        child: onOpen == null
            ? row
            : TextButton(
                onPressed: onOpen,
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(48, 48),
                  foregroundColor: AppTheme.ink,
                  disabledForegroundColor: AppTheme.muted,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: row,
              ),
      ),
    );
  }
}
