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

Future<void> _settle(ChatsHomeViewModel model) async {
  for (var i = 0; i < 50 && model.loading; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(model.loading, isFalse);
}

void main() {
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
      await tester.tap(find.widgetWithText(ChoiceChip, 'Laptop'));
      await tester.pumpAndSettle();
      expect(find.text('b conversation'), findsNothing);
      await tester.enterText(find.byType(TextField), 'a conversation');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(ListTile, 'a conversation'));
      await tester.pumpAndSettle();
      expect(repo.calls.last, ('a', 'chat.snapshot'));
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
