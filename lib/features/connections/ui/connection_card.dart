import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../../../ui/core/status_badge.dart';
import '../domain/remote_connection.dart';
import '../domain/connection_color.dart';
import '../../../ui/core/chat_avatar.dart';

class ConnectionCard extends StatelessWidget {
  const ConnectionCard({
    super.key,
    required this.connection,
    this.isSelected = false,
    this.onSelect,
    this.onOpen,
    this.onDelete,
    this.onRename,
    this.isDeleting = false,
    this.isRenaming = false,
    this.color = ConnectionColor.lime,
    this.onColor,
  });
  final RemoteConnection connection;
  final bool isSelected;
  final VoidCallback? onSelect;
  final VoidCallback? onOpen;
  final VoidCallback? onDelete;
  final VoidCallback? onRename;
  final bool isDeleting;
  final bool isRenaming;
  final ConnectionColor color;
  final VoidCallback? onColor;

  bool get _isOffline => connection.status == ConnectionStatus.offline;

  Color _selectionColor(BuildContext context) => _isOffline
      ? AppTheme.of(context).muted
      : AppTheme.of(context).selectedBorder;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: isSelected,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen ?? onSelect,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            border: Border.all(
              color: _isOffline
                  ? AppTheme.of(context).muted
                  : isSelected
                  ? _selectionColor(context)
                  : AppTheme.of(context).border,
              width: isSelected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: connectionAccent(color),
                foregroundColor: AppTheme.ink,
                child: const Icon(Icons.computer_rounded, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connection.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (isSelected)
                      Text(
                        'Selected',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: _selectionColor(context),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    const SizedBox(height: 10),
                    StatusBadge(
                      label: connection.statusLabel,
                      tone: switch (connection.status) {
                        ConnectionStatus.online => StatusTone.success,
                        ConnectionStatus.offline => StatusTone.neutral,
                        ConnectionStatus.verificationRequired =>
                          StatusTone.warning,
                        ConnectionStatus.identityChanged => StatusTone.error,
                        ConnectionStatus.unknown => StatusTone.info,
                      },
                      icon: switch (connection.status) {
                        ConnectionStatus.online => Icons.check_circle,
                        ConnectionStatus.offline => Icons.cloud_off_outlined,
                        ConnectionStatus.verificationRequired =>
                          Icons.shield_outlined,
                        ConnectionStatus.identityChanged =>
                          Icons.gpp_bad_outlined,
                        ConnectionStatus.unknown => Icons.help_outline,
                      },
                    ),
                    if (onOpen != null)
                      TextButton.icon(
                        onPressed: onOpen,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Open projects'),
                      ),
                    if (connection.verificationMessage case final message?) ...[
                      const SizedBox(height: 12),
                      Text(message),
                    ],
                  ],
                ),
              ),
              if (isDeleting || isRenaming)
                Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      semanticsLabel: isDeleting
                          ? 'Revoking connection'
                          : 'Saving name',
                    ),
                  ),
                )
              else
                PopupMenuButton<_ConnectionAction>(
                  tooltip: 'Connection options',
                  enabled:
                      onRename != null || onDelete != null || onColor != null,
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) {
                    switch (action) {
                      case _ConnectionAction.color:
                        onColor?.call();
                      case _ConnectionAction.rename:
                        onRename?.call();
                      case _ConnectionAction.delete:
                        onDelete?.call();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: _ConnectionAction.color,
                      enabled: onColor != null,
                      child: const Text('Color'),
                    ),
                    PopupMenuItem(
                      value: _ConnectionAction.rename,
                      enabled: onRename != null,
                      child: const Text('Rename'),
                    ),
                    PopupMenuItem(
                      value: _ConnectionAction.delete,
                      enabled: onDelete != null,
                      child: const Text('Delete'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

enum _ConnectionAction { rename, delete, color }
