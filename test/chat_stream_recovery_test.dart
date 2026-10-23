import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/settings/settings_view_model.dart';

import 'support/memory_settings_repository.dart';

const _projectId = '11111111-1111-4111-8111-111111111111';
const _summary = {'id': 'session', 'title': 'Chat', 'updatedAt': 100};

final class _Repository implements ChatRepository {
  final events = StreamController<ChatEvent>.broadcast(sync: true);
  final changes = StreamController<void>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];
  final peer = Object();
  final revisions = <String, int>{};
  final messages = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? renewal;
  ChatFailure? snapshotFailure;
  bool online = true, trusted = true;

  Map<String, dynamic> get snapshot => {
    'version': 1,
    'chat': _summary,
    'status': 'idle',
    'messages': [...messages],
    'cursor': null,
  };

  List<Map<String, dynamic>> get subscriptions => calls
      .where((call) => call.$1 == 'chat.stream.subscribe')
      .map((call) => call.$2)
      .toList();

  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async {
    calls.add((operation, {...body}));
    switch (operation) {
      case 'project.list':
        return {
          'version': 1,
          'projects': [
            {'id': _projectId, 'name': 'Project', 'path': '/work/project'},
          ],
          'pathEntry': true,
        };
      case 'chat.list':
        return {
          'version': 1,
          'chats': [_summary],
          'cursor': null,
        };
      case 'chat.snapshot':
        if (snapshotFailure case final failure?) throw failure;
        return snapshot;
      case 'chat.stream.subscribe':
        final id = body['subscriptionId'] as String;
        if (revisions.containsKey(id) && renewal != null) {
          return renewal!.future;
        }
        final revision = (revisions[id] ?? -1) + 1;
        revisions[id] = revision;
        return update(body, revision);
      case 'chat.stream.unsubscribe':
        revisions.remove(body['subscriptionId']);
        return {'version': 1, 'unsubscribed': true};
      case 'chat.prompt':
        messages.add({
          'id': 'message-${messages.length}',
          'role': 'user',
          'text': body['text'],
          'truncated': false,
        });
        // Deliberately drop the event: an accepted prompt still needs reconciliation.
        return {'version': 1, 'accepted': true};
      default:
        throw StateError('Unexpected operation: $operation');
    }
  }

  Map<String, dynamic> update(Map<String, dynamic> target, int revision) => {
    'version': 1,
    'projectId': _projectId,
    'sessionId': 'session',
    'subscriptionId': target['subscriptionId'],
    'revision': revision,
    'reset': false,
    'snapshot': snapshot,
  };

  void emit(int revision) {
    final target = subscriptions.last;
    revisions[target['subscriptionId'] as String] = revision;
    events.add(
      ChatEvent(
        connectorId: 'connector',
        generation: peer,
        operation: 'chat.stream.updated',
        requestId: target['subscriptionId'] as String,
        body: update(target, revision),
      ),
    );
  }

  @override
  bool chatOnline(String connectorId) => online;
  @override
  bool chatTrusted(String connectorId) => trusted;
  @override
  Object chatConnectionGeneration(String connectorId) => peer;
  @override
  Stream<void> get chatConnectionChanges => changes.stream;
  @override
  Stream<ChatEvent> get chatEvents => events.stream;
  @override
  bool chatSupports(String connectorId, String operation) => [
    'chat.prompt',
    'chat.stream.subscribe',
    'chat.stream.updated',
  ].contains(operation);
  @override
  Future<Set<String>> pinnedChatIds(
    String connectorId,
    String projectPath,
  ) async => {};
  @override
  Future<Set<String>> setChatPinned(
    String a,
    String b,
    String c,
    bool d,
  ) async => {};
}

Future<ChatViewModel> _open(_Repository repository) async {
  final settings = SettingsViewModel(MemorySettingsRepository());
  final model = ChatViewModel(repository, 'connector', settings: settings);
  addTearDown(() async {
    model.dispose();
    settings.dispose();
    await repository.events.close();
    await repository.changes.close();
  });
  await model.refresh();
  await model.openProject(model.projects.projects.single);
  await model.openChat(model.chatList.chats.single);
  return model;
}

