import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/features/chat/ui/subtask_view.dart';
import 'package:openremotecode/features/chat/ui/thought_view.dart';
import 'package:openremotecode/features/chat/ui/tool_run_view.dart';
import 'package:openremotecode/features/chat/ui/tool_view.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

final _fixture = jsonDecode(
  File('../packages/protocol/test/fixtures/chat-tools-v1.json')
      .readAsStringSync(),
) as Map<String, dynamic>;
ChatMessage get _message =>
    ChatMessage.parse((_fixture['response']['messages'] as List).single);
final _shellFixture = jsonDecode(
  File('../packages/protocol/test/fixtures/chat-shell-v1.json')
      .readAsStringSync(),
) as Map<String, dynamic>;

void main() {
  test(
    'shell fixture parses with strict fields and a shared display budget',
    () {
      final source =
          _shellFixture['response']['messages'][1] as Map<String, dynamic>;
      final message = ChatMessage.parse(source);
      expect(
        message.parts!.single.tool!.shell!.command,
        "printf 'shell fixture\\n'",
      );
      expect(message.parts!.single.tool!.shell!.output, 'shell fixture\n');
      final tool = source['parts'][0]['tool'] as Map<String, dynamic>;
      final shell = tool['shell'] as Map<String, dynamic>;
      for (final invalid in [
        {...tool, 'operation': 'read'},
        {...tool, 'shell': null},
        {
          ...tool,
          'shell': {...shell, 'command': 'c' * 8001},
        },
        {
          ...tool,
          'shell': {...shell, 'output': 'o' * 32001},
        },
        {
          ...tool,
          'shell': {...shell, 'truncated': null},
        },
        {
          ...tool,
          'shell': {...shell, 'input': <String, dynamic>{}},
        },
      ]) {
        expect(() => ChatTool.parse(invalid), throwsA(isA<Exception>()));
      }
      final oversized = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
      oversized['parts'][0]['tool']['shell'] = {
        'command': 'c' * 8000,
        'output': 'o' * 32000,
        'truncated': false,
      };
      oversized['parts'].add({
        'id': 'text',
        'type': 'text',
        'text': 't' * 8000,
      });
      oversized['text'] += 't' * 8000;
      expect(() => ChatMessage.parse(oversized), throwsFormatException);
      final truncated = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
      truncated['parts'][0]['tool']['shell']['truncated'] = true;
      expect(() => ChatMessage.parse(truncated), throwsFormatException);
      truncated['truncated'] = true;
      expect(ChatMessage.parse(truncated).truncated, isTrue);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'shell toggle hides command/output and survives updates at scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        final source = jsonDecode(
          jsonEncode(_shellFixture['response']['messages'][1]),
        ) as Map<String, dynamic>;
        final model = ChatViewModel(_Repository(), 'connector')
          ..conversation.messages = [
            ChatMessage.parse(_shellFixture['response']['messages'][0]),
            ChatMessage.parse(source),
          ];
        Future<void> show() => tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: ConversationView(model: model.conversation),
              ),
            ),
          ),
        );
        await show();
        expect(find.text('You'), findsNothing);
        expect(find.byKey(const ValueKey('message-msg_marker')), findsNothing);
        expect(find.text("printf 'shell fixture\\n'"), findsNothing);
        expect(find.text('shell fixture\n'), findsNothing);
        await tester.tap(find.byType(TextButton));
        await tester.pump();
        expect(find.text("printf 'shell fixture\\n'"), findsOneWidget);
        expect(find.text('shell fixture\n'), findsOneWidget);
        expect(find.textContaining('[Tool:'), findsNothing);
        // Compact full-width shell headers share the 32px activity row rhythm.
        expect(
          tester.getSize(find.byType(TextButton)).height,
          greaterThanOrEqualTo(32),
        );
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await tester.tap(find.byType(TextButton));
        await tester.pump();
        expect(find.text("printf 'shell fixture\\n'"), findsNothing);
        expect(find.text('shell fixture\n'), findsNothing);
        expect(find.bySemanticsLabel(RegExp('shell fixture')), findsNothing);
        expect(find.text('Run command · Completed · 250ms'), findsOneWidget);

        source['parts'][0]['tool']['shell']['output'] = 'new output';
        final second = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
        second['id'] = 'msg_second';
        second['parts'][0]['tool']['shell']['command'] = 'second command';
        // A real message between them keeps these two standalone rows apart
        // -- two bare adjacent tool-only messages would otherwise condense
        // into one cross-message ToolRun (see tool_run_test.dart), which is
        // not what this test exercises.
        model.conversation.messages = [
          ChatMessage.parse(source),
          ChatMessage('msg_between', 'user', 'ok', false),
          ChatMessage.parse(second),
        ];
        await show();
        // New rows start closed independently, even with the same part ID.
        expect(find.text("printf 'shell fixture\\n'"), findsNothing);
        expect(find.text('second command'), findsNothing);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('message-msg_second')),
            matching: find.byType(TextButton),
          ),
        );
        await tester.pump();
        expect(find.text('second command'), findsOneWidget);
        expect(find.text('new output'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('message-msg_shell')),
            matching: find.byType(TextButton),
          ),
        );
        await tester.pump();
        expect(find.text("printf 'shell fixture\\n'"), findsOneWidget);
        expect(find.text('new output'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      },
    );
  }

  testWidgets(
    'expanded shells survive list recycling and reset closed with history',
    (tester) async {
      final source =
          _shellFixture['response']['messages'][1] as Map<String, dynamic>;
      final model = ChatViewModel(_Repository(), 'connector')
        ..conversation.messages = [
          for (var i = 0; i < 40; i++)
            ChatMessage('older-$i', 'user', 'Earlier message $i\n' * 5, false),
          ChatMessage.parse(source),
        ];
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: ConversationView(model: model.conversation)),
        ),
      );
      await show();
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-msg_shell')), findsNothing);
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-msg_shell')), findsOneWidget);
      expect(find.text("printf 'shell fixture\\n'"), findsOneWidget);
      model.conversation.messageHistoryRevision++;
      await show();
      expect(find.text("printf 'shell fixture\\n'"), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'shell display handles live, empty, failed and truncated output as passive text',
    (tester) async {
      final model = ChatViewModel(_Repository(), 'connector');
      final source = jsonDecode(
        jsonEncode(_shellFixture['response']['messages'][1]),
      ) as Map<String, dynamic>;
      final tool = source['parts'][0]['tool'];
      Future<void> show(
        String status,
        String output, {
        bool truncated = false,
      }) async {
        source['text'] = source['parts'][0]['text'] =
            '[Tool: bash · $status]\n';
        source['truncated'] = truncated;
        tool['status'] = status;
        tool['shell'] = {
          'command': 'fixture',
          'output': output,
          'truncated': truncated,
        };
        model.conversation.messages = [ChatMessage.parse(source)];
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(body: ConversationView(model: model.conversation)),
          ),
        );
      }

      await show('running', '');
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      expect(find.text('Waiting for output…'), findsOneWidget);
      await show('running', 'partial output');
      expect(find.text('partial output'), findsOneWidget);
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      await show('completed', 'final output');
      expect(find.text('final output'), findsNothing);
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      expect(find.text('final output'), findsOneWidget);
      await show('completed', '');
      expect(find.text('No output'), findsOneWidget);
      await show(
        'error',
        '\x1b[31mfailed\x1b[0m\n[link](https://example.test)\n<img src="https://example.test">',
      );
      expect(
        find.text(
          'failed\n[link](https://example.test)\n<img src="https://example.test">',
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await show('completed', 'short output', truncated: true);
      expect(find.text('Shell details shortened for display.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  test(
    'shared tools and compact file reference parse without private content',
    () {
      expect(_message.parts!.map((p) => p.type), ['tool', 'tool', 'tool']);
      expect(
        _message.parts![1].tool!.description,
        '"Theme|Color" in mobile/lib',
      );
      expect(_message.parts!.first.tool!.description, 'lib/example.dart');
      expect(_message.parts!.last.tool!.durationMs, 2000);
      final user = ChatMessage.parse(_fixture['userResponse']);
      expect(user.text, 'Review @example.dart\n[File: example.dart]\n');
      expect(user.text, isNot(contains('PRIVATE_')));
      final tool =
          (_fixture['response']['messages'] as List).single['parts'][0]['tool']
              as Map<String, dynamic>;
      for (final extra in [
        {'operation': 'shell'},
        {'status': 'success'},
        {'description': ''},
        {'description': 'x' * 257},
        {'description': null},
        {'durationMs': -1},
        {'durationMs': 0.5},
        {'durationMs': 9007199254740992},
        {'durationMs': null},
        {'input': <String, dynamic>{}},
        {'output': 'private'},
        {'error': 'private'},
      ]) {
        expect(
          () => ChatTool.parse({...tool, ...extra}),
          throwsA(isA<Exception>()),
        );
      }
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets('activity rows share gutters and wrap at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const ThoughtView(
                    part: ChatMessagePart('r', 'reasoning', 'Check layout'),
                    active: false,
                  ),
                  ToolView(
                    tool: _message.parts!.first.tool!,
                    online: true,
                    active: false,
                  ),
                  ToolView(
                    tool: _message.parts!.last.tool!,
                    online: true,
                    active: false,
                  ),
                  SubtaskView(
                    task: const ChatSubtask(
                      title: 'Inspect the tool presentation and wrapping',
                      agent: 'explore',
                      status: 'completed',
                      background: false,
                      sessionId: 'child',
                    ),
                    online: true,
                    onOpen: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      for (final text in [
        'Thought: Check layout',
        'lib/example.dart',
        'Check formatting (Failed · 2.0s)',
        'Explore Task — Inspect the tool presentation and wrapping',
        'Completed',
      ]) {
        expect(
          tester.getTopLeft(find.text(text, findRichText: true)).dx,
          20 + 12 * scale + 8,
        );
      }
      final title = tester.widget<Text>(find.text('lib/example.dart'));
      expect(title.style!.color, AppTheme.subtaskTitle);
      expect(
        title.style!.fontFamily,
        AppTheme.light.textTheme.bodyMedium!.fontFamily,
      );
      expect(title.style!.fontSize, 12);
      expect(title.style!.fontWeight, FontWeight.w400);
      expect(find.text('Completed · 250ms'), findsNothing);
      expect(
        find.bySemanticsLabel('Read lib/example.dart. Completed · 250ms'),
        findsOneWidget,
      );
      final failure = tester.widget<Text>(
        find.text('Check formatting (Failed · 2.0s)'),
      );
      expect(
        (failure.textSpan! as TextSpan).children!.last.style!.color,
        AppTheme.light.colorScheme.error,
      );
      final tools = find.byType(ToolView);
      expect(tester.getSize(tools.first).height, greaterThanOrEqualTo(32));
      expect(
        tester.getBottomLeft(tools.first).dy,
        tester.getTopLeft(tools.last).dy,
      );
      expect(
        tester.getSize(find.byType(ThoughtView)).height,
        greaterThanOrEqualTo(32),
      );
      expect(
        tester.getSize(find.byType(SubtaskView)).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        find.descendant(of: tools, matching: find.byType(TextButton)),
        findsNothing,
      );
      expect(find.byIcon(Icons.subdirectory_arrow_right), findsNothing);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
    });
  }

  testWidgets('tool status is explicit, passive and truthful offline or idle', (
    tester,
  ) async {
    for (final (online, active, label) in [
      (true, true, 'Running'),
      (false, true, 'Offline · last known: running'),
      (true, false, 'Last known: running'),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ToolView(
              tool: const ChatTool(
                operation: 'tool',
                status: 'running',
                durationMs: 100,
              ),
              online: online,
              active: active,
            ),
          ),
        ),
      );
      expect(find.text(label), findsOneWidget);
      expect(find.textContaining('100ms'), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('short completed tools fit a single compact row', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ListView(
            children: [
              ToolView(
                tool: const ChatTool(
                  operation: 'read',
                  description: 'a.dart',
                  status: 'completed',
                  durationMs: 250,
                ),
                online: true,
                active: false,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('a.dart'), findsOneWidget);
    expect(find.textContaining('Read'), findsNothing);
    expect(find.textContaining('Completed'), findsNothing);
    expect(tester.getSize(find.byType(ToolView)).height, 32);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'conversation renders tools once and preserves message boundaries and updates',
    (tester) async {
      final model = ChatViewModel(_Repository(), 'connector')
        ..conversation.messages = [
          ChatMessage.parse(_fixture['userResponse']),
          _message,
        ];
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: ConversationView(model: model.conversation)),
        ),
      );
      await show();
      // Three consecutive tool parts condense into one summary row.
      expect(find.byType(ToolView), findsNothing);
      expect(find.byType(ToolRunView), findsOneWidget);
      expect(
        find.text('Ran a command, read a file, searched once'),
        findsOneWidget,
      );
      expect(find.textContaining('[Tool:', findRichText: true), findsNothing);
      expect(find.textContaining('PRIVATE_', findRichText: true), findsNothing);
      await tester.tap(find.byType(ToolRunView));
      await tester.pumpAndSettle();
      expect(find.byType(ToolView), findsNWidgets(3));
      expect(find.text('"Theme|Color" in mobile/lib'), findsOneWidget);
      expect(find.textContaining('PRIVATE_', findRichText: true), findsNothing);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      final container = tester.widget<Padding>(
        find.byKey(const ValueKey('message-msg_tools')),
      );
      expect(container.padding, const EdgeInsets.only(bottom: 12));
      expect(
        tester.widget<ListView>(find.byType(ListView)).padding,
        const EdgeInsets.all(20),
      );
      final source = jsonDecode(
        jsonEncode((_fixture['response']['messages'] as List).single),
      ) as Map<String, dynamic>;
      source['parts'][0]['tool']['description'] = 'lib/updated.dart';
      model.conversation.messages = [ChatMessage.parse(source)];
      await show();
      await tester.tap(find.byType(ToolRunView));
      await tester.pumpAndSettle();
      expect(find.text('lib/updated.dart'), findsOneWidget);
      expect(find.text('lib/example.dart'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  test('older connectors never receive the new snapshot field', () async {
    final repo = _Repository();
    final model = ChatViewModel(repo, 'connector');
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    await model.openChat(model.chatList.chats.single);
    expect(repo.requests.last.containsKey('includeTools'), isFalse);
    expect(repo.requests.last.containsKey('includeShell'), isFalse);
    repo.tools = true;
    await model.refresh();
    expect(repo.requests.last['includeTools'], isTrue);
    expect(repo.requests.last.containsKey('includeShell'), isFalse);
    repo.shell = true;
    await model.refresh();
    expect(repo.requests.last['includeShell'], isTrue);
    repo.tools = false;
    await model.refresh();
    expect(repo.requests.last.containsKey('includeShell'), isFalse);
    model.dispose();
  });

  testWidgets(
    'operation names are semantic only and missing descriptions leave just the icon',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ListView(
              children: [
                for (final operation in [
                  'read',
                  'edit',
                  'write',
                  'search',
                  'list',
                  'execute',
                  'fetch',
                ])
                  ToolView(
                    tool: ChatTool(
                      operation: operation,
                      status: 'completed',
                      description: 'target',
                    ),
                    online: true,
                    active: false,
                  ),
                const ToolView(
                  tool: ChatTool(operation: 'tool', status: 'completed'),
                  online: true,
                  active: false,
                ),
                const ToolView(
                  tool: ChatTool(
                    operation: 'tool',
                    status: 'completed',
                    description: 'Capture screen',
                  ),
                  online: true,
                  active: false,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('target'), findsNWidgets(7));
      expect(find.text('Capture screen'), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsNWidgets(2));
      for (final label in [
        'Read',
        'Edit',
        'Write',
        'Search',
        'List',
        'Run',
        'Fetch',
        'Tool',
      ]) {
        expect(find.text(label), findsNothing);
      }
      expect(find.bySemanticsLabel('Read target. Completed'), findsOneWidget);
      expect(find.bySemanticsLabel('Tool. Completed'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Tool Capture screen. Completed'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  for (final firstType in ['tool', 'reasoning', 'subtask']) {
    for (final secondType in ['tool', 'reasoning', 'subtask']) {
      // Two adjacent tool-only messages now condense into one cross-message
      // ToolRun (see tool_run_test.dart and the dedicated test below) rather
      // than rendering as two separately-spaced rows, so this pair no
      // longer fits the generic same-spacing comparison below.
      if (firstType == 'tool' && secondType == 'tool') continue;
      testWidgets('$firstType to $secondType uses the same activity spacing', (
        tester,
      ) async {
        ChatMessage message(String id, String type) {
          final part = ChatMessagePart(
            id,
            type,
            type == 'reasoning' ? 'Checking' : '',
            tool: type == 'tool'
                ? const ChatTool(
                    operation: 'read',
                    status: 'completed',
                    description: 'a.dart',
                  )
                : null,
            task: type == 'subtask'
                ? const ChatSubtask(
                    title: 'Inspect',
                    agent: 'explore',
                    status: 'completed',
                    background: false,
                  )
                : null,
          );
          return ChatMessage(id, 'assistant', '', false, parts: [part]);
        }

        final model = ChatViewModel(_Repository(), 'connector')
          ..conversation.messages = [
            const ChatMessage('user', 'user', 'Check this', false),
            message('first', firstType),
            const ChatMessage('empty', 'assistant', ' \n', false),
            const ChatMessage('empty-parts', 'assistant', '', false, parts: []),
            message('second', secondType),
            const ChatMessage('answer', 'assistant', 'Answer', false),
          ];
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(body: ConversationView(model: model.conversation)),
          ),
        );
        expect(find.byKey(const ValueKey('message-empty')), findsNothing);
        expect(find.byKey(const ValueKey('message-empty-parts')), findsNothing);
        expect(
          tester.getBottomLeft(find.byKey(const ValueKey('first'))).dy,
          tester.getTopLeft(find.byKey(const ValueKey('second'))).dy,
        );
        expect(
          tester
              .widget<Padding>(find.byKey(const ValueKey('message-first')))
              .padding,
          EdgeInsets.zero,
        );
        expect(
          tester
              .widget<Padding>(find.byKey(const ValueKey('message-second')))
              .padding,
          const EdgeInsets.only(bottom: 12),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      });
    }
  }

  testWidgets(
    'adjacent tool-only messages condense into one cross-message ToolRun',
    (tester) async {
      ChatMessage toolMessage(String id) => ChatMessage(
        id,
        'assistant',
        '',
        false,
        parts: [
          ChatMessagePart(
            id,
            'tool',
            '',
            tool: const ChatTool(
              operation: 'read',
              status: 'completed',
              description: 'a.dart',
            ),
          ),
        ],
      );
      final model = ChatViewModel(_Repository(), 'connector')
        ..conversation.messages = [
          const ChatMessage('user', 'user', 'Check this', false),
          toolMessage('first'),
          toolMessage('second'),
          const ChatMessage('answer', 'assistant', 'Answer', false),
        ];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: ConversationView(model: model.conversation)),
        ),
      );
      expect(find.byKey(const ValueKey('message-second')), findsOneWidget);
      expect(
        tester
            .widget<SizedBox>(find.byKey(const ValueKey('message-second')))
            .child,
        isNull,
      );
      expect(find.byType(ToolRunView), findsOneWidget);
      expect(find.text('Read 2 files'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'tool runs keep the same spacing across keyed message boundaries',
    (tester) async {
      final parts = _message.parts!;
      final first = ChatMessage(
        'first',
        'assistant',
        parts.first.text,
        false,
        parts: [parts.first, const ChatMessagePart('space', 'text', '\n  ')],
      );
      final second = ChatMessage(
        'second',
        'assistant',
        parts[1].text,
        false,
        parts: [const ChatMessagePart('space2', 'text', '  '), parts[1]],
      );
      final model = ChatViewModel(_Repository(), 'connector')
        ..conversation.messages = [
          const ChatMessage('user', 'user', 'Find the theme', false),
          first,
          second,
          const ChatMessage('prose', 'assistant', 'Here is the answer.', false),
        ];
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: ConversationView(model: model.conversation)),
        ),
      );
      await show();
      final read = find.byKey(ValueKey(parts.first.id));
      final search = find.byKey(ValueKey(parts[1].id));
      expect(tester.getBottomLeft(read).dy, tester.getTopLeft(search).dy);
      expect(
        tester
            .widget<Padding>(find.byKey(const ValueKey('message-first')))
            .padding,
        EdgeInsets.zero,
      );
      for (final id in ['user', 'second', 'prose']) {
        expect(
          tester.widget<Padding>(find.byKey(ValueKey('message-$id'))).padding,
          const EdgeInsets.only(bottom: 12),
        );
      }
      expect(find.byKey(const ValueKey('space')), findsNothing);
      expect(find.byKey(const ValueKey('space2')), findsNothing);
      final before = tester.getTopLeft(search);
      model.conversation.messages = [
        const ChatMessage('older', 'user', 'Earlier message', false),
        ...model.conversation.messages,
      ];
      await show();
      expect(tester.getTopLeft(search), before);
      expect(tester.takeException(), isNull);

      model.conversation.messages = [
        ChatMessage('first', 'assistant', first.text, true, parts: first.parts),
        second,
      ];
      await show();
      expect(
        tester
            .widget<Padding>(find.byKey(const ValueKey('message-first')))
            .padding,
        const EdgeInsets.only(bottom: 12),
      );
      expect(find.text('Long message shortened for display.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}

class _Repository implements ChatRepository {
  bool tools = false;
  bool shell = false;
  final requests = <Map<String, dynamic>>[];
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
  bool chatSupports(String connectorId, String operation) =>
      (operation == 'chat.tools' && tools) ||
      (operation == 'chat.shell' && shell);
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
    requests.add(body);
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
      'chat.snapshot' => Map<String, dynamic>.from(_fixture['response']),
      _ => throw UnimplementedError(),
    };
  }
}
