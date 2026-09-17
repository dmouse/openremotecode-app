import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/chat_flow_screen.dart';
import 'package:openremotecode/features/chat/ui/subtask_view.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

final _fixture = jsonDecode(
  File('../packages/protocol/test/fixtures/chat-subtasks-v1.json')
      .readAsStringSync(),
) as Map<String, dynamic>;
Map<String, dynamic> get _snapshot =>
    jsonDecode(jsonEncode(_fixture['response'])) as Map<String, dynamic>;
const _projectId = 'adfcaa47-d299-4d49-9137-fbac353c7cbd';
const _label = 'Explore Task — Inspect mobile color palette';

void main() {
  test(
    'shared snapshot preserves task identity, order, statistics and fallback',
    () {
      final message = ChatMessage.parse(
        (_snapshot['messages'] as List).single as Map<String, dynamic>,
      );
      expect(message.parts!.map((p) => p.type), ['text', 'subtask', 'text']);
      final task = message.parts![1].task!;
      expect(task.label, _label);
      expect(task.sessionId, 'ses_child');
      expect(task.toolCalls, 15);
      expect(task.statsComplete, isTrue);
      expect(task.durationMs, 82000);
      expect(message.text, contains('[Tool: task · completed]'));
    },
  );

  test(
    'untrusted task fields, metadata, counts and unsupported states fail',
    () {
      final wire =
          ((_snapshot['messages'] as List).single['parts'] as List)[1]['task']
              as Map<String, dynamic>;
      for (final extra in [
        {'title': ''},
        {'title': 'x' * 513},
        {'agent': 'x' * 65},
        {'metadata': <String, dynamic>{}},
        {'input': <String, dynamic>{}},
        {'output': 'secret'},
        {'status': 'aborted'},
        {'background': 1},
        {'sessionId': null},
        {'stats': null},
        for (final stats in [
          {'toolCalls': -1},
          {'toolCalls': 1.5},
          {'toolCalls': 5001},
          {'complete': null},
          {'durationMs': -1},
          {'durationMs': 9007199254740992},
          {'metadata': <String, dynamic>{}},
        ])
          {
            'stats': {...wire['stats'] as Map<String, dynamic>, ...stats},
          },
      ]) {
        expect(
          () => ChatSubtask.parse({...wire, ...extra}),
          throwsA(isA<Exception>()),
        );
      }
    },
  );

  testWidgets(
    'task row opens one child, is read-only and returns to the preserved parent draft',
    (tester) async {
      final repo = _Repository();
      await _open(tester, repo);
      expect(find.text(_label), findsOneWidget);
      expect(find.text('Completed · 15 toolcalls · 1m 22s'), findsOneWidget);
      expect(
        find.textContaining('[Tool: task', findRichText: true),
        findsNothing,
      );
      await tester.enterText(find.byType(TextField), 'Keep my parent draft');
      final duplicateTap = tester
          .widget<SubtaskView>(find.byType(SubtaskView))
          .onOpen!;
      await tester.tap(find.text(_label));
      duplicateTap();
      await tester.pumpAndSettle();
      expect(
        repo.calls.where((c) => c.$1 == 'chat.subtask.snapshot'),
        hasLength(1),
      );
      expect(
        {'version': 1, ...repo.calls.last.$2},
        {
          ..._fixture['request'] as Map<String, dynamic>,
          'includeTools': true,
          'includeShell': true,
          'includeTodos': true,
        },
      );
      expect(
        find.text('Child palette findings.', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Subtask conversation · View only'), findsOneWidget);
      expect(
        tester.widget<AppBar>(find.byType(AppBar)).backgroundColor,
        AppTheme.chatBackground,
      );
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
        AppTheme.chatBackground,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Chat options'), findsNothing);
      expect(find.byTooltip('Stop response'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_label), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Keep my parent draft',
      );
      expect(
        repo.calls.any(
          (c) => ['chat.prompt', 'chat.create', 'chat.abort'].contains(c.$1),
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'subtask row exposes a screen-reader action and wraps with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      var opened = false;
      final task = ChatMessage.parse((_snapshot['messages'] as List).single)
          .parts![1]
          .task!;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: ListView(
                children: [
                  SubtaskView(
                    task: task,
                    online: true,
                    onOpen: () => opened = true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final title = tester.widget<Text>(find.text(_label)).style!;
      final metadata = tester
          .widget<Text>(find.text('Completed · 15 toolcalls · 1m 22s'))
          .style!;
      expect(title.color, AppTheme.subtaskTitle);
      expect(title.fontWeight, FontWeight.w400);
      expect(metadata.color, AppTheme.muted);
      expect(metadata.fontSize, lessThan(title.fontSize!));
      expect(
        tester.widget<Icon>(find.byIcon(Icons.check)).color,
        AppTheme.subtaskTitle,
      );
      expect(
        tester.getSemantics(find.byType(SubtaskView)),
        matchesSemantics(
          label: '$_label. Completed · 15 toolcalls · 1m 22s',
          isButton: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.text(_label));
      expect(opened, isTrue);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'offline tasks and partial histories never claim exact or current progress',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: SubtaskView(
              task: const ChatSubtask(
                title: 'Palette',
                agent: 'explore',
                status: 'running',
                background: false,
                sessionId: 'child',
                toolCalls: 15,
                statsComplete: false,
              ),
              online: false,
            ),
          ),
        ),
      );
      expect(
        find.text('Offline · last known: running · 15+ toolcalls'),
        findsOneWidget,
      );
      expect(find.byType(TextButton), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  // A subtask carries no activity of its own, and a background one leaves the
  // parent session idle, so the header has to read the task's own status to
  // keep showing work in flight.
  for (final (status, badge) in [
    ('running', 'Working'),
    ('pending', 'Working'),
    ('retry', 'Working'),
    ('completed', 'Online'),
  ]) {
    testWidgets('an idle session with a $status task badges the agent $badge', (
      tester,
    ) async {
      final repo = _Repository()..taskStatus = status;
      // Never settled: a badge that spins keeps a live clock by design.
      await _openLive(tester, repo);
      expect(find.byTooltip(badge), findsOneWidget);
      expect(
        find.byIcon(Icons.circle),
        badge == 'Online' ? findsOneWidget : findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('late child reads cannot reopen a dismissed route', (
    tester,
  ) async {
    final repo = _Repository()..pending = Completer<Map<String, dynamic>>();
    await _open(tester, repo);
    await tester.tap(find.text(_label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();
    repo.pending!.complete(repo.child);
    await tester.pumpAndSettle();
    expect(find.text(_label), findsOneWidget);
    expect(
      find.text('Child palette findings.', findRichText: true),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('trust loss clears decrypted parent and child content', (
    tester,
  ) async {
    final repo = _Repository();
    await _open(tester, repo);
    await tester.tap(find.text(_label));
    await tester.pumpAndSettle();
    repo.trusted = false;
    repo.changes.add(null);
    await tester.pumpAndSettle();
    expect(find.text(_label), findsNothing);
    expect(
      find.text('Child palette findings.', findRichText: true),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'child failures leave a recoverable view and preserve the parent',
    (tester) async {
      final repo = _Repository()..failure = ChatFailure.notFound;
      await _open(tester, repo);
      await tester.tap(find.text(_label));
      await tester.pumpAndSettle();
      expect(find.text(ChatFailure.notFound.message), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_label), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'child model denies mutations and rejects mismatched parent responses',
    () async {
      final repo = _Repository();
      addTearDown(repo.changes.close);
      final model = ChatViewModel(repo, 'synthetic', parentSessionId: 'wrong')
        ..project = RemoteProject.parse(repo.project);
      addTearDown(model.dispose);
      await model.openChat(
        RemoteChat.parse(repo.child['chat'] as Map<String, dynamic>),
      );
      expect(model.error, ChatFailure.invalid.message);
      expect(model.conversation.messages, isEmpty);
      expect(model.conversation.canSend, isFalse);
      expect(model.conversation.canRename, isFalse);
      expect(model.conversation.canFork, isFalse);
      expect(await model.conversation.send('Do not send'), isFalse);
      await model.conversation.abort();
      expect(
        repo.calls.any((c) => ['chat.prompt', 'chat.abort'].contains(c.$1)),
        isFalse,
      );
    },
  );

  testWidgets(
    'older connectors keep the text fallback without unsupported request fields',
    (tester) async {
      final repo = _Repository()..supports = false;
      await _open(tester, repo);
      expect(repo.calls.last.$2.containsKey('includeSubtasks'), isFalse);
      expect(find.byType(SubtaskView), findsNothing);
      expect(
        find.textContaining('[Tool: task', findRichText: true),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}

/// Opens the conversation with plain pumps, for a chat whose own activity
/// animations keep a clock running and so never settle.
Future<void> _openLive(WidgetTester tester, _Repository repo) async {
  addTearDown(repo.changes.close);
  Future<void> pumps() async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: ChatFlowScreen(
        repository: repo,
        connectorId: 'synthetic',
        connectionName: 'Workstation',
      ),
    ),
  );
  await pumps();
  await tester.tap(find.text('Mobile app'));
  await pumps();
  await tester.tap(find.text('Review mobile chat'));
  await pumps();
}

Future<void> _open(WidgetTester tester, _Repository repo) async {
  addTearDown(repo.changes.close);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: ChatFlowScreen(
        repository: repo,
        connectorId: 'synthetic',
        connectionName: 'Workstation',
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Mobile app'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Review mobile chat'));
  await tester.pumpAndSettle();
}

class _Repository implements ChatRepository {
  final changes = StreamController<void>.broadcast();
  final calls = <(String, Map<String, dynamic>)>[];
  bool trusted = true, supports = true;
  ChatFailure? failure;
  Completer<Map<String, dynamic>>? pending;
  // Overrides the fixture task's own status; the session stays idle either way.
  String? taskStatus;
  final project = {
    'id': _projectId,
    'name': 'Mobile app',
    'path': '/workspace/mobile',
  };
  Map<String, dynamic> get child => {
    'version': 1,
    'chat': {
      'id': 'ses_child',
      'parentId': 'ses_parent',
      'title': 'Inspect mobile color palette',
      'updatedAt': 1788700000000,
    },
    'cursor': null,
    'status': 'idle',
    'messages': [
      {
        'id': 'child_message',
        'role': 'assistant',
        'text': 'Child palette findings.',
        'truncated': false,
      },
    ],
  };
  @override
  bool chatOnline(String id) => true;
  @override
  bool chatTrusted(String id) => trusted;
  @override
  bool chatSupports(String id, String operation) =>
      trusted &&
      !operation.startsWith('project.mcp.') &&
      !operation.startsWith('chat.stream.') &&
      operation != 'chat.activities' &&
      operation != 'chat.images' &&
      operation != 'chat.permissions' &&
      operation != 'chat.permission.reply' &&
      operation != 'chat.questions' &&
      operation != 'chat.question.reply' &&
      (operation != 'chat.subtask.snapshot' || supports);
  @override
  Stream<void> get chatConnectionChanges => changes.stream;
  @override
  Stream<ChatEvent> get chatEvents => const Stream.empty();
  @override
  Object chatConnectionGeneration(String connectorId) => 0;
  @override
  Future<Set<String>> pinnedChatIds(String id, String path) async => {};
  @override
  Future<Set<String>> setChatPinned(
    String id,
    String path,
    String session,
    bool pinned,
  ) async => {};
  @override
  Future<Map<String, dynamic>> chatRequest(
    String id,
    String operation,
    Map<String, dynamic> body,
  ) async {
    calls.add((operation, Map.of(body)));
    switch (operation) {
      case 'project.list':
        return {
          'version': 1,
          'projects': [project],
          'pathEntry': false,
        };
      case 'chat.list':
        return {
          'version': 1,
          'chats': [_snapshot['chat']],
          'cursor': null,
        };
      case 'chat.snapshot':
        final result = _snapshot;
        if (taskStatus != null) {
          for (final message in result['messages'] as List) {
            for (final part in (message as Map)['parts'] as List? ?? []) {
              final task = (part as Map)['task'];
              if (task is Map) task['status'] = taskStatus;
            }
          }
        }
        if (!supports) {
          for (final message in result['messages'] as List) {
            (message as Map).remove('parts');
          }
        }
        return result;
      case 'chat.subtask.snapshot':
        if (failure != null) throw failure!;
        return pending == null ? child : pending!.future;
      default:
        throw StateError('Unexpected request: $operation');
    }
  }
}
