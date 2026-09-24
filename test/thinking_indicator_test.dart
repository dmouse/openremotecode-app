import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/activity.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/activity_animation.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/features/chat/ui/thought_view.dart';
import 'package:openremotecode/features/chat/ui/typing_indicator.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

ChatMessage thought(String state, [String text = '']) => ChatMessage(
  'message',
  'assistant',
  '',
  false,
  parts: [
    ChatMessagePart(
      'thought',
      'reasoning',
      text,
      activity: AgentActivity('reasoning', state),
    ),
  ],
);

void main() {
  testWidgets(
    'typing footer does not move the message being read in older history',
    (tester) async {
      final repo = _Repository();
      final model = ChatViewModel(repo, 'connector')
        ..conversation.status = 'idle'
        ..conversation.messages = [
          for (var i = 0; i < 30; i++)
            ChatMessage('old-$i', 'user', 'Message $i', false),
        ];
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: ConversationView(model: model.conversation),
            ),
          ),
        ),
      );
      await show();
      final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
      scroll.jumpTo(160);
      await tester.pumpAndSettle();
      final message = find.byKey(const ValueKey('message-old-26'));
      final before = tester.getTopLeft(message);
      model.conversation.status = 'busy';
      await show();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(message).dy, closeTo(before.dy, 0.1));
      model.conversation.status = 'idle';
      await show();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(message).dy, closeTo(before.dy, 0.1));
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await repo.changes.close();
    },
  );
  testWidgets(
    'idle status does not animate retained running reasoning or tools',
    (tester) async {
      final repo = _Repository();
      final model = ChatViewModel(repo, 'connector')
        ..conversation.status = 'idle'
        ..conversation.messages = [thought('running')];
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: ConversationView(model: model.conversation)),
        ),
      );
      await show();
      await tester.pump();
      expect(find.text('Thinking… · last known'), findsOneWidget);
      expect(
        tester.widget<ActivitySpinner>(find.byType(ActivitySpinner)).running,
        isTrue,
      );
      expect(find.byType(TypingIndicator), findsNothing);
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'Historical work must not keep an animation clock live',
      );
      model.conversation.status = 'busy';
      await show();
      await tester.pump();
      expect(find.text('Thinking…'), findsOneWidget);
      expect(find.byType(TypingIndicator), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 1);
      model.conversation.messages = [thought('running', 'Live preview')];
      await show();
      await tester.pump();
      expect(find.text('Thinking: Live preview…'), findsOneWidget);
      model.conversation.messages = [thought('completed', 'Live preview')];
      model.conversation.status = 'busy';
      await show();
      await tester.pump();
      expect(find.text('Thought: Live preview'), findsOneWidget);
      expect(
        find.byType(TypingIndicator),
        findsOneWidget,
        reason: 'Overall work continues between thought blocks',
      );
      model.conversation.status = 'idle';
      model.conversation.messages = [
        const ChatMessage(
          'tool-message',
          'assistant',
          '',
          false,
          parts: [
            ChatMessagePart(
              'read',
              'tool',
              '',
              tool: ChatTool(
                operation: 'read',
                status: 'running',
                description: 'a.dart',
              ),
              activity: AgentActivity('read', 'running'),
            ),
          ],
        ),
      ];
      await show();
      await tester.pump();
      expect(
        tester.widget<ActivitySpinner>(find.byType(ActivitySpinner)).running,
        isFalse,
      );
      expect(find.byType(TypingIndicator), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      model.conversation.messages = [thought('completed', 'Live preview')];
      model.conversation.status = 'idle';
      await show();
      await tester.pump();
      await tester.pump();
      expect(find.byType(TypingIndicator), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await repo.changes.close();
    },
  );

  testWidgets('an older running part cannot keep a finished chat working', (
    tester,
  ) async {
    final repo = _Repository();
    final model = ChatViewModel(repo, 'connector')
      ..conversation.status = 'idle'
      ..conversation.messages = [
        thought('running'),
        const ChatMessage('reply', 'assistant', 'Done', false),
      ];
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ConversationView(model: model.conversation))),
    );
    await tester.pump();
    expect(model.conversation.isWorking, isFalse);
    expect(find.byType(TypingIndicator), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    await repo.changes.close();
  });

  testWidgets('only a recent verified background subtask can keep an idle parent working', (
    tester,
  ) async {
    final repo = _Repository();
    const task = ChatMessage(
      'task',
      'assistant',
      '',
      false,
      parts: [
        ChatMessagePart(
          'child',
          'subtask',
          '',
          task: ChatSubtask(
            title: 'Research',
            agent: 'explore',
            status: 'running',
            background: true,
            sessionId: 'ses_child',
          ),
        ),
      ],
    );
    final model = ChatViewModel(repo, 'connector')
      ..conversation.status = 'idle'
      ..conversation.messages = [task];
    Future<void> show() => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ConversationView(model: model.conversation))),
    );
    await show();
    expect(model.conversation.isWorking, isTrue);
    expect(find.byType(TypingIndicator), findsOneWidget);
    model.conversation.messages = [
      task,
      const ChatMessage('later', 'assistant', 'Done', false),
    ];
    await show();
    expect(model.conversation.isWorking, isTrue);
    model.conversation.messages = [
      task,
      for (var i = 0; i < 10; i++)
        ChatMessage('later-$i', 'assistant', 'Done', false),
    ];
    await show();
    expect(model.conversation.isWorking, isFalse);
    expect(find.byType(TypingIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    await repo.changes.close();
  });

  testWidgets(
    'animation gates keep known running thoughts last-known rather than completed',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActivityAnimations(
              enabled: true,
              child: ThoughtView(
                part: thought('running', 'Preview').parts!.single,
                active: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Thinking: Preview… · last known'), findsOneWidget);
      expect(
        tester.widget<ActivitySpinner>(find.byType(ActivitySpinner)).running,
        isTrue,
      );
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'typing dots disappear offline and use static dots for reduced motion',
    (tester) async {
      final repo = _Repository();
      final model = ChatViewModel(repo, 'connector')
        ..conversation.status = 'busy';
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: ConversationView(model: model.conversation),
            ),
          ),
        ),
      );
      await show();
      await tester.pump();
      expect(find.byType(TypingIndicator), findsOneWidget);
      expect(
        find.text('Start this conversation with a message.'),
        findsNothing,
      );
      expect(tester.binding.transientCallbackCount, 0);
      repo.online = false;
      repo.changes.add(null);
      await show();
      await tester.pump();
      expect(find.byType(TypingIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await repo.changes.close();
    },
  );
}

class _Repository implements ChatRepository {
  bool online = true;
  final changes = StreamController<void>.broadcast(sync: true);
  @override
  bool chatOnline(String id) => online;
  @override
  bool chatTrusted(String id) => true;
  @override
  Stream<void> get chatConnectionChanges => changes.stream;
  @override
  Stream<ChatEvent> get chatEvents => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call');
}
