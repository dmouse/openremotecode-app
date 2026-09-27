import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../../auth/auth_repository.dart';
import '../../auth/ui/delete_account_dialog.dart';
import '../../settings/data/settings_repository.dart';
import '../../settings/settings_view_model.dart';
import '../../connections/connections_view_model.dart';
import '../../connections/data/connections_repository.dart';
import '../../connections/domain/remote_connection.dart';
import '../../connections/ui/connections_screen.dart';
import '../../connections/ui/pairing_sheet.dart';
import 'workspace_sidebar.dart';
import 'workspace_settings_view.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/ui/chat_flow_screen.dart';

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({
    super.key,
    required this.repository,
    required this.auth,
    this.settings,
  });
  final ConnectionsRepository repository;
  final AuthRepository auth;
  final SettingsViewModel? settings;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with WidgetsBindingObserver {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final _connections = ConnectionsViewModel(widget.repository);
  late final _settings =
      widget.settings ?? SettingsViewModel(PreferencesSettingsRepository());
  bool _settingsSelected = false;
  bool _pairingOpen = false;
  bool _chatOpen = false;
  bool _deleteOpen = false;

  Future<void> _openConnection(RemoteConnection connection) async {
    if (_chatOpen || _connections.isMutating) return;
    final repository = widget.repository;
    if (connection.needsVerification) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Verify this connection before opening projects.'),
        ),
      );
      return;
    }
    if (repository is! ChatRepository) return;
    _chatOpen = true;
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ChatFlowScreen(
            repository: repository as ChatRepository,
            connectorId: connection.id,
            connectionName: connection.name,
            settings: _settings,
          ),
        ),
      );
    } finally {
      _chatOpen = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.settings == null) unawaited(_settings.load());
    unawaited(_connections.load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _connections.setActive(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.auth.validateOnResume());
      unawaited(_connections.load());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connections.dispose();
    if (widget.settings == null) _settings.dispose();
    super.dispose();
  }

  void _select(bool settings) {
    _scaffoldKey.currentState?.closeDrawer();
    setState(() => _settingsSelected = settings);
  }

  Future<void> _deleteAccount() async {
    if (_deleteOpen || widget.auth.isBusy) return;
    _deleteOpen = true;
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => DeleteAccountDialog(auth: widget.auth),
      );
    } finally {
      _deleteOpen = false;
    }
  }

  Future<void> _addConnection() async {
    if (_pairingOpen || _connections.isMutating) return;
    _pairingOpen = true;
    try {
      final connection = await showModalBottomSheet<RemoteConnection>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        isDismissible: false,
        enableDrag: false,
        constraints: const BoxConstraints(maxWidth: 520),
        builder: (_) => PairingSheet(repository: widget.repository),
      );
      if (mounted && connection != null) _connections.addConfirmed(connection);
    } finally {
      _pairingOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 720;
      final sidebar = WorkspaceSidebar(
        settingsSelected: _settingsSelected,
        onSettingsSelected: () => _select(true),
        onConnectionsSelected: () => _select(false),
      );
      final content = _settingsSelected
          ? WorkspaceSettingsView(
              auth: widget.auth,
              settings: _settings,
              onDeleteAccount: _deleteAccount,
            )
          : ConnectionsScreen(
              key: const ValueKey('workspace-content'),
              viewModel: _connections,
              onAddConnection: _addConnection,
              onOpenConnection: _openConnection,
            );
      return Scaffold(
        key: _scaffoldKey,
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: AppTheme.background,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          automaticallyImplyLeading: !wide,
          title: Text(_settingsSelected ? 'Settings' : 'Connections'),
          actions: [
            if (!_settingsSelected)
              ListenableBuilder(
                listenable: _connections,
                builder: (context, _) => IconButton(
                  tooltip: 'Add connection',
                  onPressed: !_connections.isMutating ? _addConnection : null,
                  icon: const Icon(Icons.add),
                ),
              ),
          ],
        ),
        drawer: wide ? null : sidebar,
        body: SafeArea(
          child: wide
              ? Row(
                  children: [
                    SizedBox(width: 280, child: sidebar),
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(child: content),
                  ],
                )
              : content,
        ),
      );
    },
  );
}
