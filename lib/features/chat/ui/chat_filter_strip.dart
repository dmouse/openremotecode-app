import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../../../ui/core/chat_avatar.dart';
import '../chats_home_view_model.dart';

/// One left-anchored, lazy strip. Hue identifies connections; blue plus a folder
/// icon identifies folders. Neither style is a presence or trust signal.
class ChatFilterStrip extends StatelessWidget {
  const ChatFilterStrip({
    super.key,
    required this.model,
    required this.onChanged,
  });
  final ChatsHomeViewModel model;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.of(context);
    final machines = model.machines;
    final folders = model.folderSources;
    final height = math.max(
      48.0,
      MediaQuery.textScalerOf(context).scale(12) * 1.4 + 32,
    );
    Widget chip({
      required Key key,
      required String label,
      required String tooltip,
      required bool selected,
      required VoidCallback select,
      Widget? avatar,
      Color? foreground,
      Color? background,
      Color? selectedColor,
      Color? border,
    }) => ChoiceChip(
      key: key,
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200),
        child: Text(
          label,
          textAlign: TextAlign.start,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      labelStyle: Theme.of(context).textTheme.labelMedium
          ?.copyWith(fontSize: 12, color: foreground ?? colors.ink),
      tooltip: tooltip,
      selected: selected,
      showCheckmark: true,
      checkmarkColor: foreground ?? colors.ink,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      avatar: avatar,
      backgroundColor: background ?? colors.background,
      selectedColor: selectedColor ?? colors.neutralSurface,
      side: BorderSide(color: border ?? colors.border),
      onSelected: (_) {
        select();
        onChanged();
      },
    );

    return SizedBox(
      width: double.infinity,
      height: height,
      child: ListView.separated(
        key: const ValueKey('chat-filter-strip'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: 1 + machines.length + folders.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == 0) {
            return chip(
              key: const ValueKey('filter-all'),
              label: 'All',
              tooltip: 'All connections and folders',
              selected:
                  model.selectedMachine == null && model.selectedFolder == null,
              select: () => model.selectMachine(null),
            );
          }
          if (index <= machines.length) {
            final machine = machines[index - 1];
            final accent = connectionAccent(
              model.connections.colorFor(machine.id),
            );
            final selected = model.selectedMachine == machine.id;
            return chip(
              key: ValueKey(('machine-filter', machine.id)),
              label: machine.name,
              tooltip: 'Connection: ${machine.name} · ${machine.statusLabel}',
              selected: selected,
              background: accent.withValues(alpha: .12),
              selectedColor: accent,
              foreground: selected ? AppTheme.ink : colors.ink,
              avatar: ExcludeSemantics(
                child: CircleAvatar(
                  radius: 10,
                  backgroundColor: accent,
                  child: const Icon(
                    Icons.computer_outlined,
                    size: 13,
                    color: AppTheme.ink,
                  ),
                ),
              ),
              select: () => model.selectMachine(machine.id),
            );
          }
          final source = folders[index - 1 - machines.length];
          final project = source.project!;
          final machine = machines.firstWhere(
            (m) => m.id == source.connectorId,
          );
          return chip(
            key: ValueKey(('folder-filter', source.connectorId, project.path)),
            label: model.folderLabel(source),
            tooltip: 'Folder: ${machine.name} · ${project.path}',
            selected:
                model.selectedFolder == (source.connectorId, project.path),
            foreground: colors.info,
            background: colors.infoSurface.withValues(alpha: .35),
            selectedColor: colors.infoSurface,
            border: colors.info,
            avatar: ExcludeSemantics(
              child: Icon(Icons.folder_outlined, size: 16, color: colors.info),
            ),
            select: () => model.selectFolder(source),
          );
        },
      ),
    );
  }
}
