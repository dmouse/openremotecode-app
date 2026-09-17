import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/features/chat/ui/markdown_message.dart';
import 'package:openremotecode/features/chat/ui/thought_view.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

void main() {
  final fixture = jsonDecode(
    File('../packages/protocol/test/fixtures/chat-reasoning-v1.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  final wire =
      (fixture['response']['messages'] as List).single as Map<String, dynamic>;

  test(
    'shared plugin fixture preserves ordered thoughts, answers and timing',
    () {
      final message = ChatMessage.parse(wire);
      expect(message.parts!.map((p) => p.type), [
        'text',
        'reasoning',
        'text',
        'reasoning',
        'text',
      ]);
      expect(message.parts![1].durationMs, 18800);
      expect(message.parts![3].durationMs, 6900);
      expect(message.text, wire['text']);
      final legacy = Map<String, dynamic>.from(wire)..remove('parts');
      expect(ChatMessage.parse(legacy).parts, isNull);
    },
  );

  test('parts reject malformed clocks, metadata, unsupported types and excessive content', () {
    final reasoning = {'id': 'r', 'type': 'reasoning', 'text': ''};
    for (final part in [
      {...reasoning, 'type': 'shell'},
      {
        ...reasoning,
        'metadata': {'signature': 'synthetic'},
      },
      {...reasoning, 'text': 'x' * 48001},
      {...reasoning, 'time': null},
      for (final time in [
        {'start': -1},
        {'start': 0.5},
        {'end': 1},
        {'start': 2, 'end': 1},
        {'start': 0, 'end': null},
        {'start': 0, 'end': 9007199254740992},
        {'start': 0, 'metadata': <String, dynamic>{}},
      ])
        {...reasoning, 'time': time},
    ]) {
      expect(
        () => ChatMessage.parse({
          ...wire,
          'text': '',
          'parts': [part],
        }),
        throwsFormatException,
      );
    }
    for (final parts in [
      null,
      [reasoning, reasoning],
      List.generate(101, (i) => {...reasoning, 'id': '$i'}),
      [
        {...reasoning, 'text': 'x' * 24001},
        {...reasoning, 'id': 's', 'text': 'x' * 24000},
      ],
    ]) {
      expect(
        () => ChatMessage.parse({...wire, 'text': '', 'parts': parts}),
        throwsFormatException,
      );
    }
    expect(
      () => ChatMessage.parse({...wire, 'role': 'user'}),
      throwsFormatException,
    );
    expect(
      () => ChatMessage.parse({...wire, 'text': 'different'}),
      throwsFormatException,
    );
  });

  testWidgets(
    'shared snapshot displays passive thoughts without duplicating their text',
    (tester) async {
      final model = ChatViewModel(_NoChatIO(), 'synthetic')
        ..conversation.messages = [ChatMessage.parse(wire)];
      try {
        await tester.pumpWidget(
          _app(ConversationView(model: model.conversation)),
        );
        await tester.pumpAndSettle();
        final title = find.text(
          'Thought: Prepare passive link builder · 18.8s',
          findRichText: true,
        );
        expect(title, findsOneWidget);
        expect(find.byIcon(Icons.psychology_outlined), findsNWidgets(2));
        expect(find.byType(MarkdownMessage), findsNWidgets(3));
        await tester.tap(title);
        await tester.pumpAndSettle();
        expect(find.byType(MarkdownMessage), findsNWidgets(3));
        expect(find.byType(ExpansionTile), findsNothing);
        expect(
          find.text('Check how links are displayed.', findRichText: true),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      }
    },
  );

  testWidgets(
    'a streaming thought updates in place and stops claiming work when offline',
    (tester) async {
      Future<void> show(ChatMessagePart part, {bool active = true}) async {
        await tester.pumpWidget(
          _app(
            ListView(
              children: [
                ThoughtView(
                  key: const ValueKey('same'),
                  part: part,
                  active: active,
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(
        const ChatMessagePart(
          'r',
          'reasoning',
          'Checking emulator pairing\n\nFirst detail',
          start: 1000,
        ),
      );
      final title = find.textContaining(
        'Thinking: Checking emulator pairing',
        findRichText: true,
      );
      expect(title, findsOneWidget);
      await show(
        const ChatMessagePart(
          'r',
          'reasoning',
          'Updating pairing status\n\nUpdated detail',
          start: 1000,
        ),
      );
      expect(
        find.textContaining(
          'Thinking: Updating pairing status',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Updated detail', findRichText: true), findsNothing);
      await show(
        const ChatMessagePart(
          'r',
          'reasoning',
          'Checking emulator pairing\n\nUpdated detail',
          start: 1000,
        ),
        active: false,
      );
      expect(
        find.text('Thought: Checking emulator pairing', findRichText: true),
        findsOneWidget,
      );
      await show(
        const ChatMessagePart(
          'r',
          'reasoning',
          'Checking emulator pairing\n\nCompleted detail',
          start: 1000,
          end: 9000,
        ),
      );
      expect(
        find.text(
          'Thought: Checking emulator pairing · 8.0s',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Completed detail', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty and untimed thoughts have truthful labels and no fabricated duration',
    (tester) async {
      await tester.pumpWidget(
        _app(
          ListView(
            children: const [
              ThoughtView(
                part: ChatMessagePart('r', 'reasoning', ''),
                active: true,
              ),
              ThoughtView(
                part: ChatMessagePart(
                  't',
                  'reasoning',
                  'Updating pairing status',
                  start: 1000,
                  end: 1471,
                ),
                active: false,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Thought', findRichText: true), findsOneWidget);
      expect(
        find.text(
          'Thought: Updating pairing status · 471ms',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'passive thoughts wrap with large text and have no button or tap semantics',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _app(
            ListView(
              padding: const EdgeInsets.all(20),
              children: const [
                ThoughtView(
                  part: ChatMessagePart(
                    'r',
                    'reasoning',
                    'Checking emulator pairing and updating the connection status\n\nSynthetic detail',
                    start: 1000,
                    end: 9000,
                  ),
                  active: false,
                ),
              ],
            ),
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getSemantics(
            find.textContaining('Thought:', findRichText: true),
          ),
          isSemantics(
            label: 'Thought: Checking emulator pairing and updating the connection status · 8.0s',
          ),
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}

Widget _app(Widget child, {double scale = 1}) => MaterialApp(
  theme: AppTheme.light,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(backgroundColor: Colors.white, body: child),
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
