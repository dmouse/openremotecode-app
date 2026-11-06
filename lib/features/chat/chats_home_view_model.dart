import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connections/connections_view_model.dart';
import '../connections/domain/remote_connection.dart';
import '../settings/settings_view_model.dart';
import 'chat_view_model.dart';
import 'data/chat_repository.dart';
import 'domain/chat_models.dart';
import 'projects_view_model.dart';

/// A chat's source is part of its identity: session IDs are not globally unique.
final class HomeChat {
  const HomeChat(this.connection, this.source, this.chat);
  final RemoteConnection connection;
  final ChatViewModel source;
  final RemoteChat chat;
  RemoteProject get project => source.project!;
  bool get pinned => source.chatList.isPinned(chat);
}

/// In-memory, account-scoped index of authorized projects. It never fetches
/// messages or persists conversation metadata. Each project retains the existing
/// bounded pagination, pinning and authorization behavior.
final class ChatsHomeViewModel extends ChangeNotifier {
  ChatsHomeViewModel(this.connections, this.repository, {this.settings}) {
    connections.addListener(_connectionsChanged);
    _subscription = repository.chatConnectionChanges.listen((_) {
      _connectionsChanged();
    });
    _connectionsChanged();
  }

  final ConnectionsViewModel connections;
  final ChatRepository repository;
  final SettingsViewModel? settings;
  final _sources = <(String, String), ChatViewModel>{};
  final _drafts = <(String, String), Map<String, String>>{};
  final _errors = <String, String>{};
  final _online = <String>{};
  StreamSubscription<void>? _subscription;
  bool _disposed = false, _active = true, loading = false;
  int _generation = 0;
  bool _refreshAgain = false;
  String? selectedMachine;
  (String, String)? _selectedFolder;
  (String, String)? get selectedFolder => _selectedFolder;
  String? filterNotice;
  int _filterRevision = 0;

  List<RemoteConnection> get machines => connections.connections;

  /// Folder choices follow the machine scope, not the selected folder itself.
  List<ChatViewModel> get folderSources => _sources.values
      .where(
        (source) =>
            source.project != null &&
            (selectedMachine == null || source.connectorId == selectedMachine),
      )
      .toList();
  List<ChatViewModel> get sources => folderSources
      .where(
        (source) =>
            _selectedFolder == null ||
            _selectedFolder == (source.connectorId, source.project!.path),
      )
      .toList();

  String folderLabel(ChatViewModel source) {
    final project = source.project!;
    final label = project.name.startsWith('/')
        ? project.name
        : '/${project.name}';
    final duplicates = folderSources
        .where((s) => s.project!.name == project.name)
        .toList();
    if (duplicates.length < 2) return label;
    if (duplicates.any(
      (s) => s != source && s.connectorId == source.connectorId,
    )) {
      return project.path;
    }
    final machine = machines
        .where((m) => m.id == source.connectorId)
        .firstOrNull;
    return '$label · ${machine?.name ?? 'Connection'}';
  }

