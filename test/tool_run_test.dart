import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/domain/tool_run.dart';

ChatMessagePart _tool(
  String id,
  String operation, {
  String status = 'completed',
}) => ChatMessagePart(
  id,
  'tool',
  '[Tool: $id]\n',
  tool: ChatTool(operation: operation, status: status),
);

void main() {
  test('a run below the threshold renders its parts individually', () {
    expect(condenseToolRuns([_tool('a', 'read')]), [_isPart('a')]);
    expect(condenseToolRuns([]), isEmpty);
  });

  test('a run at or above the threshold condenses into one ToolRun', () {
    final plan = condenseToolRuns([_tool('a', 'read'), _tool('b', 'search')]);
    expect(plan, hasLength(1));
    final run = plan.single as ToolRun;
    expect(run.parts.map((p) => p.id), ['a', 'b']);
  });

  test('text, reasoning, subtask and image parts always break a run', () {
    final between = ChatMessagePart('mid', 'reasoning', 'thinking');
    final plan = condenseToolRuns([
      _tool('a', 'read'),
      _tool('b', 'read'),
      between,
      _tool('c', 'edit'),
      _tool('d', 'edit'),
    ]);
    expect(plan, [
      isA<ToolRun>().having((r) => r.parts.map((p) => p.id), 'ids', ['a', 'b']),
      between,
      isA<ToolRun>().having((r) => r.parts.map((p) => p.id), 'ids', ['c', 'd']),
    ]);
  });

  test('a custom minLength is honored', () {
    final twoTools = [_tool('a', 'read'), _tool('b', 'read')];
    expect(condenseToolRuns(twoTools, minLength: 3), twoTools);
    expect(condenseToolRuns(twoTools, minLength: 2), hasLength(1));
  });

  test(
    'summary tallies by operation in a fixed order with natural phrasing',
    () {
      String summaryOf(List<ChatMessagePart> parts) => ToolRun(parts).summary;
      expect(
        summaryOf([_tool('a', 'execute'), _tool('b', 'tool')]),
        'Ran a command, used a tool',
      );
      expect(
        summaryOf([
          _tool('a', 'execute'),
          _tool('b', 'execute'),
          _tool('c', 'execute'),
          _tool('d', 'tool'),
        ]),
        'Ran 3 commands, used a tool',
      );
      expect(
        summaryOf([
          _tool('a', 'edit'),
          _tool('b', 'edit'),
          _tool('c', 'read'),
          _tool('d', 'execute'),
        ]),
        'Ran a command, edited 2 files, read a file',
      );
      expect(summaryOf([_tool('a', 'search')]), 'Searched once');
      expect(
        summaryOf([_tool('a', 'search'), _tool('b', 'search')]),
        'Searched 2 times',
      );
    },
  );

  test('a run is failed/running when any part is, not only the last', () {
    final run = ToolRun([
      _tool('a', 'read'),
      _tool('b', 'execute', status: 'error'),
      _tool('c', 'edit', status: 'running'),
    ]);
    expect(run.failed, isTrue);
    expect(run.running, isTrue);
    expect(ToolRun([_tool('a', 'read')]).failed, isFalse);
    expect(ToolRun([_tool('a', 'read')]).running, isFalse);
  });

  test('condensedShellPartIds agrees exactly with the shell ids condenseToolRuns absorbs', () {
    final parts = [
      _tool('a', 'read'),
      _shellTool('s'), // absorbed: part of a run of 2 with 'a'
      _text('lone'),
      _shellTool('b'), // inline: alone, below the threshold
    ];
    final absorbed = condensedShellPartIds(parts);
    final plan = condenseToolRuns(parts);
    final expectedAbsorbed = <String>{
      for (final item in plan)
        if (item is ToolRun)
          for (final part in item.parts)
            if (part.tool!.shell != null) part.id,
    };
    expect(absorbed, expectedAbsorbed);
    expect(absorbed, {'s'});
  });

  group('cross-message merging', () {
    ChatMessage toolMessage(String id, {String operation = 'read'}) =>
        ChatMessage(id, 'assistant', '', false, parts: [_tool(id, operation)]);
    ChatMessage mixedMessage(String id) => ChatMessage(
      id,
      'assistant',
      '',
      false,
      parts: [
        ChatMessagePart('$id-r', 'reasoning', 'thinking'),
        _tool(id, 'read'),
      ],
    );

    test(
      'isPureToolMessage requires an assistant message made only of tool parts',
      () {
        expect(isPureToolMessage(toolMessage('a')), isTrue);
        expect(isPureToolMessage(mixedMessage('a')), isFalse);
        expect(
          isPureToolMessage(const ChatMessage('u', 'user', 'hi', false)),
          isFalse,
        );
        expect(
          isPureToolMessage(const ChatMessage('e', 'assistant', '', false)),
          isFalse,
        );
        expect(
          isPureToolMessage(
            ChatMessage(
              't',
              'assistant',
              '',
              true,
              parts: [_tool('t', 'read')],
            ),
          ),
          isFalse,
          reason: 'a truncated message is never poolable',
        );
      },
    );

    test('pureToolMessageRuns finds only maximal runs of two or more', () {
      final messages = [
        toolMessage('a'),
        toolMessage('b'),
        mixedMessage('c'),
        toolMessage('d'), // lone: below the threshold
        const ChatMessage('u', 'user', 'hi', false),
        toolMessage('e'),
        toolMessage('f'),
        toolMessage('g'),
      ];
      expect(pureToolMessageRuns(messages), [(0, 1), (5, 7)]);
    });

    test(
      'visibleMessages drops blank projected records but keeps truncated ones',
      () {
        final messages = [
          const ChatMessage('blank', 'user', '  ', false),
          const ChatMessage('blank-parts', 'assistant', '', false, parts: []),
          toolMessage('a'),
          const ChatMessage('trunc', 'user', '', true),
        ];
        expect(visibleMessages(messages).map((m) => m.id), ['a', 'trunc']);
      },
    );

    test('findToolRun re-derives a merged run fresh and returns null once it is gone', () {
      final messages = [toolMessage('a'), toolMessage('b'), toolMessage('c')];
      final run = findToolRun(messages, 'a', 'a');
      expect(run, isNotNull);
      expect(run!.parts.map((p) => p.id), ['a', 'b', 'c']);
      // A non-anchor id never leads a run of its own.
      expect(findToolRun(messages, 'b', 'b'), isNull);
      // Falls back to plain per-message condensing for a run inside one message.
      final single = [mixedMessage('x')];
      expect(
        findToolRun(single, 'x', 'x'),
        isNull,
        reason: 'a run of 1 stays uncondensed',
      );
      // Gone from history entirely.
      expect(findToolRun([], 'a', 'a'), isNull);
    });
  });
}

ChatMessagePart _text(String id) => ChatMessagePart(id, 'text', 'hi');

ChatMessagePart _shellTool(String id) => ChatMessagePart(
  id,
  'tool',
  '[Tool: bash]\n',
  tool: const ChatTool(
    operation: 'execute',
    status: 'completed',
    shell: ChatShell(command: 'echo hi', output: 'hi', truncated: false),
  ),
);

Matcher _isPart(String id) =>
    isA<ChatMessagePart>().having((p) => p.id, 'id', id);
