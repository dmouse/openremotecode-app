import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/domain/tool_run.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/features/chat/ui/image_message.dart';
import 'package:openremotecode/features/chat/ui/markdown_message.dart';
import 'package:openremotecode/features/chat/ui/thought_view.dart';
import 'package:openremotecode/features/settings/settings_view_model.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

import 'support/memory_settings_repository.dart';

void main() {
  final reasoning = jsonDecode(
    File('../packages/protocol/test/fixtures/chat-reasoning-v1.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  final image = jsonDecode(
    File('../packages/protocol/test/fixtures/chat-image-v1.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  final reasoningMessage = ChatMessage.parse(
    (reasoning['response']['messages'] as List).single as Map<String, dynamic>,
  );
  final imageMessage = ChatMessage.parse(
    (image['response']['messages'] as List).single as Map<String, dynamic>,
  );

  testWidgets('settings hide cached thoughts and images in a mounted chat', (
    tester,
  ) async {
    final settings = SettingsViewModel(MemorySettingsRepository());
    final model = ChatViewModel(_NoChatIO(), 'connector', settings: settings)
      ..conversation.messages = [reasoningMessage, imageMessage];
    await tester.pumpWidget(_app(ConversationView(model: model.conversation)));
    expect(find.byType(ThoughtView), findsNWidgets(2));
    expect(find.byType(ImageMessage), findsOneWidget);
    expect(find.byType(MarkdownMessage), findsNWidgets(3));

    await settings.setShowThinkingMessages(false);
    await settings.setShowImages(false);
    await tester.pump();
    expect(find.byType(ThoughtView), findsNothing);
    expect(find.byType(ImageMessage), findsNothing);
    expect(find.byType(MarkdownMessage), findsNWidgets(3));
    expect(tester.takeException(), isNull);

    await settings.setShowThinkingMessages(true);
    await settings.setShowImages(true);
    await tester.pump();
    expect(find.byType(ThoughtView), findsNWidgets(2));
    expect(find.byType(ImageMessage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    settings.dispose();
  });

  testWidgets('reasoning-only history has no phantom row or false invitation', (
    tester,
  ) async {
    final settings = SettingsViewModel(MemorySettingsRepository());
    final onlyThought = ChatMessage.parse({
      'id': 'only-thought',
      'role': 'assistant',
      'text': '',
      'truncated': false,
      'parts': [
        {'id': 'thought', 'type': 'reasoning', 'text': 'Considering the task'},
      ],
    });
    final model = ChatViewModel(_NoChatIO(), 'connector', settings: settings)
      ..conversation.messages = [onlyThought];
    await settings.setShowThinkingMessages(false);
    expect(
      visibleMessages(model.conversation.messages, showThoughts: false),
      isEmpty,
    );
    await tester.pumpWidget(_app(ConversationView(model: model.conversation)));
    expect(find.byKey(const ValueKey('message-only-thought')), findsNothing);
    expect(
      find.text('Some messages are hidden by your chat settings.'),
      findsOneWidget,
    );
    expect(find.text('Start this conversation with a message.'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    settings.dispose();
  });

  test(
    'hidden thoughts still break tool runs and preserve history helpers',
    () {
      final parts = [
        const ChatMessagePart(
          'tool-a',
          'tool',
          '',
          tool: ChatTool(operation: 'execute', status: 'completed'),
        ),
        const ChatMessagePart('thought', 'reasoning', 'thinking'),
        const ChatMessagePart(
          'tool-b',
          'tool',
          '',
          tool: ChatTool(operation: 'execute', status: 'completed'),
        ),
      ];
      expect(condenseToolRuns(parts).length, 3);
      expect(condenseToolRuns(parts).whereType<ToolRun>(), isEmpty);
      final imageOnlyPrompt = ChatMessage(
        'image-prompt',
        'user',
        '',
        false,
        parts: [imageMessage.parts!.single],
      );
      expect(userMessageIds([imageOnlyPrompt]), ['image-prompt']);
      expect(userMessageIds([imageOnlyPrompt], showImages: false), isEmpty);
    },
  );
}

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.light,
  home: Scaffold(body: child),
);

class _NoChatIO implements ChatRepository {
  @override
  bool chatOnline(String connectorId) => false;
  @override
  Stream<void> get chatConnectionChanges => const Stream.empty();
  @override
  Stream<ChatEvent> get chatEvents => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected chat IO');
}
