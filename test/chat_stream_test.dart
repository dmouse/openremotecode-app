import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/data/chat_stream.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';

final _fixture =
    jsonDecode(
          File('../packages/protocol/test/fixtures/activity-v1.json')
              .readAsStringSync(),
        )['stream']
        as Map<String, dynamic>;
const _target = {
  'projectId': '11111111-1111-4111-8111-111111111111',
  'sessionId': 'session',
  'includeActivities': true,
};

class _Repository implements ChatRepository {
  final events = StreamController<ChatEvent>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];
  Object generation = Object();
  Completer<Map<String, dynamic>>? pending;
  int revision = 0;
  bool online = true;
  @override
  Stream<ChatEvent> get chatEvents => events.stream;
  @override
  bool chatOnline(String id) => online;
  @override
  bool chatTrusted(String id) => true;
  @override
  bool chatSupports(String id, String operation) => true;
  @override
  Object chatConnectionGeneration(String id) => generation;
  @override
  Future<Map<String, dynamic>> chatRequest(
    String id,
    String operation,
    Map<String, dynamic> body,
  ) async {
    calls.add((operation, body));
    if (operation == 'chat.stream.unsubscribe') {
      return {'version': 1, 'unsubscribed': true};
    }
    return pending?.future ?? Future.value(update(body, revision));
  }

  Map<String, dynamic> update(Map<String, dynamic> target, int revision) => {
    ..._fixture,
    'subscriptionId': target['subscriptionId'],
    'revision': revision,
  };
  void emit(
    Map<String, dynamic> target,
    int revision, {
    Object? from,
    String connector = 'connector',
  }) => events.add(
    ChatEvent(
      connectorId: connector,
      generation: from ?? generation,
      operation: 'chat.stream.updated',
      requestId: target['subscriptionId'] as String,
      body: update(target, revision),
    ),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository method');
}

void main() {
  testWidgets('a renewal baseline cannot erase an overtaken deletion reset', (
    tester,
  ) async {
    final repo = _Repository();
    final resets = <bool>[];
    final stream = ChatStream(
      repo,
      'connector',
      (_, reset) => resets.add(reset),
      () {},
    );
    await stream.start(_target);
    final target = repo.calls.first.$2;
    repo.pending = Completer<Map<String, dynamic>>();
    await tester.pump(const Duration(seconds: 25));
    repo.pending!.complete({...repo.update(target, 2), 'resetRevision': 1});
    await tester.pump();
    expect(resets, [false, true]);
    repo.emit(target, 1);
    expect(resets, [false, true]);
    stream.dispose();
    await repo.events.close();
  });
  testWidgets(
    'stream reconciles pre-ack events, duplicates, renewal and lifecycle without snapshot polling',
    (tester) async {
      final repo = _Repository()..pending = Completer<Map<String, dynamic>>();
      final snapshots = <Map<String, dynamic>>[];
      final stream = ChatStream(
        repo,
        'connector',
        (snapshot, _) => snapshots.add(snapshot),
        () {},
      );
      stream.start(_target);
      final target = repo.calls.single.$2;
      repo.emit(target, 1);
      expect(snapshots, isEmpty);
      repo.pending!.complete(repo.update(target, 0));
      repo.pending = null;
      await tester.pump();
      expect(snapshots.length, 2);
      repo.emit(target, 1);
      repo.emit(target, 2, connector: 'foreign');
      repo.emit(target, 2, from: Object());
      expect(snapshots.length, 2);
      repo.emit(target, 3);
      repo.emit(target, 2);
      expect(snapshots.length, 4);
      repo.revision = 4;
      await tester.pump(const Duration(seconds: 25));
      expect(
        repo.calls.where((call) => call.$1 == 'chat.stream.subscribe').length,
        2,
      );
      expect(snapshots.length, 5);
      stream.stop();
      repo.emit(target, 5);
      await tester.pump(const Duration(seconds: 90));
      expect(snapshots.length, 5);
      expect(repo.calls.last.$1, 'chat.stream.unsubscribe');
      stream.dispose();
      await repo.events.close();
    },
  );
  testWidgets(
    'revision gaps, peer replacement and explicit closure stop the old stream',
    (tester) async {
      final repo = _Repository();
      final stream = ChatStream(repo, 'connector', (_, _) {}, () {});
      stream.start(_target);
      await tester.pump();
      final first = repo.calls.first.$2;
      repo.emit(first, 2);
      await tester.pump(const Duration(milliseconds: 501));
      expect(stream.active, isFalse);
      stream.start(_target);
      await tester.pump();
      expect(stream.live, isTrue);
      repo.generation = Object();
      stream.connectionChanged();
      expect(stream.active, isFalse);
      stream.start(_target);
      await tester.pump();
      final target = repo.calls
          .lastWhere((call) => call.$1 == 'chat.stream.subscribe')
          .$2;
      repo.events.add(
        ChatEvent(
          connectorId: 'connector',
          generation: repo.generation,
          operation: 'chat.stream.closed',
          requestId: target['subscriptionId'] as String,
          body: {...target, 'version': 1},
        ),
      );
      expect(stream.active, isFalse);
      stream.dispose();
      await repo.events.close();
    },
  );
}
