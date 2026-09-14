import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../conversation_view_model.dart';
import '../domain/tool_run.dart';
import 'activity_presentation.dart';
import 'activity_row.dart';
import 'tool_view.dart';

/// A condensed row standing in for a run of consecutive tool-call parts.
/// Tapping it opens [showToolRunSheet], which lists the original rows.
class ToolRunView extends StatelessWidget {
  const ToolRunView({
    super.key,
    required this.run,
    required this.model,
    required this.messageId,
    required this.active,
  });
  final ToolRun run;
  final ConversationViewModel model;
  final String messageId;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final failed = run.failed;
    final color = failed
        ? Theme.of(context).colorScheme.error
        : AppTheme.subtaskTitle;
    return Semantics(
      label: '${run.summary}. Double tap to view details.',
      child: ExcludeSemantics(
        child: TextButton(
          onPressed: () => showToolRunSheet(
            context,
            model: model,
            messageId: messageId,
            leadingPartId: run.parts.first.id,
          ),
          style: TextButton.styleFrom(
            foregroundColor: color,
            minimumSize: const Size(48, ActivityPresentation.rowHeight),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: EdgeInsets.zero,
          ),
          child: ActivityRow(
            icon: failed ? Icons.error_outline : Icons.checklist,
            color: color,
            running: active && run.running,
            title: Text(
              run.summary,
              style: ActivityPresentation.style(context, color),
            ),
            trailing: const Icon(
              Icons.chevron_right,
              size: ActivityPresentation.iconSize,
              applyTextScaling: true,
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showToolRunSheet(
  BuildContext context, {
  required ConversationViewModel model,
  required String messageId,
  required String leadingPartId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.background,
    showDragHandle: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => SafeArea(
      top: false,
      child: ListenableBuilder(
        listenable: model,
        builder: (context, _) {
          final run = findToolRun(
            visibleMessages(model.messages),
            messageId,
            leadingPartId,
          );
          if (run == null) {
            // The message aged out of bounded in-memory history while the
            // sheet was open -- there is nothing left to show.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.of(sheetContext).canPop()) {
                Navigator.of(sheetContext).pop();
              }
            });
            return const SizedBox.shrink();
          }
          return _ToolRunSheetBody(run: run, model: model);
        },
      ),
    ),
  );
}

class _ToolRunSheetBody extends StatefulWidget {
  const _ToolRunSheetBody({required this.run, required this.model});
  final ToolRun run;
  final ConversationViewModel model;

  @override
  State<_ToolRunSheetBody> createState() => _ToolRunSheetBodyState();
}

class _ToolRunSheetBodyState extends State<_ToolRunSheetBody> {
  // Sheet-local: expand state need not survive after it closes.
  final _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final parts = widget.run.parts;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: Text(
                  widget.run.summary,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < parts.length; i++) ...[
                    if (i > 0)
                      parts[i].tool!.operation == parts[i - 1].tool!.operation
                          ? Padding(
                              padding: EdgeInsets.only(
                                left:
                                    ActivityPresentation.gutterFor(context) /
                                        2 -
                                    0.5,
                              ),
                              child: Container(
                                width: 1,
                                height: 10,
                                color: AppTheme.border,
                              ),
                            )
                          : const SizedBox(height: 12),
                    ToolView(
                      key: ValueKey(parts[i].id),
                      tool: parts[i].tool!,
                      activity: parts[i].activity,
                      expanded: _expanded.contains(parts[i].id),
                      onToggle: () => setState(() {
                        if (!_expanded.remove(parts[i].id)) {
                          _expanded.add(parts[i].id);
                        }
                      }),
                      online: model.online(),
                      active:
                          model.activityLive &&
                          (parts[i].activity != null ||
                              ['busy', 'retry'].contains(model.status)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
