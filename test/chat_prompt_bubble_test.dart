import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/features/chat/ui/thought_view.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

void main() {
  testWidgets('a prompt fills the conversation width, whatever its length', (
    tester,
  ) async {
    final model = _conversation();
    addTearDown(model.dispose);
    await _show(tester, model);

    // Two prompts of very different lengths reach exactly the same edges:
    // the surface is the width of the conversation, not of the words on it.
    final short = _bubble(tester, 'short');
    final long = _bubble(tester, 'long');
    expect(short.left, long.left);
    expect(short.width, long.width);
    expect(short.width, greaterThan(0));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('only a plan prompt carries a Plan mark, and no rule beside it', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final model = _conversation();
    addTearDown(model.dispose);
    await _show(tester, model);

    expect(find.text('Plan'), findsOneWidget);
    expect(
      find.descendant(of: _row('planned'), matching: find.text('Plan')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Sent in Plan mode'), findsOneWidget);
    final mark = tester.widget<Text>(find.text('Plan')).style!;
    expect(mark.color, AppTheme.muted);
    expect(mark.fontStyle, FontStyle.italic);
    expect(mark.fontSize, 9);
    // Bottom right of its own prompt, under the words rather than beside them.
    final bubble = _bubble(tester, 'planned');
    final rect = tester.getRect(find.text('Plan'));
    expect(rect.right, lessThanOrEqualTo(bubble.right));
    expect(rect.center.dx, greaterThan(bubble.center.dx));
    expect(rect.top, greaterThan(tester.getRect(find.text('Plan it')).top));

    // The mark inside the prompt is the whole of it: no wrapper is left around
    // a prompt to draw a rule down its side.
    for (final id in ['planned', 'short']) {
      expect(
        find.descendant(of: _row(id), matching: find.byType(Container)),
        findsOneWidget,
        reason: 'the bubble is the only decorated box in the row',
      );
    }
    expect(
      tester
          .widget<Container>(
            find
                .descendant(
                  of: _row('planned'),
                  matching: find.byType(Container),
                )
                .first,
          )
          .decoration,
      BoxDecoration(
        color: AppTheme.codeSurface,
        borderRadius: BorderRadius.circular(12),
      ),
    );

    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets("the agent's own words keep the rule down their side", (
    tester,
  ) async {
    final model = _conversation();
    addTearDown(model.dispose);
    await _show(tester, model);

    final gutter = tester.widget<Container>(
      find.byKey(const ValueKey('plan-rule-planning')),
    );
    expect(
      gutter.decoration,
      const BoxDecoration(
        border: Border(left: BorderSide(color: AppTheme.info, width: 3)),
      ),
    );
    expect(gutter.padding, const EdgeInsets.only(left: 10));
    // The prose is inset by the gutter; a prompt starts at the edge.
    expect(
      tester.getRect(find.text('Working on the plan.')).left,
      greaterThan(_bubble(tester, 'planned').left),
    );

    // Tool runs and thought rows keep their own gutters, so the rule hugs the
    // prose beside them rather than enclosing the whole message.
    expect(find.byKey(const ValueKey('plan-rule-prose')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('plan-rule-prose')),
        matching: find.byType(ThoughtView),
      ),
      findsNothing,
    );
    expect(
      tester.getRect(find.byType(ThoughtView)).left,
      _bubble(tester, 'planned').left,
    );

    // Tool work, build-mode work, and the prompt that wears its own mark
    // instead all carry no rule at all.
    for (final id in ['planTool', 'reply']) {
      expect(
        find.descendant(of: _row(id), matching: find.byType(Container)),
        findsNothing,
        reason: '$id carries no plan rule',
      );
    }
    await tester.pumpWidget(const SizedBox());
  });
}

ChatViewModel _conversation() =>
    ChatViewModel(_Repository(), 'connector')
      ..conversation.messages = [
        const ChatMessage('short', 'user', 'Hosted?', false, mode: 'build'),
        const ChatMessage(
          'long',
          'user',
          'Where is this agent hosted, and who pays for it?',
          false,
          mode: 'build',
        ),
        const ChatMessage('planned', 'user', 'Plan it', false, mode: 'plan'),
        const ChatMessage(
          'planning',
          'assistant',
          'Working on the plan.',
          false,
          mode: 'plan',
        ),
        const ChatMessage(
          'planTool',
          'assistant',
          '',
          false,
          mode: 'plan',
          parts: [
            ChatMessagePart(
              'read',
              'tool',
              '',
              tool: ChatTool(operation: 'read', status: 'completed'),
            ),
          ],
        ),
        const ChatMessage(
          'planThought',
          'assistant',
          'The answer itself.',
          false,
          mode: 'plan',
          parts: [
            ChatMessagePart('thinking', 'reasoning', 'Weighing the options'),
            ChatMessagePart('prose', 'text', 'The answer itself.'),
          ],
        ),
        const ChatMessage('reply', 'assistant', 'Here is the answer.', false),
      ];

Future<void> _show(WidgetTester tester, ChatViewModel model) =>
    tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: ConversationView(model: model.conversation)),
      ),
    );

Finder _row(String id) => find.byKey(ValueKey('message-$id'));

Rect _bubble(WidgetTester tester, String id) => tester.getRect(
  find.descendant(of: _row(id), matching: find.byType(Container)).first,
);

class _Repository implements ChatRepository {
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
  ) async => {};
  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async => throw StateError('Unexpected $operation');
}