  List<String> get errors => [
    if (connections.error != null) connections.error!,
    for (final entry in _errors.entries)
      if (selectedMachine == null || selectedMachine == entry.key) entry.value,
    for (final source in sources)
      if (source.error != null) source.error!,
  ];
  bool get hasMore =>
      sources.any((s) => s.chatList.chatCursor != null && s.online);
  List<HomeChat> get chats {
    final entries = <HomeChat>[];
    for (final source in sources) {
      final machine = machines
          .where((m) => m.id == source.connectorId)
          .firstOrNull;
      if (machine == null || machine.needsVerification) continue;
      entries.addAll(
        source.chatList.chats.map((chat) => HomeChat(machine, source, chat)),
      );
    }
    entries.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final time = b.chat.updatedAt.compareTo(a.chat.updatedAt);
      if (time != 0) return time;
      return '${a.connection.id}/${a.project.path}/${a.chat.id}'.compareTo(
        '${b.connection.id}/${b.project.path}/${b.chat.id}',
      );
    });
    return entries;
  }

  Map<String, String> draftsFor(ChatViewModel source) =>
      _drafts.putIfAbsent((source.connectorId, source.project!.path), () => {});

  void selectMachine(String? id) {
    if (_disposed || (id != null && !machines.any((m) => m.id == id))) return;
    selectedMachine = id;
    _selectedFolder = null;
    filterNotice = null;
    _filterRevision++;
    notifyListeners();
  }

  void selectFolder(ChatViewModel source) {
    if (_disposed ||
        !folderSources.contains(source) ||
        source.project == null ||
        !repository.chatTrusted(source.connectorId)) {
      return;
    }
    selectedMachine = source.connectorId;
    _selectedFolder = (source.connectorId, source.project!.path);
    filterNotice = null;
    _filterRevision++;
    notifyListeners();
  }

  void _reconcileFolder() {
    final selected = _selectedFolder;
    if (selected == null) return;
    final source = _sources[selected];
    if (source == null ||
        source.project == null ||
        !repository.chatTrusted(selected.$1)) {
      _selectedFolder = null;
      _filterRevision++;
      filterNotice = 'The selected folder is no longer available. The folder filter was cleared.';
    }
  }

  void _connectionsChanged() {
    if (_disposed) return;
    final allowed = machines
        .where((m) => !m.needsVerification && repository.chatTrusted(m.id))
        .map((m) => m.id)
        .toSet();
    for (final key in _sources.keys.toList()) {
      if (!allowed.contains(key.$1)) {
        _sources.remove(key)!.dispose();
        _drafts.remove(key)?.clear();
      }
    }
    _errors.removeWhere((id, _) => !allowed.contains(id));
    if (selectedMachine != null &&
        !machines.any((m) => m.id == selectedMachine)) {
      selectedMachine = null;
      _filterRevision++;
    }
    _reconcileFolder();
    final online = allowed.where(repository.chatOnline).toSet();
    final changed = !setEquals(online, _online);
    _online
      ..clear()
      ..addAll(online);
    notifyListeners();
    if (changed && _active) unawaited(refresh());
  }

  void setActive(bool active) {
    if (_disposed || _active == active) return;
    _active = active;
    _generation++;
    for (final source in _sources.values) {
      source.setActive(active, reconcile: false);
    }
    if (active) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (_disposed || !_active) return;
    if (loading) {
      _refreshAgain = true;
      return;
    }
    loading = true;
    final generation = _generation;
    bool valid(String id) =>
        !_disposed &&
        _active &&
        generation == _generation &&
        machines.any((m) => m.id == id && !m.needsVerification) &&
        repository.chatTrusted(id);
    notifyListeners();
    // Sequential admission leaves relay capacity for the visible conversation
    // and prevents many machines/projects from exhausting its four-request cap.
    try {
      for (final machine in [...machines]) {
        if (!valid(machine.id) || !repository.chatOnline(machine.id)) continue;
        try {
          final discovery = ProjectsViewModel(repository, machine.id);
          await discovery.fetchList();
          if (!valid(machine.id)) continue;
          final paths = discovery.projects.map((p) => p.path).toSet();
          for (final key
              in _sources.keys.where((k) => k.$1 == machine.id).toList()) {
            if (!paths.contains(key.$2)) {
              _sources.remove(key)!.dispose();
              _drafts.remove(key)?.clear();
            }
          }
          _reconcileFolder();
          _errors.remove(machine.id);
          for (final project in discovery.projects) {
            if (!valid(machine.id) || !repository.chatOnline(machine.id)) break;
            final source = _sources.putIfAbsent(
              (machine.id, project.path),
              () => ChatViewModel(
                repository,
                machine.id,
                settings: settings,
                reconcileConnectionChanges: false,
              )..addListener(_notify),
            );
            if (source.project == null) {
              await source.openProject(project);
            } else {
              await source.refresh();
            }
            if (!valid(machine.id)) break;
            if (source.error != null) source.chatList.reset();
            _notify();
          }
        } catch (failure) {
          if (valid(machine.id)) {
            if (failure == ChatFailure.denied ||
                failure == ChatFailure.expired) {
              for (final key
                  in _sources.keys.where((k) => k.$1 == machine.id).toList()) {
                _sources.remove(key)!.dispose();
                _drafts.remove(key)?.clear();
              }
            }
            _errors[machine.id] = 'Some chats could not be loaded. Check the connection and refresh.';
          }
        }
      }
    } finally {
      loading = false;
      if (!_disposed) {
        _notify();
        if (_refreshAgain && _active) {
          _refreshAgain = false;
          unawaited(refresh());
        }
      }
    }
  }

  Future<void> loadMore() async {
    if (_disposed || !_active || loading) return;
    loading = true;
    final filterRevision = _filterRevision;
    notifyListeners();
    try {
      for (final source in sources) {
        if (_disposed || !_active || filterRevision != _filterRevision) break;
        if (source.online &&
            source.chatList.chatCursor != null &&
            source.chatList.moreChatsError == null) {
          await source.moreChats();
        }
      }
    } finally {
      loading = false;
      _notify();
      if (_refreshAgain && !_disposed && _active) {
        _refreshAgain = false;
        unawaited(refresh());
      }
    }
  }

  void _notify() {
    if (!_disposed) {
      _reconcileFolder();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    connections.removeListener(_connectionsChanged);
    unawaited(_subscription?.cancel());
    for (final source in _sources.values) {
      source.dispose();
    }
    _sources.clear();
    for (final drafts in _drafts.values) {
      drafts.clear();
    }
    _drafts.clear();
    super.dispose();
  }
}
