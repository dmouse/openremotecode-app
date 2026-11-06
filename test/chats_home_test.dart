import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chats_home_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/connections/connections_view_model.dart';
import 'package:openremotecode/features/connections/data/connections_repository.dart';
import 'package:openremotecode/features/connections/domain/remote_connection.dart';
import 'package:openremotecode/features/workspace/ui/workspace_screen.dart';
import 'package:openremotecode/ui/core/app_theme.dart';
import 'package:openremotecode/ui/core/chat_avatar.dart';
import 'package:openremotecode/features/chat/ui/chats_home_view.dart';
import 'package:openremotecode/features/chat/ui/chat_filter_strip.dart';

import 'support/auth_fakes.dart';

class _Repository implements ConnectionsRepository, ChatRepository {
  final changes = StreamController<void>.broadcast(sync: true);
  final trusted = {'a', 'b'};
  final online = {'a', 'b'};
  final calls = <(String, String)>[];
  Completer<Map<String, dynamic>>? pending;
  @override
  Future<List<RemoteConnection>> listConnections() async => [
    for (final id in ['a', 'b'])
      RemoteConnection(
        id: id,
        name: id == 'a' ? 'Laptop' : 'Server',
        status: trusted.contains(id)
            ? online.contains(id)
                  ? ConnectionStatus.online
                  : ConnectionStatus.offline
            : ConnectionStatus.verificationRequired,
      ),
  ];
  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async {
    calls.add((connectorId, operation));
    if (operation == 'project.list') {
      if (pending != null) return pending!.future;
      return {
        'projects': [
          {'id': 'project', 'name': 'App', 'path': '/work/app'},
        ],
      };
    }
    if (operation == 'chat.list') {
      return {
        'chats': [
          {
            'id': 'same-session',
            'title': '$connectorId conversation',
            'updatedAt': connectorId == 'a' ? 200 : 300,
          },
          {
            'id': 'child',
            'title': 'Hidden child',
            'updatedAt': 400,
            'parentId': 'same-session',
          },
        ],
        'cursor': null,
      };
    }
    if (operation == 'chat.snapshot') {
      return {
        'version': 1,
        'chat': {
          'id': 'same-session',
          'title': '$connectorId conversation',
          'updatedAt': 300,
        },
        'messages': [],
        'status': 'idle',
        'cursor': null,
      };
    }
    throw StateError('Unexpected request');
  }

