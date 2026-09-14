import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/data/relay_crypto.dart';
import 'package:openremotecode/features/chat/domain/mcp_models.dart';
import 'package:openremotecode/features/chat/mcp_view_model.dart';

import 'support/mcp_fakes.dart';

void main() {
  testWidgets(
    'trust loss clears a populated snapshot and cannot be reversed by a queued event',
    (tester) async {
      final repo = McpRepositoryFake();
      final model = _model(repo)..setActive(true);
      await tester.pump();
      final id = repo.subscriptionId;
      final late = repo.update(revision: 100);
      expect(model.snapshot?.servers, isNotEmpty);
      repo.trusted = false;
      repo.changes.add(null);
      repo.emit(body: late, id: id);
      expect(model.snapshot, isNull);
      expect(model.live, isFalse);
      expect(model.phase, McpPhase.untrusted);
      model.dispose();
    },
  );

  testWidgets(
    'listen first; event wins over older subscribe and duplicate revisions',
    (tester) async {
      final repo = McpRepositoryFake()..eventBeforeResponse = true;
      final model = _model(repo);
      expect(repo.calls, isEmpty);
      model.setActive(true);
      expect(model.snapshot?.revision, 2);
      await tester.pump();
      expect(model.snapshot?.revision, 2);
      expect(model.live, isTrue);
      final original = model.snapshot;
      for (final revision in [0, 1, 2]) {
        repo.emit(
          body: {
            ...repo.update(revision: revision),
            'servers': [],
          },
        );
        expect(model.snapshot, same(original));
      }
      repo.emit(body: {...repo.update(revision: 3), 'servers': []});
      expect(model.snapshot?.servers, isEmpty);
      expect(repo.calls.single.$1, 'project.mcp.subscribe');
      expect(repo.calls.single.$2.keys.toSet(), {
        'version',
        'projectId',
        'subscriptionId',
      });
      model.dispose();
    },
  );

  testWidgets(
    'same-ID 30-second renewals refresh change-only status; freshness expires at 45',
    (tester) async {
      final repo = McpRepositoryFake();
      final model = _model(repo)..setActive(true);
      await tester.pump();
      final id = repo.subscriptionId;
      await tester.pump(const Duration(seconds: 30));
      expect(repo.subscriptions.length, 2);
      expect(repo.subscriptionId, id);
      expect(model.snapshot?.revision, 2);
      expect(model.live, isTrue);
      repo.pending = Completer<Map<String, dynamic>>();
      await tester.pump(const Duration(seconds: 30));
      expect(repo.subscriptions.length, 3);
      await tester.pump(const Duration(seconds: 14));
      expect(model.live, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(model.live, isFalse);
      expect(model.phase, McpPhase.unavailable);
      repo.pending!.complete(repo.update(revision: 3));
      await tester.pump();
      expect(model.live, isTrue);
      model.dispose();
    },
  );

  testWidgets(
    'failed renewal removes live state even if updates continue, later renewal recovers',
    (tester) async {
      final repo = McpRepositoryFake();
      final model = _model(repo)..setActive(true);
      await tester.pump();
      repo.failure = ChatFailure.unavailable;
      final id = repo.subscriptionId;
      await tester.pump(const Duration(seconds: 30));
      expect(model.live, isFalse);
      expect(model.snapshot?.servers, isNotEmpty);
      repo.emit(body: repo.update(revision: 10));
      expect(model.live, isFalse);
      repo.failure = null;
      await tester.pump(const Duration(seconds: 30));
      expect(repo.subscriptionId, isNot(id));
      expect(model.snapshot?.revision, 1);
      expect(model.live, isTrue);
      model.dispose();
    },
  );

  testWidgets(
    'expired revision-zero lifetime never revives old connected revision ten',
    (tester) async {
      final repo = McpRepositoryFake()..initialRevision = 0;
      final model = _model(repo)..setActive(true);
      await tester.pump();
      final id = repo.subscriptionId;
      final generation = repo.chatConnectionGeneration('connector');
      expect(model.snapshot?.revision, 0);
      await tester.pump(const Duration(seconds: 25));
      repo.emit(body: repo.update(revision: 10));
      final renewal = Completer<Map<String, dynamic>>();
      repo.pending = renewal;
      await tester.pump(const Duration(seconds: 5));
      expect(repo.subscriptions.length, 2);
      expect(repo.subscriptionId, id);
      // No acknowledgement for more than a full lease, on the same connection.
      await tester.pump(const Duration(seconds: 35));
      expect(model.live, isFalse);
      expect(model.snapshot?.revision, 10);
      expect(model.snapshot?.servers.first.status, McpStatus.connected);
      expect(repo.calls.last.$1, 'project.mcp.unsubscribe');
      repo.revisions.clear();
      repo.data['servers'] = [
        {'name': 'context7', 'status': 'disabled'},
      ];
      renewal.complete(repo.update(id: id, revision: 0));
      repo.pending = null;
      await tester.pump();
      // Presence notifications and retired events cannot bypass retry backoff.
      repo.changes.add(null);
      repo.emit(
        body: repo.update(id: id, revision: 11),
        id: id,
      );
      await tester.pump(const Duration(seconds: 24));
      expect(repo.subscriptions.length, 2);
      expect(model.live, isFalse);
      expect(model.snapshot?.revision, 10);
      await tester.pump(const Duration(seconds: 1));
      expect(repo.subscriptionId, isNot(id));
      expect(model.snapshot?.revision, 0);
      expect(model.snapshot?.servers.single.status, McpStatus.disabled);
      expect(model.live, isTrue);
      final newId = repo.subscriptionId;
      await tester.pump(const Duration(seconds: 30));
      expect(repo.subscriptionId, newId);
      expect(model.snapshot?.revision, 1);
      expect(model.snapshot?.servers.single.status, McpStatus.disabled);
      expect(repo.chatConnectionGeneration('connector'), generation);
      model.dispose();
    },
  );

  for (final trigger in ['renewal', 'event']) {
    testWidgets(
      'elapsed lease check precedes overdue $trigger callback on an unchanged connection',
      (tester) async {
        var now = DateTime.utc(2026);
        final repo = McpRepositoryFake()..initialRevision = 0;
        final model = _model(repo, now: () => now)..setActive(true);
        await tester.pump();
        final id = repo.subscriptionId;
        repo.emit(body: repo.update(revision: 10));
        now = now.add(const Duration(seconds: 65));
        expect(model.live, isFalse);
        if (trigger == 'event') {
          repo.emit(body: repo.update(revision: 11));
        } else {
          await tester.pump(const Duration(seconds: 30));
        }
        expect(repo.subscriptions.length, 1);
        expect(repo.calls.last.$1, 'project.mcp.unsubscribe');
        expect(model.snapshot?.revision, 10);
        repo.data['servers'] = [
          {'name': 'context7', 'status': 'disabled'},
        ];
        await tester.pump(const Duration(seconds: 30));
        expect(repo.subscriptionId, isNot(id));
        expect(model.snapshot?.revision, 0);
        expect(model.snapshot?.servers.single.status, McpStatus.disabled);
        model.dispose();
      },
    );
  }

  testWidgets(
    'rejected reset revision retires the ID and retries at most once per 30 seconds',
    (tester) async {
      final repo = McpRepositoryFake()..initialRevision = 0;
      final model = _model(repo)..setActive(true);
      await tester.pump();
      final first = repo.subscriptionId;
      repo.emit(body: repo.update(revision: 10));
      repo.revisions.clear();
      repo.data['servers'] = [
        {'name': 'context7', 'status': 'disabled'},
      ];
      await tester.pump(const Duration(seconds: 30));
      expect(model.live, isFalse);
      repo.failure = ChatFailure.unavailable;
      for (var i = 0; i < 3; i++) {
        final count = repo.subscriptions.length;
        repo.changes.add(null);
        await tester.pump(const Duration(seconds: 29));
        expect(repo.subscriptions.length, count);
        await tester.pump(const Duration(seconds: 1));
        expect(repo.subscriptions.length, count + 1);
        expect(repo.subscriptionId, isNot(first));
        expect(model.live, isFalse);
      }
      expect(
        repo.subscriptions.skip(2).map((c) => c.$2['subscriptionId']).toSet(),
        hasLength(3),
      );
      model.setActive(false);
      final count = repo.subscriptions.length;
      await tester.pump(const Duration(seconds: 90));
      expect(repo.subscriptions.length, count);
      model.dispose();
    },
  );

  testWidgets(
    'offline, reconnect generation and resume use new IDs and allow revision reset',
    (tester) async {
      final repo = McpRepositoryFake();
      final model = _model(repo)..setActive(true);
      await tester.pump();
      final first = repo.subscriptionId;
      repo.emit(body: repo.update(revision: 20));
      repo.online = false;
      repo.generation++;
      repo.changes.add(null);
      expect(model.live, isFalse);
      expect(model.phase, McpPhase.offline);
      final calls = repo.calls.length;
      await tester.pump(const Duration(seconds: 90));
      expect(repo.calls.length, calls);
      repo.online = true;
      repo.changes.add(null);
      await tester.pump();
      final second = repo.subscriptionId;
      expect(second, isNot(first));
      expect(model.snapshot?.revision, 1);
      expect(model.live, isTrue);
      repo.generation++;
      repo.changes.add(null);
      await tester.pump();
      expect(repo.subscriptionId, isNot(second));
      final third = repo.subscriptionId;
      model.setActive(false);
      expect(model.phase, McpPhase.paused);
      expect(repo.calls.last.$1, 'project.mcp.unsubscribe');
      expect(repo.calls.last.$2['subscriptionId'], third);
      await tester.pump(const Duration(seconds: 90));
      model.setActive(true);
      await tester.pump();
      expect(repo.subscriptionId, isNot(third));
      expect(model.live, isTrue);
      model.dispose();
    },
  );

  for (final capability in McpSnapshot.capabilities) {
    testWidgets('gate missing $capability before any request', (tester) async {
      final repo = McpRepositoryFake()..capabilities.remove(capability);
      final model = _model(repo)..setActive(true);
      await tester.pump();
      expect(model.phase, McpPhase.unsupported);
      expect(repo.calls, isEmpty);
      model.dispose();
    });
  }

  testWidgets(
    'wrong connector, project, subscription or generation never replaces data',
    (tester) async {
      final repo = McpRepositoryFake();
      final model = _model(repo)..setActive(true);
      await tester.pump();
      final original = model.snapshot;
      final update = {...repo.update(revision: 100), 'servers': []};
      repo.emit(body: update, connector: 'another-connector');
      repo.emit(body: update, connectionGeneration: -1);
      repo.emit(body: update, id: requestId());
      repo.emit(body: {...update, 'projectId': requestId()});
      repo.emit(body: {...update, 'subscriptionId': requestId()});
      expect(model.snapshot, same(original));
      expect(model.live, isTrue);
      model.dispose();
    },
  );

  for (final transition in [
    'close',
    'project',
    'background',
    'trust',
    'reconnect',
  ]) {
    testWidgets(
      'late subscribe/event after $transition cannot restore old data; cleanup is bounded',
      (tester) async {
        final repo = McpRepositoryFake()
          ..pending = Completer<Map<String, dynamic>>();
        final model = _model(repo)..setActive(true);
        final id = repo.subscriptionId;
        final late = repo.update(revision: 99);
        final pending = repo.pending!;
        repo.pending = null;
        switch (transition) {
          case 'close':
            model.dispose();
          case 'project':
            repo.projectId = requestId();
            model.setProject(repo.projectId);
          case 'background':
            model.setActive(false);
          case 'trust':
            repo.trusted = false;
            repo.changes.add(null);
          case 'reconnect':
            repo.generation++;
            repo.changes.add(null);
        }
        repo.emit(body: late, id: id);
        pending.complete(late);
        await tester.pump();
        expect(model.snapshot?.revision, isNot(99));
        if (transition == 'trust' || transition == 'close') {
          expect(model.snapshot, isNull);
        }
        if (transition == 'project' || transition == 'reconnect') {
          expect(model.snapshot?.revision, 1);
          expect(repo.subscriptionId, isNot(id));
        }
        final cleanup = repo.calls.where(
          (c) =>
              c.$1 == 'project.mcp.unsubscribe' && c.$2['subscriptionId'] == id,
        );
        expect(
          cleanup.length,
          transition == 'trust' || transition == 'reconnect' ? 0 : 2,
        );
        model.dispose();
      },
    );
  }

  testWidgets(
    'malformed updates fail closed and unavailable is not empty ready',
    (tester) async {
      final repo = McpRepositoryFake();
      final model = _model(repo)..setActive(true);
      await tester.pump();
      repo.emit(body: {...repo.update(revision: 2), 'extra': 'private'});
      expect(model.live, isFalse);
      repo.data = {...repo.data, 'state': 'unavailable', 'servers': []};
      await tester.pump(const Duration(seconds: 30));
      expect(model.snapshot?.available, isFalse);
      expect(model.snapshot?.servers, isEmpty);
      expect(model.live, isFalse);
      model.dispose();
    },
  );
}

McpViewModel _model(McpRepositoryFake repo, {DateTime Function()? now}) {
  final model = McpViewModel(
    repo,
    'connector',
    mcpProject,
    now: now ?? TestWidgetsFlutterBinding.instance.clock.now,
  );
  addTearDown(() async {
    model.dispose();
    await repo.dispose();
  });
  return model;
}
