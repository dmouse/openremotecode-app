import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../../../ui/core/confirm_dialog.dart';
import '../../../ui/core/inline_notice.dart';
import '../../../ui/core/rename_dialog.dart';
import '../connections_view_model.dart';
import '../domain/remote_connection.dart';
import 'connection_card.dart';

class ConnectionsScreen extends StatelessWidget {
  const ConnectionsScreen({
    super.key,
    required this.viewModel,
    required this.onAddConnection,
    this.onOpenConnection,
  });
  final ConnectionsViewModel viewModel;
  final VoidCallback onAddConnection;
  final ValueChanged<RemoteConnection>? onOpenConnection;

  Future<void> _rename(
    BuildContext context,
    RemoteConnection connection,
  ) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(
        title: 'Rename connection',
        label: 'Name',
        initialValue: connection.name,
        validator: viewModel.validateName,
      ),
    );
    if (name != null) await viewModel.renameConnection(connection.id, name);
  }

  Future<void> _delete(
    BuildContext context,
    RemoteConnection connection,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ConfirmDialog(
        title: 'Delete and revoke connection?',
        content: Text(
          'Remove “${connection.name}” and revoke its remote access for every device. Your local OpenCode chats will remain. A new pairing will be required to reconnect.',
        ),
        confirmLabel: 'Delete and revoke',
      ),
    );
    if (confirmed == true) await viewModel.deleteConnection(connection.id);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: viewModel,
    builder: (context, _) => RefreshIndicator(
      color: AppTheme.ink,
      onRefresh: viewModel.load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(24),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Your OpenCode instances, all in one place.'),
                  if (viewModel.error case final error?) ...[
                    const SizedBox(height: 16),
                    InlineNotice(message: error, isError: true),
                    TextButton(
                      onPressed: viewModel.isLoading ? null : viewModel.load,
                      child: const Text('Try again'),
                    ),
                  ],
                  if (viewModel.isLoading) ...[
                    const SizedBox(height: 20),
                    const LinearProgressIndicator(
                      semanticsLabel: 'Loading connections',
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (viewModel.connections.isEmpty &&
              !viewModel.isLoading &&
              viewModel.error == null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 48),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: AppTheme.lime,
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: const Icon(Icons.devices_rounded, size: 48),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      'Connect your first\nOpenCode instance',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Start OpenCode on your computer, then enter the short code shown by the Remote plugin.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 28),
                    FilledButton.icon(
                      onPressed: onAddConnection,
                      icon: const Icon(Icons.add),
                      label: const Text('Enter pairing code'),
                    ),
                  ],
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            sliver: SliverList.separated(
              itemCount: viewModel.connections.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final connection = viewModel.connections[index];
                return ConnectionCard(
                  key: ValueKey(connection.id),
                  connection: connection,
                  isSelected: viewModel.selectedId == connection.id,
                  onSelect: viewModel.isMutating
                      ? null
                      : () => viewModel.selectConnection(connection.id),
                  onOpen: onOpenConnection == null || viewModel.isMutating
                      ? null
                      : () {
                          viewModel.selectConnection(connection.id);
                          onOpenConnection!(connection);
                        },
                  isDeleting: viewModel.deletingId == connection.id,
                  isRenaming: viewModel.renamingId == connection.id,
                  onRename: viewModel.isMutating
                      ? null
                      : () => _rename(context, connection),
                  onDelete: viewModel.isMutating
                      ? null
                      : () => _delete(context, connection),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
