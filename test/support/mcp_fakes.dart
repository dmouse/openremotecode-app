import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/mcp_models.dart';

Map<String, dynamic> get mcpFixture => jsonDecode(
  File('../packages/protocol/test/fixtures/project-mcp-v1.json')
      .readAsStringSync(),
) as Map<String, dynamic>;
String get mcpProject => mcpFixture['snapshotRequest']['projectId'] as String;

class McpRepositoryFake implements ChatRepository {
  final changes = StreamController<void>.broadcast(sync: true);
  final events = StreamController<ChatEvent>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];
  final capabilities = {...McpSnapshot.capabilities};
  bool online = true, trusted = true, eventBeforeResponse = false;
  int generation = 0;
  int initialRevision = 1;
  final revisions = <String, int>{};
  Completer<Map<String, dynamic>>? pending;
  ChatFailure? failure;
  Map<String, dynamic> data = Map.from(mcpFixture['snapshotResponse'] as Map);
  String projectId = mcpProject;
  List<(String, Map<String, dynamic>)> get subscriptions =>
      calls.where((call) => call.$1 == 'project.mcp.subscribe').toList();
  String get subscriptionId =>
      subscriptions.last.$2['subscriptionId'] as String;

  @override
  Stream<void> get chatConnectionChanges => changes.stream;
  @override
  Stream<ChatEvent> get chatEvents => events.stream;
  @override
  Object chatConnectionGeneration(String connectorId) => generation;
  @override
  bool chatOnline(String connectorId) => online && trusted;
  @override
  bool chatTrusted(String connectorId) => trusted;
  @override
  bool chatSupports(String connectorId, String operation) =>
      trusted && capabilities.contains(operation);
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
  ) => throw StateError('Unexpected mutation');

  Map<String, dynamic> update({String? id, int revision = 1}) => {
    ...data,
    'projectId': projectId,
    'subscriptionId': id ?? subscriptionId,
    'revision': revision,
  };

  void emit({
    Map<String, dynamic>? body,
    String? id,
    String connector = 'connector',
    int? connectionGeneration,
  }) {
    events.add(
      ChatEvent(
        connectorId: connector,
        generation: connectionGeneration ?? generation,
        operation: 'project.mcp.updated',
        requestId: id ?? subscriptionId,
        body: body ?? update(),
      ),
    );
  }

  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async {
    calls.add((operation, Map.of(body)));
    if (operation == 'project.mcp.unsubscribe') {
      return {'version': 1, 'unsubscribed': true};
    }
    if (operation == 'project.mcp.subscribe') {
      if (failure != null) throw failure!;
      final id = body['subscriptionId'] as String;
      final revision = revisions.update(
        id,
        (r) => r + 1,
        ifAbsent: () => initialRevision,
      );
      if (eventBeforeResponse) {
        emit(
          body: update(id: id, revision: revision + 1),
        );
      }
      return pending?.future ?? update(id: id, revision: revision);
    }
    return switch (operation) {
      'project.mcp.snapshot' => data,
      'project.list' => {
        'version': 1,
        'projects': [
          {'id': projectId, 'name': 'Fixture project', 'path': '/work/fixture'},
        ],
        'pathEntry': false,
      },
      'chat.list' => {
        'version': 1,
        'chats': [chat],
        'cursor': null,
      },
      'chat.snapshot' => {
        'version': 1,
        'chat': chat,
        'status': 'idle',
        'cursor': null,
        'messages': [
          {
            'id': 'message',
            'role': 'assistant',
            'text': 'Conversation stays available.',
            'truncated': false,
          },
        ],
      },
      _ => throw StateError('Unexpected operation $operation'),
    };
  }

  Map<String, dynamic> get chat => {
    'id': 'ses_fixture',
    'title': 'Fixture chat',
    'updatedAt': 100,
  };
  Future<void> dispose() async {
    await changes.close();
    await events.close();
  }
}
