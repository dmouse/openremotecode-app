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
import '../../chat/chats_home_view_model.dart';
import '../../chat/chat_view_model.dart';
import '../../chat/ui/chats_home_view.dart';
import 'workspace_settings_view.dart';
import '../../chat/data/chat_repository.dart';
import '../../chat/ui/chat_flow_screen.dart';
import '../../chat/domain/voice_recorder.dart';
import '../../chat/domain/voice_audio_player.dart';
import '../../chat/domain/voice_note.dart';

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({
    super.key,
    required this.repository,
    required this.auth,
    this.settings,
    this.voiceRecorderFactory,
    this.voicePlaybackFactory,
  });
  final ConnectionsRepository repository;
  final AuthRepository auth;
  final SettingsViewModel? settings;
  final VoiceRecorder Function()? voiceRecorderFactory;
  final VoiceAudioPlayer Function()? voicePlaybackFactory;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with WidgetsBindingObserver {
  late final _connections = ConnectionsViewModel(widget.repository);
  late final _settings =
      widget.settings ?? SettingsViewModel(PreferencesSettingsRepository());
  String? _destination;
  ChatsHomeViewModel? _chats;
  bool _pairingOpen = false;
  bool _chatOpen = false;
  bool _choosingProject = false;
  bool _deleteOpen = false;
  final _voiceNotes = VoiceNoteMemory();

  Future<void> _openChat(ChatViewModel source, [HomeChat? entry]) async {
    if (_chatOpen ||
        !source.online ||
        source.project == null ||
        _chats?.sources.contains(source) != true ||
        !_connections.connections.any((c) => c.id == source.connectorId)) {
      return;
    }
    final project = source.project!;
    final connectionName = _connections.connections
        .firstWhere((c) => c.id == source.connectorId)
        .name;
    final drafts = _chats?.draftsFor(source);
    _chatOpen = true;
    _chats?.setActive(false);
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ChatFlowScreen(
            repository: source.repository,
            connectorId: source.connectorId,
            connectionName: connectionName,
            connectionColor: _connections.colorFor(source.connectorId),
            initialProject: project,
            initialChat: entry?.chat,
            directConversation: true,
            drafts: drafts,
            settings: _settings,
            voiceRecorderFactory: widget.voiceRecorderFactory,
            voicePlaybackFactory: widget.voicePlaybackFactory,
            voiceNotes: _voiceNotes,
          ),
        ),
      );
    } finally {
      _chatOpen = false;
      if (mounted) _chats?.setActive(true);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _connections.addListener(_clearRevokedAudio);
    if (widget.repository case final ChatRepository repository) {
      _chats = ChatsHomeViewModel(
        _connections,
        repository,
        settings: _settings,
      );
    }
    if (widget.settings == null) unawaited(_settings.load());
    unawaited(_connections.load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _connections.setActive(state == AppLifecycleState.resumed);
    if (!_chatOpen) _chats?.setActive(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.auth.validateOnResume());
      unawaited(_connections.load());
    }
  }

  @override
  void dispose() {
    _connections.removeListener(_clearRevokedAudio);
    _voiceNotes.clear();
    WidgetsBinding.instance.removeObserver(this);
    _chats?.dispose();
    _connections.dispose();
    if (widget.settings == null) _settings.dispose();
    super.dispose();
  }

  void _clearRevokedAudio() {
    if (widget.repository case final ChatRepository repository) {
      _voiceNotes.retainConnectors(
        _connections.connections.map((c) => c.id).toSet(),
      );
      for (final machine in _connections.connections) {
        if (machine.needsVerification || !repository.chatTrusted(machine.id)) {
          _voiceNotes.clear(connector: machine.id);
        }
      }
    }
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

  Future<void> _newChat() async {
    final home = _chats;
    if (home == null || _chatOpen || _choosingProject) return;
    _choosingProject = true;
    try {
      if (home.selectedFolder != null && home.sources.length == 1) {
        await _openChat(home.sources.single);
        return;
      }
      final source = await chooseChatProject(context, home);
      if (mounted && source != null) await _openChat(source);
    } finally {
      _choosingProject = false;
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _destination == null,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) setState(() => _destination = null);
    },
    child: Scaffold(
      backgroundColor: AppTheme.of(context).background,
      appBar: AppBar(
        backgroundColor: AppTheme.of(context).background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        leading: _destination == null
            ? null
            : BackButton(onPressed: () => setState(() => _destination = null)),
        title: Text(switch (_destination) {
          'settings' => 'Settings',
          'connect' => 'Connections',
          _ => 'Chats',
        }),
        actions: [
          if (_destination == null)
            PopupMenuButton<String>(
              tooltip: 'App options',
              icon: const Icon(Icons.more_vert),
              onSelected: (value) => setState(() => _destination = value),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'connect', child: Text('Connect')),
                PopupMenuItem(value: 'settings', child: Text('Settings')),
              ],
            ),
          if (_destination == 'connect')
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
      body: SafeArea(
        child: IndexedStack(
          index: switch (_destination) {
            'connect' => 1,
            'settings' => 2,
            _ => 0,
          },
          children: [
            if (_chats case final home?)
              ChatsHomeView(
                model: home,
                onOpen: (entry) => _openChat(entry.source, entry),
                onOpenDraft: (source) => _openChat(source),
                onConnect: () => setState(() => _destination = 'connect'),
              )
            else
              const Center(
                child: Text('Connect an OpenCode instance to view chats.'),
              ),
            ConnectionsScreen(
              key: const ValueKey('workspace-content'),
              viewModel: _connections,
              onAddConnection: _addConnection,
            ),
            WorkspaceSettingsView(
              auth: widget.auth,
              settings: _settings,
              onDeleteAccount: _deleteAccount,
            ),
          ],
        ),
      ),
      floatingActionButton: _destination == null && _chats != null
          ? FloatingActionButton(
              tooltip: 'New chat',
              onPressed: _newChat,
              child: const Icon(Icons.add_comment_outlined),
            )
          : null,
    ),
  );
}