  @override
  bool chatOnline(String id) => online.contains(id) && trusted.contains(id);
  @override
  bool chatTrusted(String id) => trusted.contains(id);
  @override
  Stream<void> get chatConnectionChanges => changes.stream;
  @override
  Stream<ChatEvent> get chatEvents => const Stream.empty();
  @override
  bool chatSupports(String id, String operation) => false;
  @override
  Future<Set<String>> pinnedChatIds(String id, String path) async => {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FoldersRepository extends _Repository {
  bool apiAllowed = true;
  bool morePages = false;
  bool duplicateNames = false;
  Completer<Map<String, dynamic>>? pendingPage;
  final chatReads = <(String, String)>[];
  @override
  Future<Map<String, dynamic>> chatRequest(
    String id,
    String operation,
    Map<String, dynamic> body,
  ) async {
    if (operation == 'project.list') {
      return {
        'projects': [
          if (id == 'a') ...[
            {'id': 'p_app', 'name': 'App', 'path': '/one/app'},
            if (apiAllowed)
              {
                'id': 'p_api',
                'name': duplicateNames ? 'App' : 'Api',
                'path': '/one/api',
              },
          ] else ...[
            {'id': 'p_app', 'name': 'App', 'path': '/two/app'},
            {'id': 'p_docs', 'name': 'Docs', 'path': '/two/docs'},
          ],
        ],
      };
    }
    if (operation == 'chat.list') {
      final project = body['projectId'] as String;
      chatReads.add((id, project));
      if (body['cursor'] != null && pendingPage != null) {
        return pendingPage!.future;
      }
      return {
        'chats': [
          {'id': 'same-session', 'title': '$id/$project', 'updatedAt': 100},
        ],
        'cursor': morePages && body['cursor'] == null ? 'older' : null,
      };
    }
    return super.chatRequest(id, operation, body);
  }
}

Future<void> _settle(ChatsHomeViewModel model) async {
  for (var i = 0; i < 50 && model.loading; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(model.loading, isFalse);
}

void main() {
  test('duplicate folder names on one connection use full paths', () async {
    final repo = _FoldersRepository()..duplicateNames = true;
    final connections = ConnectionsViewModel(repo);
    final home = ChatsHomeViewModel(connections, repo);
    await connections.load();
    await _settle(home);
    home.selectMachine('a');
    expect(home.folderSources.map(home.folderLabel), ['/one/app', '/one/api']);
    home.dispose();
    connections.dispose();
    await repo.changes.close();
  });

  test('changing filters stops pagination of the old source list', () async {
    final repo = _FoldersRepository()..morePages = true;
    final connections = ConnectionsViewModel(repo);
    final home = ChatsHomeViewModel(connections, repo);
    await connections.load();
    await _settle(home);
    repo.chatReads.clear();
    repo.pendingPage = Completer<Map<String, dynamic>>();
    final loading = home.loadMore();
    await Future<void>.delayed(Duration.zero);
    home.selectFolder(
      home.folderSources.firstWhere((s) => s.project!.id == 'p_docs'),
    );
    repo.pendingPage!.complete({'chats': [], 'cursor': null});
    await loading;
    expect(repo.chatReads, [('a', 'p_app')]);
    expect(home.selectedFolder, ('b', '/two/docs'));
    expect(home.chats.single.chat.title, 'b/p_docs');
    home.dispose();
    connections.dispose();
    await repo.changes.close();
  });

  testWidgets(
    'folder-scoped New chat skips chooser and Back preserves filter, search and draft',
    (tester) async {
      final repo = _FoldersRepository();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: WorkspaceScreen(repository: repo, auth: fakeAuth()),
        ),
      );
      await tester.pumpAndSettle();
      final folder = find.byKey(
        const ValueKey(('folder-filter', 'a', '/one/api')),
      );
      await tester.scrollUntilVisible(
        folder,
        150,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('chat-filter-strip')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(folder);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'a/p_api');
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('New chat'));
        await tester.pumpAndSettle();
        final composer = find.byKey(const ValueKey('chat-composer'));
        expect(composer, findsOneWidget);
        expect(find.text('Choose project'), findsNothing);
        if (i == 0) {
          await tester.enterText(composer, 'Folder-specific draft');
        } else {
          expect(
            tester.widget<TextField>(composer).controller!.text,
            'Folder-specific draft',
          );
        }
        await tester.tap(find.byTooltip('Back').first);
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(folder).selected, isTrue);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'a/p_api',
        );
        expect(find.text('a/p_api'), findsWidgets);
        expect(find.text('b/p_docs'), findsNothing);
      }
      expect(repo.calls.any((call) => call.$2 == 'chat.create'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await repo.changes.close();
    },
  );

  test('one strip composes machine and folder scopes with distinct source identities', () async {
    final repo = _FoldersRepository();
    final connections = ConnectionsViewModel(repo);
    final home = ChatsHomeViewModel(connections, repo);
    await connections.load();
    await _settle(home);
    expect(home.chats, hasLength(4));
    expect(home.folderSources, hasLength(4));
    expect(
      home.folderLabel(
        home.folderSources.firstWhere(
          (s) => s.connectorId == 'a' && s.project!.id == 'p_app',
        ),
      ),
      '/App · Laptop',
    );
    final reads = repo.chatReads.length;
    home.selectMachine('a');
    expect(home.folderSources, hasLength(2));
    home.selectFolder(
      home.folderSources.firstWhere((s) => s.project!.id == 'p_api'),
    );
    expect(home.selectedFolder, ('a', '/one/api'));
    expect(home.chats.single.chat.title, 'a/p_api');
    expect(
      repo.chatReads.length,
      reads,
      reason: 'Selecting a filter does not mutate or rediscover projects',
    );
    home.selectMachine('b');
    expect(home.selectedFolder, isNull);
    expect(home.folderSources.every((s) => s.connectorId == 'b'), isTrue);
    home.selectMachine(null);
    expect(home.chats, hasLength(4));
    home.selectFolder(
      home.folderSources.firstWhere((s) => s.project!.id == 'p_docs'),
    );
    expect(home.selectedMachine, 'b');
    expect(home.chats.single.chat.title, 'b/p_docs');
    repo.online.remove('b');
    repo.changes.add(null);
    expect(home.selectedFolder, ('b', '/two/docs'));
    expect(home.chats.single.source.online, isFalse);
    repo.trusted.remove('b');
    repo.changes.add(null);
    expect(home.selectedFolder, isNull);
    expect(home.chats, isEmpty);
    expect(home.filterNotice, isNotNull);
    home.dispose();
    connections.dispose();
    await repo.changes.close();
  });

  test('folder pagination stays scoped and removed approvals clear selection with notice', () async {
    final repo = _FoldersRepository()..morePages = true;
    final connections = ConnectionsViewModel(repo);
    final home = ChatsHomeViewModel(connections, repo);
    await connections.load();
    await _settle(home);
    home.selectFolder(
      home.folderSources.firstWhere((s) => s.project!.id == 'p_api'),
    );
    repo.chatReads.clear();
    await home.loadMore();
    expect(repo.chatReads, [('a', 'p_api')]);
    expect(home.hasMore, isFalse);
    repo.apiAllowed = false;
    await home.refresh();
    expect(home.selectedFolder, isNull);
    expect(home.filterNotice, contains('no longer available'));
    expect(home.filterNotice, isNot(contains('/one/api')));
    expect(home.folderSources.any((s) => s.project!.id == 'p_api'), isFalse);
    home.selectMachine(null);
    expect(home.filterNotice, isNull);
    home.dispose();
    connections.dispose();
    await repo.changes.close();
  });

  for (final theme in [AppTheme.light, AppTheme.dark]) {
    testWidgets(
      'left-aligned 12px filters distinguish folder and machine theme colors in ${theme.brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final repo = _FoldersRepository();
        final connections = ConnectionsViewModel(repo);
        final home = ChatsHomeViewModel(connections, repo);
        await tester.runAsync(() async {
          await connections.load();
          await _settle(home);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: ChatsHomeView(
                model: home,
                onOpen: (_) {},
                onConnect: () {},
              ),
            ),
          ),
        );
        final all = find.byKey(const ValueKey('filter-all'));
        expect(tester.getTopLeft(all).dx, 20);
        expect(tester.getSize(all).height, greaterThanOrEqualTo(48));
        expect(tester.widget<ChoiceChip>(all).labelStyle!.fontSize, 12);
        final folder = find.byKey(
          const ValueKey(('folder-filter', 'a', '/one/api')),
        );
        await tester.scrollUntilVisible(
          folder,
          150,
          scrollable: find.descendant(
            of: find.byKey(const ValueKey('chat-filter-strip')),
            matching: find.byType(Scrollable),
          ),
        );
        final chip = tester.widget<ChoiceChip>(folder);
        final colors = theme.brightness == Brightness.dark
            ? AppTheme.darkColors
            : const AppColors();
        expect(chip.selectedColor, colors.infoSurface);
        expect(chip.labelStyle!.color, colors.info);
        expect(
          find.descendant(
            of: folder,
            matching: find.byIcon(Icons.folder_outlined),
          ),
          findsOneWidget,
        );
        await tester.tap(folder);
        await tester.pumpAndSettle();
        expect(home.chats.single.chat.title, 'a/p_api');
        expect(find.text('b/p_docs'), findsNothing);
        expect(find.byType(ChatFilterStrip), findsOneWidget);
        repo.apiAllowed = false;
        await tester.runAsync(home.refresh);
        await tester.pumpAndSettle();
        expect(find.text(home.filterNotice!), findsOneWidget);
        expect(find.text('a/p_app'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        home.dispose();
        connections.dispose();
        await repo.changes.close();
      },
    );
  }

  testWidgets('new chat draft survives Back and the home fits large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _Repository();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: WorkspaceScreen(repository: repo, auth: fakeAuth()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Laptop'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byTooltip('New chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'App'));
      await tester.pumpAndSettle();
      final composer = find.byKey(const ValueKey('chat-composer'));
      if (i == 0) {
        await tester.enterText(composer, 'Recover this new draft');
      } else {
        expect(
          tester.widget<TextField>(composer).controller!.text,
          'Recover this new draft',
        );
      }
      await tester.tap(find.byTooltip('Back').first);
      await tester.pumpAndSettle();
    }
    expect(repo.calls.any((call) => call.$2 == 'chat.create'), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await repo.changes.close();
  });

  test('aggregates distinct peer identities, excludes children and sorts newest first', () async {
    final repo = _Repository();
    final connections = ConnectionsViewModel(repo);
    final home = ChatsHomeViewModel(connections, repo);
    await connections.load();
    await _settle(home);
    expect(home.chats.map((c) => c.chat.title), [
      'b conversation',
      'a conversation',
    ]);
    expect(repo.calls.where((c) => c.$2 == 'chat.snapshot'), isEmpty);
    home.selectMachine('a');
    expect(home.chats.single.connection.id, 'a');
    final drafts = home.draftsFor(home.chats.single.source)
      ..['chat:same-session'] = 'Private draft';
    repo.trusted.remove('a');
    repo.changes.add(null);
    expect(home.chats, isEmpty);
    expect(
      drafts,
      isEmpty,
      reason: 'Revocation clears shared draft memory too',
    );
    home.dispose();
    connections.dispose();
    await repo.changes.close();
  });

  test(
    'offline peers keep last-known rows and a cold start does not query them',
    () async {
      final repo = _Repository()..online.remove('b');
      final connections = ConnectionsViewModel(repo);
      final home = ChatsHomeViewModel(connections, repo);
      await connections.load();
      await _settle(home);
      expect(home.chats.single.connection.id, 'a');
      expect(repo.calls.any((c) => c.$1 == 'b'), isFalse);
      repo.online.remove('a');
      repo.changes.add(null);
      expect(home.chats.single.source.online, isFalse);
      expect(home.machines, hasLength(2));
      home.dispose();
      connections.dispose();
      await repo.changes.close();
    },
  );

  test('revocation during discovery rejects late decrypted metadata', () async {
    final repo = _Repository()..online.remove('b');
    repo.pending = Completer<Map<String, dynamic>>();
    final connections = ConnectionsViewModel(repo);
    final home = ChatsHomeViewModel(connections, repo);
    await connections.load();
    repo.trusted.remove('a');
    repo.changes.add(null);
    repo.pending!.complete({
      'projects': [
        {'id': 'project', 'name': 'Secret', 'path': '/secret'},
      ],
    });
    await _settle(home);
    expect(home.sources, isEmpty);
    home.dispose();
    connections.dispose();
    await repo.changes.close();
  });

  testWidgets(
    'machine chips filter, chat opens directly, Back restores search and draft',
    (tester) async {
      final repo = _Repository();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: WorkspaceScreen(repository: repo, auth: fakeAuth()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chats'), findsOneWidget);
      expect(find.text('a conversation'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Laptop'))
            .labelStyle!
            .fontSize,
        12,
      );
      final color = tester
          .widget<ChatAvatar>(find.byType(ChatAvatar).first)
          .color;
      await tester.tap(find.widgetWithText(ChoiceChip, 'Laptop'));
      await tester.pumpAndSettle();
      expect(find.text('b conversation'), findsNothing);
      await tester.enterText(find.byType(TextField), 'a conversation');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(ListTile, 'a conversation'));
      await tester.pumpAndSettle();
      expect(repo.calls.last, ('a', 'chat.snapshot'));
      expect(
        tester.widget<ChatAvatar>(find.byType(ChatAvatar).first).color,
        color,
      );
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        'Unsent draft',
      );
      await tester.tap(find.byTooltip('Back').first);
      await tester.pumpAndSettle();
      expect(find.text('Chats'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'a conversation',
      );
      await tester.tap(find.byTooltip('App options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Connections'), findsOneWidget);
      expect(find.text('Open projects'), findsNothing);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Laptop'))
            .selected,
        isTrue,
      );
      await tester.tap(find.widgetWithText(ListTile, 'a conversation'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('chat-composer')))
            .controller!
            .text,
        'Unsent draft',
      );
      await tester.pumpWidget(const SizedBox());
      await repo.changes.close();
    },
  );
}
