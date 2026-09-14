import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/features/chat/ui/tool_run_view.dart';
import 'package:openremotecode/features/chat/ui/tool_view.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

ChatMessagePart _toolPart(String id, String operation) => ChatMessagePart(
  id,
  'tool',
  '[Tool: $id]\n',
  tool: ChatTool(operation: operation, status: 'completed'),
);

void main() {
  testWidgets(
    'the condensed row tallies a new tool part the next time the message is rendered',
    (tester) async {
      final model = ChatViewModel(_Repository(), 'connector')
        ..conversation.messages = [
          ChatMessage(
            'm',
            'assistant',
            '',
            false,
            parts: [_toolPart('a', 'read'), _toolPart('b', 'read')],
          ),
        ];
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: ConversationView(model: model.conversation)),
        ),
      );
      await show();
      expect(find.text('Read 2 files'), findsOneWidget);
      model.conversation.messages = [
        ChatMessage(
          'm',
          'assistant',
          '',
          false,
          parts: [
            _toolPart('a', 'read'),
            _toolPart('b', 'read'),
            _toolPart('c', 'read'),
          ],
        ),
      ];
      await show();
      expect(find.text('Read 3 files'), findsOneWidget);
      expect(find.text('Read 2 files'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'an open sheet reflects a tool part that streams in while it is showing',
    (tester) async {
      final repo = _Repository()
        ..parts = [_toolPart('a', 'read'), _toolPart('b', 'read')];
      final model = ChatViewModel(repo, 'connector');
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      await model.openChat(model.chatList.chats.single);
      // Mirrors ChatFlowScreen's real ListenableBuilder wrapper: without it,
      // ConversationView never rebuilds on its own from notifyListeners.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: model,
              builder: (context, _) =>
                  ConversationView(model: model.conversation),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ToolRunView));
      await tester.pumpAndSettle();
      expect(find.byType(ToolView), findsNWidgets(2));
      // Both the still-visible condensed row behind the sheet and the
      // sheet's own title show the same tally.
      expect(find.text('Read 2 files'), findsNWidgets(2));

      // A new tool part streams in while the sheet is still open, through
      // the model's real update path (never a direct notifyListeners call).
      repo.parts = [...repo.parts, _toolPart('c', 'read')];
      await model.refresh();
      await tester.pumpAndSettle();

      expect(find.byType(ToolView), findsNWidgets(3));
      expect(find.text('Read 3 files'), findsNWidgets(2));
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      model.dispose();
    },
  );

  testWidgets(
    'the sheet auto-closes if its message ages out of bounded history',
    (tester) async {
      final repo = _Repository()
        ..parts = [_toolPart('a', 'read'), _toolPart('b', 'read')];
      final model = ChatViewModel(repo, 'connector');
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      await model.openChat(model.chatList.chats.single);
      // Mirrors ChatFlowScreen's real ListenableBuilder wrapper: without it,
      // ConversationView never rebuilds on its own from notifyListeners.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: model,
              builder: (context, _) =>
                  ConversationView(model: model.conversation),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ToolRunView));
      await tester.pumpAndSettle();
      expect(find.byType(ToolView), findsNWidgets(2));

      repo.emptySnapshot = true;
      await model.refresh();
      await tester.pumpAndSettle();

      expect(find.byType(ToolView), findsNothing);
      expect(find.byType(ToolRunView), findsNothing);
      expect(tester.takeException(), isNull);
      model.dispose();
    },
  );
}

class _Repository implements ChatRepository {
  List<ChatMessagePart> parts = [];
  bool emptySnapshot = false;

  @override
  Stream<void> get chatConnectionChanges => const Stream.empty();
  @override
  Stream<ChatEvent> get chatEvents => const Stream.empty();
  @override
  Object chatConnectionGeneration(String connectorId) => 0;
  @override
  bool chatOnline(String connectorId) => true;
  @override
  bool chatTrusted(String connectorId) => true;
  @override
  bool chatSupports(String connectorId, String operation) => false;
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

  Map<String, dynamic> _part(ChatMessagePart part) => {
    'id': part.id,
    'type': 'tool',
    'text': part.text,
    'tool': {'operation': part.tool!.operation, 'status': part.tool!.status},
  };

  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async => switch (operation) {
    'project.list' => {
      'projects': [
        {'id': 'project', 'name': 'Project', 'path': '/workspace'},
      ],
      'pathEntry': false,
    },
    'chat.list' => {
      'chats': [
        {'id': 'ses_run', 'title': 'Run', 'updatedAt': 1000},
      ],
      'cursor': null,
    },
    'chat.snapshot' => {
      'version': 1,
      'chat': {'id': 'ses_run', 'title': 'Run', 'updatedAt': 1000},
      'status': 'idle',
      'cursor': null,
      'messages': emptySnapshot
          ? <Map<String, dynamic>>[]
          : [
              {
                'id': 'msg_run',
                'role': 'assistant',
                'truncated': false,
                'text': parts.map((p) => p.text).join(),
                'parts': parts.map(_part).toList(),
              },
            ],
    },
    _ => throw UnimplementedError(),
  };
}
