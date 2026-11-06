import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/data/chat_list_stream.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/chat_row_activity.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

final fixture = jsonDecode(
  File('../packages/protocol/test/fixtures/chat-activity-v1.json')
      .readAsStringSync(),
) as Map<String, dynamic>;
const project = RemoteProject(
  '11111111-1111-4111-8111-111111111111',
  'App',
  '/app',
);

class Repository implements ChatRepository {
  final events = StreamController<ChatEvent>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];
  Object generation = Object();
  bool online = true, trusted = true;
  Map<String, dynamic>? historySummary;
  Completer<Map<String, dynamic>>? pending;
  @override
  bool chatSupports(String id, String op) =>
      ['chat.view', 'chat.list.subscribe', 'chat.list.updated'].contains(op);
  @override
  bool chatOnline(String id) => online;
  @override
  bool chatTrusted(String id) => trusted;
  @override
  Object chatConnectionGeneration(String id) => generation;
  @override
  Stream<ChatEvent> get chatEvents => events.stream;
  @override
  Stream<void> get chatConnectionChanges => const Stream.empty();
  @override
  Future<Map<String, dynamic>> chatRequest(
    String id,
    String op,
    Map<String, dynamic> body,
  ) async {
    calls.add((op, body));
    if (op == 'chat.snapshot') {
      return {
        'version': 1,
        'chat': historySummary ?? fixture['summaries'][2],
        'status': 'idle',
        'cursor': null,
        'messages': [
          {
            'id': 'older',
            'role': 'assistant',
            'text': 'Earlier response',
            'truncated': false,
          },
        ],
      };
    }
    if (op == 'chat.view') {
      return pending?.future ?? {'version': 1, 'accepted': true};
    }
    if (op == 'chat.list.subscribe') {
      return pending?.future ?? {...body, 'revision': 0};
    }
    return {'version': 1, 'unsubscribed': true};
  }

  void emit(
    Map<String, dynamic> target,
    int revision, {
    String connector = 'connector',
    Object? from,
    List<dynamic>? changes,
    bool reset = false,
  }) {
    events.add(
      ChatEvent(
        connectorId: connector,
        generation: from ?? generation,
        operation: 'chat.list.updated',
        requestId: target['subscriptionId'] as String,
        body: {
          ...target,
          'revision': revision,
          'reset': reset,
          'changes':
              changes ??
              [
                {'projectId': project.id, 'chat': fixture['summaries'][2]},
              ],
        },
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChatViewModel conversation(Repository repo) {
  final model = ChatViewModel(repo, 'connector')
    ..project = project
    ..page = ChatPage.conversation;
  model.conversation
    ..chat = RemoteChat.parse(fixture['summaries'][2] as Map<String, dynamic>)
    ..status = 'idle'
    ..messages = [
      const ChatMessage('reply', 'assistant', 'Completed response', false),
    ];
  return model;
}

void main() {
  testWidgets(
    'an earlier-history page cannot advance the viewable completion watermark',
    (tester) async {
      final repo = Repository()
        ..historySummary = {
          ...fixture['summaries'][2] as Map<String, dynamic>,
          'activity': {'status': 'idle', 'idleAt': 500, 'outcome': 'succeeded'},
        };
      final model = conversation(repo);
      model.conversation.messageCursor = 'older-page';
      await model.conversation.olderMessages();
      expect(model.conversation.chat!.activity!.idleAt, 300);
      expect(repo.calls.where((c) => c.$1 == 'chat.view'), isEmpty);
      model.dispose();
      await repo.events.close();
    },
  );

  testWidgets(
    'scrolling earlier history does not acknowledge a new completion',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final repo = Repository();
      final model = conversation(repo);
      model.conversation.chat = RemoteChat(
        'unread',
        'Long response',
        DateTime.fromMillisecondsSinceEpoch(300),
      );
      model.conversation.messages = [
        ChatMessage('reply', 'assistant', 'Long reply. ' * 500, false),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: ConversationView(model: model.conversation)),
        ),
      );
      await tester.pump();
      final controller = tester
          .widget<ListView>(find.byType(ListView).first)
          .controller!;
      controller.jumpTo(400);
      model.conversation.chat = RemoteChat.parse(
        fixture['summaries'][2] as Map<String, dynamic>,
      );
      model.conversation.notifyExternalChange();
      await tester.pump();
      await tester.pump();
      expect(repo.calls.where((c) => c.$1 == 'chat.view'), isEmpty);
      controller.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(repo.calls.where((c) => c.$1 == 'chat.view'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await repo.events.close();
    },
  );

  testWidgets(
    'list updates overtaking subscribe acknowledgment are not rolled back',
    (tester) async {
      final repo = Repository()..pending = Completer<Map<String, dynamic>>();
      final updates = <RemoteChat>[];
      final stream = ChatListStream(
        repo,
        'connector',
        (_, chat) => updates.add(chat),
        () {},
      );
      stream.start([project.id]);
      final target = repo.calls.first.$2;
      repo.emit(target, 1);
      repo.pending!.complete({...target, 'revision': 0});
      await tester.pump();
      repo.emit(target, 1);
      repo.emit(target, 2);
      expect(updates, hasLength(2));
      repo.generation = Object();
      repo.emit(target, 3);
      expect(updates, hasLength(2));
      stream.dispose();
      await repo.events.close();
    },
  );

  test('shared summaries distinguish working, unread success, read, stopped, failed and legacy', () {
    final chats = (fixture['summaries'] as List)
        .map((v) => RemoteChat.parse(v as Map<String, dynamic>))
        .toList();
    expect(chats.map((c) => c.activity?.unread ?? false), fixture['unread']);
    expect(chats.map((c) => c.activity?.working ?? false), fixture['working']);
    for (final invalid in fixture['invalidActivity'] as List) {
      expect(
        () => ChatActivity.parse(invalid as Map<String, dynamic>),
        throwsFormatException,
      );
    }
  });

  testWidgets(
    'view acknowledgment cannot clear a newer completion, and is not retried automatically',
    (tester) async {
      final repo = Repository()..pending = Completer<Map<String, dynamic>>();
      final model = conversation(repo);
      await model.conversation.markLatestViewed(
        renderedCompletion: ('unread', 100),
      );
      expect(
        repo.calls,
        isEmpty,
        reason: 'A completion must have been rendered before acknowledging it',
      );
      final reading = model.conversation.markLatestViewed(
        renderedCompletion: ('unread', 300),
      );
      expect(repo.calls.single.$2['idleAt'], 300);
      expect({'version': 1, ...repo.calls.single.$2}, fixture['view']);
      model.conversation.chat = RemoteChat(
        'unread',
        'New reply',
        DateTime.fromMillisecondsSinceEpoch(500),
        activity: const ChatActivity('idle', idleAt: 500, outcome: 'succeeded'),
      );
      repo.pending!.complete({'version': 1, 'accepted': true});
      await reading;
      expect(model.conversation.chat!.activity!.viewedAt, 300);
      expect(model.conversation.chat!.activity!.unread, isTrue);
      repo.pending = Completer<Map<String, dynamic>>();
      final next = model.conversation.markLatestViewed(
        renderedCompletion: ('unread', 500),
      );
      repo.pending!.completeError(ChatFailure.uncertain);
      await next;
      await model.conversation.markLatestViewed(
        renderedCompletion: ('unread', 500),
      );
      model.conversation.chat = RemoteChat.parse(
        fixture['summaries'][2] as Map<String, dynamic>,
      );
      await model.conversation.markLatestViewed(
        renderedCompletion: ('unread', 300),
      );
      expect(repo.calls.where((c) => c.$1 == 'chat.view'), hasLength(2));
      model.dispose();
      await repo.events.close();
    },
  );

  testWidgets(
    'covered, offline and background conversations never acknowledge a completion',
    (tester) async {
      final repo = Repository();
      final model = conversation(repo);
      model.conversation.setCovered(true);
      await model.conversation.markLatestViewed(
        renderedCompletion: ('unread', 300),
      );
      model.setActive(false);
      await model.conversation.markLatestViewed(
        renderedCompletion: ('unread', 300),
      );
      expect(repo.calls.where((c) => c.$1 == 'chat.view'), isEmpty);
      model.dispose();
      await repo.events.close();
    },
  );

  testWidgets('only a rendered foreground latest response is marked viewed', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final repo = Repository();
    final model = conversation(repo);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: ConversationView(model: model.conversation)),
      ),
    );
    await tester.pump();
    expect(repo.calls.where((c) => c.$1 == 'chat.view'), hasLength(1));
    expect(model.conversation.chat!.activity!.unread, isFalse);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    await repo.events.close();
  });

  testWidgets(
    'list events validate scopes, revision gaps, generations and foreground leases',
    (tester) async {
      final repo = Repository();
      final changes = <RemoteChat>[];
      var reconciles = 0;
      final stream = ChatListStream(
        repo,
        'connector',
        (_, chat) => changes.add(chat),
        () => reconciles++,
      );
      stream.start([project.id]);
      await tester.pump();
      final target = repo.calls.first.$2;
      expect(reconciles, 1);
      repo.emit(target, 1);
      repo.emit(target, 1);
      repo.emit(target, 2, connector: 'foreign');
      repo.emit(target, 2, from: Object());
      expect(changes, hasLength(1));
      repo.emit(target, 3);
      expect(
        reconciles,
        2,
        reason: 'A missed event requires an authoritative list',
      );
      repo.emit(
        target,
        4,
        changes: [
          {'projectId': 'foreign', 'chat': fixture['summaries'][0]},
        ],
      );
      expect(changes, hasLength(2));
      stream.dispose();
      await tester.pump(const Duration(seconds: 60));
      expect(
        repo.calls.where((c) => c.$1 == 'chat.list.subscribe'),
        hasLength(1),
      );
      await repo.events.close();
    },
  );

  testWidgets(
    'working indicators stop animating offline and with reduced motion in both themes',
    (tester) async {
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        for (final online in [true, false]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: ChatRowActivity(
                  activity: const ChatActivity('busy'),
                  online: online,
                ),
              ),
            ),
          );
          expect(
            find.byType(CircularProgressIndicator),
            online ? findsOneWidget : findsNothing,
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const MediaQuery(
              data: MediaQueryData(disableAnimations: true),
              child: Scaffold(
                body: ChatRowActivity(
                  activity: ChatActivity('busy'),
                  online: true,
                ),
              ),
            ),
          ),
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(
              body: ChatRowActivity(
                activity: ChatActivity(
                  'idle',
                  idleAt: 300,
                  outcome: 'succeeded',
                ),
                online: true,
              ),
            ),
          ),
        );
        expect(find.byTooltip('Finished · Unread'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
