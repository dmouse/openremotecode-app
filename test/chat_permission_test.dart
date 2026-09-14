import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/permission_banner.dart';

final _fixture = jsonDecode(
  File('../packages/protocol/test/fixtures/chat-permission-v1.json')
      .readAsStringSync(),
) as Map<String, dynamic>;
Map<String, dynamic> get _permission =>
    _fixture['response']['permission'] as Map<String, dynamic>;

void main() {
  test('the shared fixture parses with strict fields', () {
    final permission = ChatPermission.parse(_permission);
    expect(permission.id, 'per_fixture');
    expect(permission.operation, 'execute');
    expect(permission.description, 'Run a shell command');
    expect(permission.pattern, 'npm i*');
  });

  test('unknown operations, oversized fields and extra keys are rejected', () {
    for (final invalid in <Map<String, dynamic>>[
      {..._permission, 'operation': 'delete'},
      {..._permission, 'description': ''},
      {..._permission, 'description': 'd' * 257},
      {..._permission, 'pattern': 'p' * 257},
      {..._permission, 'extra': 'unexpected'},
    ]) {
      expect(() => ChatPermission.parse(invalid), throwsFormatException);
    }
  });

  testWidgets(
    'shows the pending permission with actionable buttons while live',
    (tester) async {
      final model = ChatViewModel(_Repository(), 'connector')
        ..conversation.permission = ChatPermission.parse(_permission);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PermissionBanner(model: model.conversation)),
        ),
      );
      expect(find.text('Run a shell command'), findsOneWidget);
      expect(find.text('npm i*'), findsOneWidget);
      expect(find.text('Allow once'), findsOneWidget);
      expect(find.text('Deny'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets('renders nothing when no permission is pending', (tester) async {
    final model = ChatViewModel(_Repository(), 'connector');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PermissionBanner(model: model.conversation)),
      ),
    );
    expect(find.byType(PermissionBanner), findsOneWidget);
    expect(find.text('Allow once'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });

  testWidgets(
    'replaces actions with an explanatory message when the connector is offline',
    (tester) async {
      final model = ChatViewModel(
        _Repository()..onlineValue = false,
        'connector',
      )..conversation.permission = ChatPermission.parse(_permission);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PermissionBanner(model: model.conversation)),
        ),
      );
      expect(find.text('Allow once'), findsNothing);
      expect(find.text('Deny'), findsNothing);
      expect(find.textContaining('Connector offline'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'Allow once sends the reply and the banner clears once the model reflects it resolved',
    (tester) async {
      final repo = _Repository()..permission = _permission;
      final model = ChatViewModel(repo, 'connector');
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      await model.openChat(model.chatList.chats.single);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: model,
              builder: (context, _) =>
                  PermissionBanner(model: model.conversation),
            ),
          ),
        ),
      );
      expect(find.text('Run a shell command'), findsOneWidget);
      await tester.tap(find.text('Allow once'));
      await tester.pumpAndSettle();
      final reply = repo.requests.firstWhere(
        (r) => r.$1 == 'chat.permission.reply',
      );
      expect(reply.$2['permissionId'], 'per_fixture');
      expect(reply.$2['response'], 'once');
      expect(find.text('Run a shell command'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}

class _Repository implements ChatRepository {
  Map<String, dynamic>? permission;
  bool onlineValue = true;
  final requests = <(String, Map<String, dynamic>)>[];

  @override
  Stream<void> get chatConnectionChanges => const Stream.empty();
  @override
  Stream<ChatEvent> get chatEvents => const Stream.empty();
  @override
  Object chatConnectionGeneration(String connectorId) => 0;
  @override
  bool chatOnline(String connectorId) => onlineValue;
  @override
  bool chatTrusted(String connectorId) => true;
  @override
  bool chatSupports(String connectorId, String operation) =>
      operation == 'chat.permissions' || operation == 'chat.permission.reply';
  @override
  Future<Set<String>> pinnedChatIds(
    String connectorId,
    String projectPath,
  ) async => {};
  @override
  Future<Set<String>> setChatPinned(
    String connectorId,
    String projectPath,
    String sessionId,
    bool pinned,
  ) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async {
    requests.add((operation, body));
    return switch (operation) {
      'project.list' => {
        'projects': [
          {'id': 'project', 'name': 'Project', 'path': '/workspace'},
        ],
        'pathEntry': false,
      },
      'chat.list' => {
        'chats': [_fixture['response']['chat']],
        'cursor': null,
      },
      'chat.snapshot' => {
        'version': 1,
        'chat': _fixture['response']['chat'],
        'status': 'idle',
        'cursor': null,
        'messages': <Map<String, dynamic>>[],
        if (permission != null) 'permission': permission,
      },
      'chat.permission.reply' => () {
        permission = null;
        return {'version': 1, 'accepted': true};
      }(),
      _ => throw UnimplementedError(),
    };
  }
}