void main() {
  testWidgets(
    'a recreated idle lease recovers in place without leaving the chat',
    (tester) async {
      final repo = _Repository();
      final model = await _open(repo);
      repo.emit(1);
      final original = repo.subscriptions.last['subscriptionId'];
      repo.revisions.clear(); // The connector lost the subscription, not the relay connection.
      repo.messages.add({
        'id': 'external',
        'role': 'assistant',
        'text': 'Arrived while idle',
        'truncated': false,
      });
      await tester.pump(const Duration(seconds: 25));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(model.page, ChatPage.conversation);
      expect(model.conversation.chat?.id, 'session');
      expect(model.conversation.messages.single.text, 'Arrived while idle');
      expect(repo.subscriptions.last['subscriptionId'], isNot(original));
      expect(model.conversation.activityLive, isTrue);
      expect(repo.calls.where((call) => call.$1 == 'chat.prompt'), isEmpty);
      model.setActive(false);
    },
  );

  testWidgets(
    'an accepted send is read back even when a silent stream still looks live',
    (tester) async {
      final repo = _Repository();
      final model = await _open(repo);
      expect(model.conversation.activityLive, isTrue);
      expect(await model.conversation.send('Keep this in history'), isTrue);
      expect(model.conversation.messages.single.text, 'Keep this in history');
      expect(repo.calls.where((call) => call.$1 == 'chat.prompt').length, 1);
      expect(model.page, ChatPage.conversation);
      model.setActive(false);
    },
  );

  testWidgets(
    'a recreated lease at the same revision also recovers with a new subscription ID',
    (tester) async {
      final repo = _Repository();
      final model = await _open(repo);
      final original = repo.subscriptions.last['subscriptionId'];
      repo.revisions.clear(); // Both the old baseline and the recreated lease are revision zero.
      await tester.pump(const Duration(seconds: 25));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(repo.subscriptions.last['subscriptionId'], isNot(original));
      expect(model.conversation.activityLive, isTrue);
      model.setActive(false);
    },
  );

  testWidgets(
    'a hung renewal times out and a late acknowledgement cannot overwrite the recovered chat',
    (tester) async {
      final repo = _Repository();
      final model = await _open(repo);
      final original = repo.subscriptions.last;
      final pending = Completer<Map<String, dynamic>>();
      repo.renewal = pending;
      await tester.pump(const Duration(seconds: 25));
      repo.messages.add({
        'id': 'external',
        'role': 'assistant',
        'text': 'Recovered',
        'truncated': false,
      });
      await tester.pump(const Duration(seconds: 20));
      expect(model.conversation.activityLive, isFalse);
      repo.renewal = null;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(model.conversation.messages.single.text, 'Recovered');
      expect(model.conversation.activityLive, isTrue);
      final recovered = repo.subscriptions.last['subscriptionId'];
      expect(recovered, isNot(original['subscriptionId']));
      pending.complete({
        ...repo.update(original, 999),
        'snapshot': {
          ...repo.snapshot,
          'messages': [
            {
              'id': 'late',
              'role': 'assistant',
              'text': 'Must not replace current state',
              'truncated': false,
            },
          ],
        },
      });
      await tester.pump();
      expect(model.conversation.messages.single.text, 'Recovered');
      expect(repo.subscriptions.last['subscriptionId'], recovered);
      model.setActive(false);
    },
  );

  testWidgets(
    'an event overtaking a renewal response is not mistaken for a lease reset',
    (tester) async {
      final repo = _Repository();
      final model = await _open(repo);
      final target = repo.subscriptions.last;
      final pending = Completer<Map<String, dynamic>>();
      repo.renewal = pending;
      await tester.pump(const Duration(seconds: 25));
      repo.emit(1);
      pending.complete(repo.update(target, 1));
      repo.renewal = null;
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(
        repo.subscriptions.last['subscriptionId'],
        target['subscriptionId'],
      );
      expect(model.conversation.activityLive, isTrue);
      expect(repo.calls.where((call) => call.$1 == 'chat.snapshot').length, 1);
      model.setActive(false);
    },
  );

  testWidgets(
    'explicit stream closure automatically fetches history and restores streaming',
    (tester) async {
      final repo = _Repository();
      final model = await _open(repo);
      final target = repo.subscriptions.last;
      repo.messages.add({
        'id': 'external',
        'role': 'assistant',
        'text': 'After closure',
        'truncated': false,
      });
      repo.events.add(
        ChatEvent(
          connectorId: 'connector',
          generation: repo.peer,
          operation: 'chat.stream.closed',
          requestId: target['subscriptionId'] as String,
          body: {'version': 1, ...target},
        ),
      );
      expect(model.conversation.activityLive, isFalse);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(model.conversation.messages.single.text, 'After closure');
      expect(model.conversation.activityLive, isTrue);
      expect(model.page, ChatPage.conversation);
      model.setActive(false);
    },
  );

  testWidgets(
    'a failed read after an accepted prompt retries reads only and clears its recovery notice',
    (tester) async {
      final repo = _Repository();
      final model = await _open(repo);
      repo.snapshotFailure = ChatFailure.unavailable;
      expect(await model.conversation.send('Send only once'), isTrue);
      expect(model.error, startsWith('Message sent,'));
      expect(model.conversation.messages, isEmpty);
      repo.snapshotFailure = null;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(model.conversation.messages.single.text, 'Send only once');
      expect(repo.calls.where((call) => call.$1 == 'chat.prompt').length, 1);
      expect(model.error, isNull);
      expect(model.conversation.activityLive, isTrue);
      model.setActive(false);
    },
  );

  testWidgets(
    'an idle foreground chat renews for five minutes without polling or duplicate subscriptions',
    (tester) async {
      final repo = _Repository();
      final model = await _open(repo);
      final original = repo.subscriptions.last['subscriptionId'];
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 25));
        expect(model.conversation.activityLive, isTrue);
      }
      expect(repo.subscriptions.length, 13);
      expect(repo.subscriptions.map((body) => body['subscriptionId']).toSet(), {
        original,
      });
      expect(repo.calls.where((call) => call.$1 == 'chat.snapshot').length, 1);
      model.setActive(false);
      final count = repo.calls.length;
      await tester.pump(const Duration(minutes: 2));
      expect(
        repo.calls.length,
        count,
        reason: 'backgrounded chats must not restart their streams',
      );
    },
  );
}
