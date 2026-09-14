import 'package:flutter/material.dart';

abstract final class ActivityPresentation {
  static const fontSize = 12.0;
  static const detailSize = 11.0;
  static const iconSize = fontSize;
  static const lineHeight = 1.35;
  static const rowHeight = 32.0;
  static double scaledIconSize(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(iconSize);
  static double gutterFor(BuildContext context) => scaledIconSize(context) + 8;
  static double firstLineHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(fontSize) * lineHeight;
  static TextStyle style(BuildContext context, Color color) =>
      Theme.of(context).textTheme.bodyMedium!
          .copyWith(fontSize: fontSize, height: lineHeight, color: color);
  static (String, IconData) forKind(String kind) => switch (kind) {
    'reasoning' => ('Thought', Icons.psychology_outlined),
    'read' => ('Read', Icons.arrow_forward),
    'write' => ('Write', Icons.note_add_outlined),
    'edit' => ('Edit', Icons.edit_outlined),
    'apply_patch' => ('Apply patch', Icons.edit_note),
    'search' => ('Search', Icons.search),
    'list' => ('List', Icons.folder_outlined),
    'execute' => ('Run command', Icons.terminal),
    'fetch' => ('Fetch', Icons.language),
    'update_tasks' => ('Update task list', Icons.checklist),
    'subtask' => ('Subtask', Icons.account_tree_outlined),
    _ => ('Tool', Icons.settings_outlined),
  };
  static String preview(String? description, String fallback) {
    final text = description?.trim().split('\n').first.trim() ?? '';
    if (text.isEmpty) return fallback;
    return text.characters.length > 100
        ? '${text.characters.take(100)}…'
        : text;
  }
}
