import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/data/relay_crypto.dart';
import 'package:openremotecode/features/chat/ui/chat_flow_screen.dart';
import 'package:openremotecode/features/chat/ui/chat_details_screen.dart';
import 'package:openremotecode/features/chat/ui/chat_list_view.dart';
import 'package:openremotecode/features/chat/ui/model_banner.dart';
import 'package:openremotecode/features/chat/ui/rename_chat_dialog.dart';
import 'package:openremotecode/features/connections/data/device_identity.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

const _projectId = 'adfcaa47-d299-4d49-9137-fbac353c7cbd';
const _source = 'ses_source';
const _fork = 'ses_fork';

void main() {
  final fixture = jsonDecode(
    File('../packages/protocol/test/fixtures/chat-mutations-v1.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;

  for (final row in (fixture['valid'] as List).cast<Map<String, dynamic>>()) {
    final operation = row['operation'] as String;
    test(
      '$operation sends the shared parsed request and consumes its reply',
      () async {
        final repository = _Actions()
          ..reply = row['response'] as Map<String, dynamic>;
        final model = await _open(repository);
        if (operation == 'chat.rename') {
          expect(
            await model.conversation.renameChat(
              (row['request'] as Map)['title'] as String,
            ),
            isTrue,
          );
        } else {
          await model.conversation.forkChat();
        }
        expect({
          'version': 1,
          ...repository.calls.singleWhere((c) => c.$1 == operation).$2,
        }, row['parsedRequest']);
        final expected = (row['response'] as Map)['chat'] as Map;
        expect(model.conversation.chat?.id, expected['id']);
        expect(model.conversation.chat?.title, expected['title']);
        expect(model.error, isNull);
      },
    );

    test(
      'relay transports shared $operation body and response unchanged',
      () async {
        final crypto = _WireCrypto();
        final relay = _connected(crypto);
        addTearDown(relay.disconnect);
        final sent = Completer<void>();
        final body = Map<String, dynamic>.from(row['parsedRequest'] as Map)
          ..remove('version');
        final result = relay.request(
          operation: operation,
          body: body,
          identity: _own,
          peer: _peer,
          send: (_) => sent.complete(),
        );
        await sent.future;
        expect(crypto.payload['operation'], operation);
        expect(crypto.payload['body'], row['parsedRequest']);
        crypto.response = {
          ...crypto.payload,
          'kind': 'response',
          'body': row['response'],
        };
        await relay.receive(crypto.envelope(), _own, _peer);
        expect(await result, row['response']);
      },
    );
  }

  test(
    'rename trims before validation, accepts 512, rejects empty and 513',
    () async {
      final repository = _Actions();
      final model = await _open(repository);
      final empty =
          ((fixture['invalid'] as List).first as Map)['request'] as Map;
      for (final title in [empty['title'] as String, '', 'x' * 513]) {
        expect(await model.conversation.renameChat(title), isFalse);
        expect(model.error, isNotNull);
        expect(repository.mutations, isEmpty);
      }
      expect(ConversationViewModel.validateChatTitle(null), isNotNull);
      expect(
        ConversationViewModel.validateChatTitle('  ${'x' * 512}\n'),
        isNull,
      );
      expect(await model.conversation.renameChat('  Original chat  '), isTrue);
      expect(repository.mutations, isEmpty);
      expect(await model.conversation.renameChat('  ${'x' * 512}\n'), isTrue);
      expect(repository.mutations.single.$2['title'], 'x' * 512);
      expect(model.conversation.chat?.title, 'x' * 512);
      expect(model.error, isNull);
    },
  );

  for (final outcome in <String, Object>{
    'denied': ChatFailure.denied,
    'uncertain': ChatFailure.uncertain,
    'missing summary': {'version': 1},
    'wrong version': {
      'version': 2,
      'chat': _summary(_source, 'New title', 300),
    },
    'wrong identity': {
      'version': 1,
      'chat': _summary('recent', 'New title', 300),
    },
    'wrong title': {
      'version': 1,
      'chat': _summary(_source, 'Unexpected title', 300),
    },
    'child summary': {
      'version': 1,
      'chat': {..._summary(_source, 'New title', 300), 'parentId': 'parent'},
    },
  }.entries) {
    test('rename ${outcome.key} never installs an unconfirmed title', () async {
      final repository = _Actions();
      if (outcome.value is ChatFailure) {
        repository.failure = outcome.value as ChatFailure;
      } else {
        repository.reply = outcome.value as Map<String, dynamic>;
      }
      final model = await _open(repository);
      final source = model.conversation.chat;
      final messages = model.conversation.messages;
      final ids = model.chatList.chats.map((c) => c.id).toList();
      expect(await model.conversation.renameChat('New title'), isFalse);
      expect(model.conversation.chat, same(source));
      expect(model.conversation.messages, same(messages));
      expect(model.chatList.chats.map((c) => c.id), ids);
      expect(
        model.chatList.chats.singleWhere((c) => c.id == _source).title,
        'Original chat',
      );
      expect(model.error, isNotNull);
      expect(model.conversation.isSending, isFalse);
      expect(model.canRefresh, isTrue);
    });
  }

  test(
    'rename waits for ack and preserves identity, history and sorted pins',
    () async {
      final repository = _Actions();
      final model = await _open(repository);
      final key = model.conversation.composerKey;
      final messages = model.conversation.messages;
      final revision = model.conversation.messageHistoryRevision;
      final pending = Completer<Map<String, dynamic>>();
      repository.pending = pending;
      final renaming = model.conversation.renameChat('  New title  ');
      expect(model.conversation.chat?.title, 'Original chat');
      expect(model.chatList.chats.map((c) => c.id), [
        'pinned',
        'recent',
        _source,
      ]);
      expect(model.mutating, isTrue);
      expect(model.conversation.isSending, isFalse);
      expect(model.conversation.progressLabel, 'Renaming chat');
      expect(model.conversation.canRename, isFalse);
      expect(model.conversation.canFork, isFalse);
      expect(model.canRefresh, isFalse);
      expect(await model.conversation.renameChat('Duplicate'), isFalse);
      await model.conversation.forkChat();
      await model.refresh();
      expect(await model.conversation.send('Do not send'), isFalse);
      expect(repository.mutations.length, 1);
      pending.complete({
        'version': 1,
        'chat': _summary(_source, 'New title', 300),
      });
      expect(await renaming, isTrue);
      expect(model.conversation.chat?.id, _source);
      expect(model.conversation.composerKey, key);
      expect(model.conversation.chat?.title, 'New title');
      expect(model.conversation.messages, same(messages));
      expect(model.conversation.messageHistoryRevision, revision);
      expect(model.chatList.chats.map((c) => c.id), [
        'pinned',
        _source,
        'recent',
      ]);
      expect(model.chatList.chats.map((c) => c.title), [
        'Pinned chat',
        'New title',
        'Recent chat',
      ]);
      expect(model.chatList.isPinned(model.chatList.chats.first), isTrue);
      expect(model.canRefresh, isTrue);
    },
  );

  test(
    'fork clears old history before reading the authoritative destination',
    () async {
      final repository = _Actions()..cursor = 'source-older';
      final model = await _open(repository);
      await model.conversation.olderMessages();
      expect(model.conversation.messages.map((m) => m.id), [
        'source-old',
        'source-message',
      ]);
      model.conversation.earlierMessagesError = 'Old history failure';
      model.conversation.messageHistoryNotice = 'Old history limit';
      final revision = model.conversation.messageHistoryRevision;
      repository.snapshotPending = Completer<Map<String, dynamic>>();
      final forking = model.conversation.forkChat();
      await _flush();
      expect(model.conversation.chat?.id, _fork);
      expect(model.conversation.messages, isEmpty);
      expect(model.conversation.messageCursor, isNull);
      expect(model.conversation.earlierMessagesError, isNull);
      expect(model.conversation.messageHistoryNotice, isNull);
      expect(model.conversation.messageHistoryRevision, greaterThan(revision));
      expect(model.conversation.status, 'unknown');
      expect(model.mutating, isTrue);
      expect(model.conversation.isSending, isFalse);
      expect(model.conversation.progressLabel, 'Forking chat');
      expect(model.canRefresh, isFalse);
      await model.conversation.forkChat();
      await model.conversation.renameChat('Too early');
      expect(await model.conversation.send('Too early'), isFalse);
      expect(repository.mutations.length, 1);
      expect(repository.calls.last.$1, 'chat.snapshot');
      expect(repository.calls.last.$2, {
        'projectId': _projectId,
        'sessionId': _fork,
        'includeSubtasks': true,
        'includeTools': true,
        'includeShell': true,
        'includeTodos': true,
      });
      repository.snapshotPending!.complete({
        'version': 1,
        'chat': _summary(_fork, 'Authoritative fork title', 400),
        'messages': [_message('fork-message', 'Fork snapshot only')],
        'cursor': 'fork-older',
        'status': 'idle',
      });
      await forking;
      expect(model.conversation.chat?.title, 'Authoritative fork title');
      expect(model.conversation.messages.single.text, 'Fork snapshot only');
      expect(model.conversation.messageCursor, 'fork-older');
      expect(model.conversation.canFork, isTrue);
      expect(model.canRefresh, isTrue);
      expect(
        model.chatList.chats.singleWhere((c) => c.id == _source).title,
        'Original chat',
      );
    },
  );

  for (final failure in [
    ChatFailure.denied,
    ChatFailure.expired,
    ChatFailure.unsupported,
    ChatFailure.busy,
    ChatFailure.chatBusy,
    ChatFailure.notFound,
  ]) {
    test('known fork failure $failure leaves the source retryable', () async {
      final repository = _Actions()..failure = failure;
      final model = await _open(repository);
      final source = model.conversation.chat;
      final messages = model.conversation.messages;
      await model.conversation.forkChat();
      expect(model.conversation.chat, same(source));
      expect(model.conversation.messages, same(messages));
      expect(model.conversation.composerKey, 'chat:$_source');
      expect(model.error, failure.message);
      expect(model.conversation.canFork, isTrue);
      expect(model.canRefresh, isTrue);
      repository.failure = null;
      await model.conversation.forkChat();
      expect(model.conversation.chat?.id, _fork);
    });
  }

  final malformed = <String, Map<String, dynamic>>{
    'missing summary': {'version': 1},
    'wrong version': {'version': 2, 'chat': _summary(_fork, 'Fork', 300)},
    'same identity': {'version': 1, 'chat': _summary(_source, 'Fork', 300)},
    'child session': {
      'version': 1,
      'chat': {..._summary(_fork, 'Fork', 300), 'parentId': _source},
    },
    'invalid title': {'version': 1, 'chat': _summary(_fork, 'x' * 513, 300)},
  };
  for (final outcome in <String, Object>{
    'disconnect': ChatFailure.uncertain,
    'unavailable': ChatFailure.unavailable,
    ...malformed,
  }.entries) {
    test(
      'fork ${outcome.key} blocks duplicates through polling, refresh and reconnect',
      () async {
        final repository = _Actions();
        if (outcome.value is ChatFailure) {
          repository.failure = outcome.value as ChatFailure;
        } else {
          repository.reply = outcome.value as Map<String, dynamic>;
        }
        final model = await _open(repository);
        await model.conversation.forkChat();
        expect(model.conversation.chat?.id, _source);
        expect(model.conversation.messages.single.id, 'source-message');
        expect(model.error, contains('Return to Chats'));
        expect(model.conversation.canFork, isFalse);
        expect(model.canRefresh, isTrue);
        repository.failure = null;
        repository.reply = null;
        await model.refresh();
        expect(model.conversation.canFork, isFalse);
        repository.online = false;
        repository.changes.add(null);
        await _flush();
        repository.online = true;
        repository.changes.add(null);
        await _flush();
        expect(model.conversation.canFork, isFalse);
        expect(model.error, contains('Return to Chats'));
        await model.conversation.forkChat();
        expect(repository.mutations.length, 1);
        model.back();
        await _flush();
        expect(model.page, ChatPage.chats);
        expect(repository.calls.last.$1, 'chat.list');
        await model.openChat(
          model.chatList.chats.singleWhere((c) => c.id == _source),
        );
        expect(model.conversation.canFork, isTrue);
        await model.conversation.forkChat();
        expect(repository.mutations.length, 2);
        expect(model.conversation.chat?.id, _fork);
      },
    );
  }

  testWidgets('snapshot polling does not reconcile an uncertain fork', (
    tester,
  ) async {
    final repository = _Actions()..failure = ChatFailure.uncertain;
    final model = await _show(tester, repository);
    await model.conversation.forkChat();
    final reads = repository.calls.where((c) => c.$1 == 'chat.snapshot').length;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(
      repository.calls.where((c) => c.$1 == 'chat.snapshot').length,
      greaterThan(reads),
    );
    expect(model.conversation.canFork, isFalse);
    await model.conversation.forkChat();
    expect(repository.mutations.length, 1);
    await tester.pumpWidget(const SizedBox());
  });

  for (final operation in ['chat.rename', 'chat.fork']) {
    for (final transition in [
      'background',
      'disconnect',
      'navigation',
      'trust',
    ]) {
      test(
        '$operation late ack cannot overwrite state after $transition',
        () async {
          final repository = _Actions();
          final model = await _open(repository);
          final pending = Completer<Map<String, dynamic>>();
          repository.pending = pending;
          final action = operation == 'chat.rename'
              ? model.conversation.renameChat('New title')
              : model.conversation.forkChat();
          final callsWhilePending = repository.calls.length;
          if (transition == 'background') {
            model.setActive(false);
          } else if (transition == 'disconnect') {
            repository.online = false;
            repository.changes.add(null);
            await _flush();
          } else if (transition == 'navigation') {
            model.back();
            await _flush();
            await model.openChat(
              model.chatList.chats.singleWhere((c) => c.id == 'recent'),
            );
          } else {
            repository.trusted = false;
            repository.online = false;
            repository.changes.add(null);
            await _flush();
          }
          expect(await model.conversation.renameChat('Duplicate'), isFalse);
          await model.conversation.forkChat();
          await model.refresh();
          expect(repository.mutations.length, 1);
          expect(repository.calls.length, callsWhilePending);
          pending.complete({
            'version': 1,
            'chat': _summary(
              operation == 'chat.rename' ? _source : _fork,
              'New title',
              300,
            ),
          });
          await action;
          await _flush();
          expect(model.conversation.isSending, isFalse);
          if (transition == 'background' || transition == 'disconnect') {
            expect(model.conversation.chat?.id, _source);
            expect(model.conversation.chat?.title, 'Original chat');
            expect(model.conversation.canRename, isFalse);
            expect(model.conversation.canFork, isFalse);
          } else if (transition == 'navigation') {
            expect(model.conversation.chat?.id, 'recent');
            expect(model.conversation.chat?.title, 'Recent chat');
            expect(model.canRefresh, isTrue);
            expect(repository.calls.skip(callsWhilePending).map((c) => c.$1), [
              'project.list',
              'chat.snapshot',
            ]);
            expect(repository.calls.last.$2['sessionId'], 'recent');
            expect(model.conversation.messages.single.text, 'Original history');
          } else {
            expect(model.trustLost, isTrue);
            expect(model.conversation.chat, isNull);
            expect(model.projects.projects, isEmpty);
            expect(model.chatList.chats, isEmpty);
            expect(model.conversation.messages, isEmpty);
            expect(model.canRefresh, isFalse);
          }
        },
      );
    }
  }

  test(
    'background fork uncertainty survives resume before its request completes',
    () async {
      final repository = _Actions();
      final model = await _open(repository);
      repository.pending = Completer<Map<String, dynamic>>();
      final action = model.conversation.forkChat();
      final callsWhilePending = repository.calls.length;
      model.setActive(false);
      model.setActive(true);
      await _flush();
      expect(model.conversation.canRename, isFalse);
      expect(model.conversation.canFork, isFalse);
      expect(model.canRefresh, isFalse);
      await model.conversation.forkChat();
      expect(repository.mutations.length, 1);
      expect(repository.calls.length, callsWhilePending);
      repository.pending!.completeError(ChatFailure.uncertain);
      await action;
      await _flush();
      expect(repository.calls.skip(callsWhilePending).map((c) => c.$1), [
        'project.list',
        'chat.snapshot',
      ]);
      expect(model.conversation.canFork, isFalse);
      expect(model.canRefresh, isTrue);
      expect(model.error, contains('The fork could not be confirmed'));
    },
  );

  for (final transition in ['background', 'disconnect']) {
    for (final resumeBeforeAck in [false, true]) {
      test(
        'confirmed fork after $transition ${resumeBeforeAck ? 'then resume' : 'before resume'} stays blocked until Chats reconciliation',
        () async {
          final repository = _Actions();
          final model = await _open(repository);
          repository.pending = Completer<Map<String, dynamic>>();
          final action = model.conversation.forkChat();
          final callsWhilePending = repository.calls.length;
          void suspend() {
            if (transition == 'background') {
              model.setActive(false);
            } else {
              repository.online = false;
              repository.changes.add(null);
            }
          }

          void resume() {
            if (transition == 'background') {
              model.setActive(true);
            } else {
              repository.online = true;
              repository.changes.add(null);
            }
          }

          suspend();
          if (resumeBeforeAck) resume();
          await _flush();
          await model.refresh();
          await model.conversation.forkChat();
          expect(repository.calls.length, callsWhilePending);
          repository.pending!.complete({
            'version': 1,
            'chat': _summary(_fork, 'Confirmed fork', 300),
          });
          await action;
          await _flush();
          expect(model.conversation.chat?.id, _source);
          expect(
            model.error,
            startsWith('A fork was created. Return to Chats'),
          );
          expect(model.conversation.canFork, isFalse);
          if (!resumeBeforeAck) resume();
          await _flush();
          expect(model.conversation.chat?.id, _source);
          expect(model.conversation.status, 'idle');
          expect(model.canRefresh, isTrue);
          expect(model.conversation.canRename, isTrue);
          expect(model.conversation.canFork, isFalse);
          await model.refresh();
          expect(
            model.error,
            startsWith('A fork was created. Return to Chats'),
          );
          await model.conversation.forkChat();
          expect(repository.mutations.length, 1);
          model.back();
          await _flush();
          expect(model.page, ChatPage.chats);
          expect(
            model.chatList.chats.singleWhere((c) => c.id == _fork).title,
            'Confirmed fork',
          );
          await model.openChat(
            model.chatList.chats.singleWhere((c) => c.id == _source),
          );
          expect(model.error, isNull);
          expect(model.conversation.canFork, isTrue);
          expect(repository.mutations.length, 1);
        },
      );
    }
  }

  test('failed fork snapshot keeps the confirmed destination and refresh does not refork', () async {
    final repository = _Actions();
    final model = await _open(repository);
    repository.snapshotPending = Completer<Map<String, dynamic>>();
    final action = model.conversation.forkChat();
    await _flush();
    repository.snapshotPending!.completeError(ChatFailure.unavailable);
    await action;
    expect(model.conversation.chat?.id, _fork);
    expect(model.conversation.messages, isEmpty);
    expect(model.conversation.status, 'unknown');
    expect(model.conversation.canFork, isFalse);
    expect(model.canRefresh, isTrue);
    await model.conversation.forkChat();
    repository.snapshotPending = null;
    await model.refresh();
    expect(model.conversation.chat?.id, _fork);
    expect(
      model.conversation.messages.single.text,
      'Authoritative fork history',
    );
    expect(model.error, isNull);
    expect(repository.mutations.length, 1);
  });

  test('a failed Chats list refresh cannot clear fork uncertainty', () async {
    final repository = _Actions()..failure = ChatFailure.uncertain;
    final model = await _open(repository);
    await model.conversation.forkChat();
    repository.listFailure = ChatFailure.unavailable;
    model.back();
    await _flush();
    expect(model.error, ChatFailure.unavailable.message);
    await model.openChat(
      model.chatList.chats.singleWhere((c) => c.id == _source),
    );
    expect(model.conversation.canFork, isFalse);
    await model.conversation.forkChat();
    expect(repository.mutations.length, 1);
    repository.listFailure = null;
    model.back();
    await _flush();
    await model.openChat(
      model.chatList.chats.singleWhere((c) => c.id == _source),
    );
    expect(model.conversation.canFork, isTrue);
  });

  for (final status in ['busy', 'retry', 'unknown', 'idle']) {
    test('$status status gates fork but allows rename', () async {
      final repository = _Actions()..status = status;
      final model = await _open(repository);
      expect(model.conversation.canRename, isTrue);
      expect(model.conversation.canFork, status == 'idle');
      if (status != 'idle') {
        await model.conversation.forkChat();
        expect(repository.mutations, isEmpty);
      }
      await model.conversation.renameChat('Allowed rename');
      expect(repository.mutations.single.$1, 'chat.rename');
    });
  }

  test(
    'an empty OpenCode session can be deleted but cannot be forked',
    () async {
      final repository = _Actions();
      final model = await _open(repository);
      model.conversation.messages = [];
      expect(model.conversation.canFork, isFalse);
      expect(model.conversation.canDeleteCurrentChat, isTrue);
      await model.conversation.forkChat();
      expect(repository.mutations, isEmpty);
    },
  );

  test(
    'unsupported, offline and uncreated draft actions never dispatch',
    () async {
      final repository = _Actions();
      final model = await _open(repository);
      for (final operation in ['chat.rename', 'chat.fork']) {
        repository.unsupported.add(operation);
        expect(
          operation == 'chat.rename'
              ? model.conversation.canRename
              : model.conversation.canFork,
          isFalse,
        );
        if (operation == 'chat.rename') {
          expect(await model.conversation.renameChat('Not supported'), isFalse);
        } else {
          await model.conversation.forkChat();
        }
      }
      repository.unsupported.clear();
      repository.online = false;
      repository.changes.add(null);
      await _flush();
      expect(model.canRefresh, isFalse);
      expect(model.conversation.canRename, isFalse);
      expect(model.conversation.canFork, isFalse);
      expect(await model.conversation.renameChat('Offline'), isFalse);
      await model.conversation.forkChat();
      repository.online = true;
      repository.changes.add(null);
      await _flush();
      model.back();
      await _flush();
      model.startNewChat();
      expect(model.conversation.isDraft, isTrue);
      expect(model.conversation.canRename, isFalse);
      expect(model.conversation.canFork, isFalse);
      expect(model.canRefresh, isTrue);
      expect(await model.conversation.renameChat('Draft'), isFalse);
      await model.conversation.forkChat();
      expect(repository.mutations, isEmpty);
    },
  );

  test(
    'only a pending prompt sets isSending and it blocks chat actions',
    () async {
      final repository = _Actions();
      final model = await _open(repository);
      repository.pending = Completer<Map<String, dynamic>>();
      final sending = model.conversation.send('Prompt');
      expect(model.conversation.isSending, isTrue);
      expect(model.conversation.canRename, isFalse);
      expect(model.conversation.canFork, isFalse);
      expect(model.canRefresh, isFalse);
      await model.conversation.renameChat('No');
      await model.conversation.forkChat();
      repository.pending!.complete({'version': 1, 'accepted': true});
      expect(await sending, isTrue);
      expect(model.conversation.isSending, isFalse);
      expect(repository.mutations.single.$1, 'chat.prompt');
    },
  );

  testWidgets(
    'compact composer is blank and long press selects a mode without sending',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final repository = _Actions();
      final model = await _show(tester, repository, largeText: true);
      final send = find.byKey(const ValueKey('chat-send'));
      final field = tester.widget<TextField>(_composer);
      expect(field.decoration!.labelText, isNull);
      expect(field.decoration!.hintText, isNull);
      expect(find.text('Send'), findsNothing);
      expect(tester.getSize(send), const Size(48, 48));
      expect(
        tester.getRect(send).left,
        greaterThan(tester.getRect(_composer).right),
      );
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      expect(tester.getSemantics(_composer).label, contains('Message'));

      await tester.enterText(_composer, 'Synthetic prompt');
      await tester.longPress(send);
      await tester.pumpAndSettle();
      expect(repository.mutations, isEmpty);
      expect(find.text('Build'), findsOneWidget);
      expect(find.text('Plan'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Plan'));
      await tester.pumpAndSettle();
      expect(model.conversation.promptMode, PromptMode.plan);
      expect(_draft(tester), 'Synthetic prompt');
      expect(tester.getSemantics(send).label, contains('Send · Plan'));
      expect(
        tester
            .getSemantics(send)
            .getSemanticsData()
            .hasAction(SemanticsAction.longPress),
        isTrue,
      );

      repository.pending = Completer<Map<String, dynamic>>();
      await tester.tap(send);
      await tester.pump();
      expect(repository.mutations.single.$2['mode'], 'plan');
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      expect(tester.widget<FilledButton>(send).onLongPress, isNull);
      expect(tester.getSemantics(send).label, contains('Sending'));
      repository.pending!.complete({'version': 1, 'accepted': true});
      await tester.pumpAndSettle();
      expect(_draft(tester), isEmpty);
      expect(model.conversation.promptMode, PromptMode.plan);

      await tester.longPress(send);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Build'));
      await tester.pumpAndSettle();
      expect(model.conversation.promptMode, PromptMode.build);
      expect(repository.mutations, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );

  testWidgets('busy chat turns an empty send button into a Stop that aborts', (
    tester,
  ) async {
    final repository = _Actions()..status = 'busy';
    final model = await _show(tester, repository);
    final send = find.byKey(const ValueKey('chat-send'));
    expect(model.conversation.status, 'busy');
    expect(find.byTooltip('Stop response'), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward), findsNothing);
    expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(send).onLongPress, isNull);
    // The Stop asks before aborting; cancelling leaves the agent running.
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.text('Stop the agent?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repository.calls.map((c) => c.$1), isNot(contains('chat.abort')));
    // Confirming dispatches the abort.
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(find.text('Stop the agent?'), findsOneWidget);
    await tester.tap(find.text('Stop agent'));
    await tester.pumpAndSettle();
    expect(repository.calls.map((c) => c.$1), contains('chat.abort'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'typing while busy returns Send under the kept mode to queue the prompt',
    (tester) async {
      final repository = _Actions()..status = 'busy';
      final model = await _show(tester, repository);
      final send = find.byKey(const ValueKey('chat-send'));
      expect(find.byTooltip('Stop response'), findsOneWidget);
      await tester.enterText(_composer, 'Queued prompt');
      await tester.pump();
      expect(find.byTooltip('Stop response'), findsNothing);
      expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
      // Long press still selects a mode while the agent works, and the send
      // under that kept mode is what gets queued.
      await tester.longPress(send);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plan'));
      await tester.pumpAndSettle();
      expect(model.conversation.promptMode, PromptMode.plan);
      await tester.tap(send);
      await tester.pump();
      expect(repository.calls.map((c) => c.$1), contains('chat.prompt'));
      expect(
        repository.calls.singleWhere((c) => c.$1 == 'chat.prompt').$2['mode'],
        'plan',
      );
      // The accepted send clears the draft, so the button is Stop again.
      await tester.pumpAndSettle();
      expect(_draft(tester), isEmpty);
      expect(find.byTooltip('Stop response'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('retry state shows Stop that clears once text is typed', (
    tester,
  ) async {
    final repository = _Actions()..status = 'retry';
    final model = await _show(tester, repository);
    expect(model.conversation.status, 'retry');
    expect(find.byTooltip('Stop response'), findsOneWidget);
    await tester.enterText(_composer, 'Retry queue');
    await tester.pump();
    expect(find.byTooltip('Stop response'), findsNothing);
    await tester.enterText(_composer, '');
    await tester.pump();
    expect(find.byTooltip('Stop response'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('idle chat keeps a plain send button with no Stop', (
    tester,
  ) async {
    final repository = _Actions();
    final model = await _show(tester, repository);
    final send = find.byKey(const ValueKey('chat-send'));
    expect(model.conversation.status, 'idle');
    expect(find.byTooltip('Stop response'), findsNothing);
    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.enterText(_composer, 'Idle prompt');
    await tester.pump();
    expect(find.byTooltip('Stop response'), findsNothing);
    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mode picker is unavailable on old connectors and stale chats', (
    tester,
  ) async {
    final repository = _Actions()..unsupported.add('chat.prompt.mode');
    final model = await _show(tester, repository);
    final send = find.byKey(const ValueKey('chat-send'));
    await tester.longPress(send);
    await tester.pumpAndSettle();
    expect(find.textContaining('Restart OpenCode'), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Plan')).enabled,
      isFalse,
    );
    expect(model.conversation.promptMode, isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    repository.unsupported.clear();
    repository.changes.add(null);
    await tester.pumpAndSettle();
    await tester.longPress(send);
    await tester.pumpAndSettle();
    model.back();
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Plan')).enabled,
      isFalse,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(model.conversation.promptMode, PromptMode.build);
    expect(repository.mutations, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'mode is captured per prompt and failures never retry or downgrade',
    () async {
      final repository = _Actions();
      final model = await _open(repository);
      model.conversation.selectPromptMode(PromptMode.plan);
      repository.pending = Completer<Map<String, dynamic>>();
      final sending = model.conversation.send('Synthetic prompt');
      model.conversation.selectPromptMode(PromptMode.build);
      expect(model.conversation.promptMode, PromptMode.plan);
      expect(await model.conversation.send('Duplicate'), isFalse);
      repository.pending!.completeError(ChatFailure.uncertain);
      expect(await sending, isFalse);
      expect(model.conversation.promptMode, PromptMode.plan);
      expect(model.conversation.canChangePromptMode, isTrue);
      expect(repository.mutations.single.$2['mode'], 'plan');
      repository.unsupported.add('chat.prompt.mode');
      repository.changes.add(null);
      expect(model.conversation.canSend, isFalse);
      expect(await model.conversation.send('Do not downgrade'), isFalse);
      expect(repository.mutations, hasLength(1));
    },
  );

  test('model list is fetched lazily, never on chat load', () async {
    final repository = _Actions()
      ..models = [
        {
          'providerID': 'anthropic',
          'providerName': 'Anthropic',
          'modelID': 'claude',
          'modelName': 'Claude',
        },
      ];
    final model = await _open(repository);
    expect(repository.calls.where((c) => c.$1 == 'chat.models'), isEmpty);
    await model.conversation.loadAvailableModels();
    expect(repository.calls.where((c) => c.$1 == 'chat.models'), hasLength(1));
    expect(model.conversation.models.availableModels, hasLength(1));
    expect(model.conversation.models.availableModels.single.modelId, 'claude');
    // A second call while already loaded is a no-op unless forced.
    await model.conversation.loadAvailableModels();
    expect(repository.calls.where((c) => c.$1 == 'chat.models'), hasLength(1));
  });

  testWidgets(
    'model button hides while actively writing and fetches only on tap',
    (tester) async {
      final repository = _Actions()
        ..models = [
          {
            'providerID': 'anthropic',
            'providerName': 'Anthropic',
            'modelID': 'claude',
            'modelName': 'Claude',
          },
          {
            'providerID': 'openai',
            'providerName': 'OpenAI',
            'modelID': 'gpt-5',
            'modelName': 'GPT-5',
            // OpenAI's real variant set, not a fixed 3-value enum -- this is
            // exactly the shape chat.models now reports for GPT models.
            'effortLevels': [
              'none',
              'minimal',
              'low',
              'medium',
              'high',
              'xhigh',
            ],
          },
        ];
      await _show(tester, repository);
      final button = _sparkles;
      expect(button, findsOneWidget);

      await tester.tap(_composer);
      await tester.pumpAndSettle();
      expect(
        button,
        findsOneWidget,
        reason: 'empty field stays visible focused',
      );

      await tester.enterText(_composer, 'Writing a prompt');
      await tester.pumpAndSettle();
      expect(button, findsNothing, reason: 'hidden while focused with text');

      await tester.enterText(_composer, '');
      await tester.pumpAndSettle();
      expect(button, findsOneWidget, reason: 'reappears once cleared');

      await tester.enterText(_composer, 'Writing a prompt');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(button, findsOneWidget, reason: 'reappears once unfocused');

      expect(repository.calls.where((c) => c.$1 == 'chat.models'), isEmpty);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        repository.calls.where((c) => c.$1 == 'chat.models'),
        hasLength(1),
      );
      // The banner names OpenCode's own default until a model is chosen, and
      // has no effort axis to offer for it.
      expect(_bannerTitle, findsOneWidget);
      expect(find.text('Default model'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);

      // It comes up over the composer, like the Build/Plan picker: the input
      // and Send are behind the sheet, not beside it.
      final sheet = tester.getRect(find.byType(BottomSheet));
      final input = tester.getRect(_composer);
      final send = tester.getRect(find.byKey(const ValueKey('chat-send')));
      expect(sheet.top, lessThan(input.top));
      expect(sheet.bottom, greaterThanOrEqualTo(send.bottom));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_bannerTitle, findsNothing);
      expect(find.text('Default model'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the banner reaches the model list and keeps effort out of it', (
    tester,
  ) async {
    final repository = _Actions()
      ..models = [
        {
          'providerID': 'anthropic',
          'providerName': 'Anthropic',
          'modelID': 'claude',
          'modelName': 'Claude',
        },
        {
          'providerID': 'openai',
          'providerName': 'OpenAI',
          'modelID': 'gpt-5',
          'modelName': 'GPT-5',
          'effortLevels': ['low', 'medium', 'high'],
        },
      ];
    await _show(tester, repository);
    await tester.tap(_sparkles);
    await tester.pumpAndSettle();
    await tester.tap(_bannerTitle);
    await tester.pumpAndSettle();
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('GPT-5'), findsOneWidget);
    // Levels belong to the banner's slider now, not to every list row.
    expect(find.text('Medium'), findsNothing);

    await tester.tap(find.text('GPT-5'));
    await tester.pumpAndSettle();
    // A model with levels of its own brings the banner back up, so its slider
    // is there to set them without asking for the sparkles again.
    expect(find.byType(ModelBanner), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ModelBanner),
        matching: find.text('GPT-5'),
      ),
      findsOneWidget,
    );

    // A model with no levels has nothing left to set, so choosing it finishes.
    await tester.tap(_bannerTitle);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude'));
    await tester.pumpAndSettle();
    expect(find.byType(ModelBanner), findsNothing);

    // Raised again for that model, the banner is its title alone -- no slider,
    // and no line of explanation where a control would have been.
    await tester.tap(_sparkles);
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNothing);
    expect(
      find.descendant(
        of: find.byType(ModelBanner),
        matching: find.byType(Text),
      ),
      findsOneWidget,
      reason: 'the name is the whole banner',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the effort slider sets, moves and clears the level in force', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final repository = _Actions()
      ..models = [
        {
          'providerID': 'openai',
          'providerName': 'OpenAI',
          'modelID': 'gpt-5',
          'modelName': 'GPT-5',
          'effortLevels': ['low', 'medium', 'high'],
        },
      ];
    final model = await _show(tester, repository);
    await tester.tap(_sparkles);
    await tester.pumpAndSettle();
    await tester.tap(_bannerTitle);
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPT-5'));
    await tester.pumpAndSettle();
    // Picking a model alone chooses no level: the slider rests on Default and
    // no effort travels with the prompt.
    expect(model.conversation.models.selectedEffort, isNull);
    // Levels are named on the slider's value semantics, so the control is not
    // readable by thumb position alone.
    final slider = tester.getSemantics(find.byType(Slider)).getSemanticsData();
    expect(slider.label, contains('Effort'));
    expect(slider.value, 'Default');
    expect(slider.increasedValue, 'Low');

    // Four stops: Default, Low, Medium, High.
    await _tapEffort(tester, 3, 4);
    expect(model.conversation.models.selectedEffort, 'high');
    expect(
      tester.getSemantics(find.byType(Slider)).getSemanticsData().value,
      'High',
    );
    expect(find.text('GPT-5 · High'), findsOneWidget);

    await _tapEffort(tester, 1, 4);
    expect(model.conversation.models.selectedEffort, 'low');
    expect(find.text('GPT-5 · Low'), findsOneWidget);

    await _tapEffort(tester, 0, 4);
    expect(
      model.conversation.models.selectedEffort,
      isNull,
      reason: 'Default clears the level',
    );
    expect(find.text('GPT-5 · Low'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets(
    'model picker search filters the list by model or provider name',
    (tester) async {
      final repository = _Actions()
        ..models = [
          {
            'providerID': 'anthropic',
            'providerName': 'Anthropic',
            'modelID': 'claude',
            'modelName': 'Claude',
          },
          {
            'providerID': 'openai',
            'providerName': 'OpenAI',
            'modelID': 'gpt-5',
            'modelName': 'GPT-5',
          },
        ];
      await _show(tester, repository);
      await tester.tap(_sparkles);
      await tester.pumpAndSettle();
      await tester.tap(_bannerTitle);
      await tester.pumpAndSettle();
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('GPT-5'), findsOneWidget);

      final searchField = find.widgetWithText(TextField, 'Search models');
      expect(searchField, findsOneWidget);
      await tester.enterText(searchField, 'gpt');
      await tester.pumpAndSettle();
      expect(find.text('Claude'), findsNothing);
      expect(find.text('GPT-5'), findsOneWidget);

      await tester.enterText(searchField, 'anthropic');
      await tester.pumpAndSettle();
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('GPT-5'), findsNothing);

      await tester.enterText(searchField, 'nothing matches this');
      await tester.pumpAndSettle();
      expect(find.text('Claude'), findsNothing);
      expect(find.text('GPT-5'), findsNothing);
      expect(
        find.text('No models match "nothing matches this".'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('GPT-5'), findsOneWidget);

      await tester.tap(find.text('Claude'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'chat header shows the selected model and effort as a second line',
    (tester) async {
      final repository = _Actions()
        ..models = [
          {
            'providerID': 'anthropic',
            'providerName': 'Anthropic',
            'modelID': 'claude',
            'modelName': 'Claude',
          },
          {
            'providerID': 'openai',
            'providerName': 'OpenAI',
            'modelID': 'gpt-5',
            'modelName': 'GPT-5',
            'effortLevels': ['low', 'high'],
          },
        ];
      final model = await _show(tester, repository);
      expect(find.text('Original chat'), findsOneWidget);
      expect(find.text('GPT-5'), findsNothing);
      expect(find.text('GPT-5 · High'), findsNothing);

      await tester.tap(_sparkles);
      await tester.pumpAndSettle();
      await tester.tap(_bannerTitle);
      await tester.pumpAndSettle();
      await tester.tap(find.text('GPT-5'));
      await tester.pumpAndSettle();
      // Three stops for two levels: Default, Low, High.
      await _tapEffort(tester, 2, 3);
      expect(model.conversation.models.selectedEffort, 'high');
      expect(find.text('Original chat'), findsOneWidget);
      expect(find.text('GPT-5 · High'), findsOneWidget);

      // A model that offers no levels drops the effort with it.
      await tester.tap(_bannerTitle);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Claude'));
      await tester.pumpAndSettle();
      expect(find.text('Original chat'), findsOneWidget);
      expect(model.conversation.models.selectedEffort, isNull);
      expect(find.text('GPT-5 · High'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    "chat header recovers a previously-opened chat's model from its snapshot",
    (tester) async {
      final repository = _Actions()
        ..snapshotModel = {
          'providerID': 'openai',
          'modelID': 'gpt-5.6-sol',
          'effort': 'high',
        };
      await _show(tester, repository);
      expect(find.text('Original chat'), findsOneWidget);
      // No display name is known yet (the picker was never opened this
      // session), so the raw ids are a correct, if plain, fallback.
      expect(find.text('gpt-5.6-sol · High'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    "a recovered model gains its display name and levels once the list loads",
    (tester) async {
      final repository = _Actions()
        ..snapshotModel = {
          'providerID': 'openai',
          'modelID': 'gpt-5',
          'effort': 'high',
        }
        ..models = [
          {
            'providerID': 'openai',
            'providerName': 'OpenAI',
            'modelID': 'gpt-5',
            'modelName': 'GPT-5',
            'effortLevels': ['low', 'high'],
          },
        ];
      final model = await _show(tester, repository);
      expect(find.text('gpt-5 · High'), findsOneWidget);

      // Opening the banner loads the list, which turns ids recovered from the
      // last reply into the real option -- name, provider and levels.
      await tester.tap(_sparkles);
      await tester.pumpAndSettle();
      expect(find.text('GPT-5 · High'), findsOneWidget);
      expect(model.conversation.models.selectedEffort, 'high');
      expect(find.byType(Slider), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a recovered effort the model does not offer is dropped', (
    tester,
  ) async {
    final repository = _Actions()
      ..snapshotModel = {
        'providerID': 'openai',
        'modelID': 'gpt-5',
        'effort': 'xhigh',
      }
      ..models = [
        {
          'providerID': 'openai',
          'providerName': 'OpenAI',
          'modelID': 'gpt-5',
          'modelName': 'GPT-5',
          'effortLevels': ['low', 'high'],
        },
      ];
    final model = await _show(tester, repository);
    expect(find.text('gpt-5 · Extra high'), findsOneWidget);
    await tester.tap(_sparkles);
    await tester.pumpAndSettle();
    // Nothing names a level its model denies: the slider rests on Default and
    // the prompt carries no effort.
    expect(model.conversation.models.selectedEffort, isNull);
    expect(find.text('GPT-5'), findsNWidgets(2));
    expect(tester.widget<Slider>(find.byType(Slider)).value, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a model selected in one chat does not leak into a different chat',
    (tester) async {
      final repository = _Actions()
        ..models = [
          {
            'providerID': 'openai',
            'providerName': 'OpenAI',
            'modelID': 'gpt-5',
            'modelName': 'GPT-5',
          },
        ];
      final model = await _show(tester, repository);
      await tester.tap(_sparkles);
      await tester.pumpAndSettle();
      await tester.tap(_bannerTitle);
      await tester.pumpAndSettle();
      await tester.tap(find.text('GPT-5'));
      await tester.pumpAndSettle();
      // This model reports no levels, so choosing it finishes there.
      expect(find.text('GPT-5'), findsOneWidget);
      expect(_bannerTitle, findsNothing);

      await model.openChat(
        model.chatList.chats.singleWhere((c) => c.id == 'recent'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Recent chat'), findsOneWidget);
      expect(find.text('GPT-5'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a banner left open over a chat the composer left is inert', (
    tester,
  ) async {
    final repository = _Actions()
      ..models = [
        {
          'providerID': 'openai',
          'providerName': 'OpenAI',
          'modelID': 'gpt-5',
          'modelName': 'GPT-5',
          'effortLevels': ['low', 'high'],
        },
      ];
    final model = await _show(tester, repository);
    await tester.tap(_sparkles);
    await tester.pumpAndSettle();
    await tester.tap(_bannerTitle);
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPT-5'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);

    await model.openChat(
      model.chatList.chats.singleWhere((c) => c.id == 'recent'),
    );
    await tester.pumpAndSettle();
    // The sheet is still up, but it was raised for the chat that was left:
    // nothing on it can reach the model of the one now in the composer.
    expect(_bannerTitle, findsOneWidget);
    expect(tester.widget<InkWell>(_bannerTitle).onTap, isNull);
    expect(find.byType(Slider), findsNothing);
    expect(model.conversation.models.selectedModel, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  final promptFixture = jsonDecode(
    File('../packages/protocol/test/fixtures/chat-prompt-mode-v1.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  for (final request
      in (promptFixture['valid'] as List).cast<Map<String, dynamic>>()) {
    test(
      'prompt mode ${request['mode']} matches the shared contract',
      () async {
        final repository = _Actions();
        final model = await _open(repository);
        final mode = request['mode'];
        if (mode == null) {
          repository.unsupported.add('chat.prompt.mode');
        } else {
          model.conversation.selectPromptMode(
            PromptMode.values.byName(mode as String),
          );
        }
        expect(
          await model.conversation.send(request['text'] as String),
          isTrue,
        );
        expect(
          {'version': 1, ...repository.mutations.single.$2},
          {...request, 'projectId': _projectId, 'sessionId': _source},
        );
      },
    );
  }

  testWidgets(
    'rename dialog prefills, cancels, validates and preserves the draft after ack',
    (tester) async {
      final repository = _Actions();
      final model = await _show(tester, repository);
      await tester.enterText(_composer, 'Unsent source draft');
      await _menu(tester, 'Rename chat');
      expect(find.byType(RenameChatDialog), findsOneWidget);
      expect(
        tester.widget<RenameChatDialog>(find.byType(RenameChatDialog)).model,
        same(model.conversation),
      );
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        'Original chat',
      );
      await tester.enterText(find.byType(TextFormField), 'Cancelled title');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repository.mutations, isEmpty);
      expect(model.conversation.chat?.title, 'Original chat');
      expect(_draft(tester), 'Unsent source draft');
      await _menu(tester, 'Rename chat');
      await tester.enterText(find.byType(TextFormField), ' \t\n ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a chat name.'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'x' * 513);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Use 512 characters or fewer.'), findsOneWidget);
      expect(repository.mutations, isEmpty);
      repository.pending = Completer<Map<String, dynamic>>();
      await tester.enterText(find.byType(TextFormField), '  Renamed source  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(RenameChatDialog), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        '  Renamed source  ',
      );
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
        isFalse,
      );
      expect(tester.widget<FilledButton>(_dialogSave).onPressed, isNull);
      expect(find.text('Saving'), findsOneWidget);
      expect(model.conversation.chat?.title, 'Original chat');
      expect(model.conversation.isSending, isFalse);
      expect(find.text('Sending'), findsNothing);
      expect(_draft(tester), 'Unsent source draft');
      expect(repository.mutations.single.$2['title'], 'Renamed source');
      repository.pending!.complete({
        'version': 1,
        'chat': _summary(_source, 'Renamed source', 300),
      });
      await tester.pumpAndSettle();
      expect(find.byType(RenameChatDialog), findsNothing);
      expect(find.text('Renamed source'), findsOneWidget);
      expect(model.conversation.composerKey, 'chat:$_source');
      expect(_draft(tester), 'Unsent source draft');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rename Save during a quiet snapshot retains input and submits only after the read',
    (tester) async {
      final repository = _Actions();
      final model = await _show(tester, repository);
      await _menu(tester, 'Rename chat');
      await tester.enterText(
        find.byType(TextFormField),
        '  Keep this edited title  ',
      );
      final input = tester
          .widget<TextFormField>(find.byType(TextFormField))
          .controller!;
      final snapshot = Completer<Map<String, dynamic>>();
      repository.snapshotPending = snapshot;
      final callsBeforePoll = repository.calls.length;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(repository.calls.length, callsBeforePoll + 1);
      expect(repository.calls.last.$1, 'chat.snapshot');
      expect(model.loading, isFalse);
      expect(model.mutating, isFalse);
      expect(model.conversation.canRename, isFalse);
      expect(tester.widget<FilledButton>(_dialogSave).onPressed, isNull);
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
        isTrue,
      );
      await tester.tap(find.text('Save'));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byType(RenameChatDialog), findsOneWidget);
      expect(input.text, '  Keep this edited title  ');
      expect(repository.mutations, isEmpty);
      repository.snapshotPending = null;
      repository.rows[_source] = _summary(
        _source,
        'Externally updated title',
        250,
      );
      snapshot.complete({
        'version': 1,
        'chat': repository.rows[_source],
        'status': 'idle',
        'messages': [_message('source-message', 'Original history')],
        'cursor': null,
      });
      await tester.pumpAndSettle();
      expect(model.conversation.chat?.title, 'Externally updated title');
      expect(input.text, '  Keep this edited title  ');
      expect(tester.widget<FilledButton>(_dialogSave).onPressed, isNotNull);
      expect(repository.mutations, isEmpty);
      repository.pending = Completer<Map<String, dynamic>>();
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.byType(RenameChatDialog), findsOneWidget);
      expect(input.text, '  Keep this edited title  ');
      expect(tester.widget<FilledButton>(_dialogSave).onPressed, isNull);
      expect(repository.mutations.single.$2, {
        'projectId': _projectId,
        'sessionId': _source,
        'title': 'Keep this edited title',
      });
      await tester.tap(find.text('Saving'));
      await tester.pump();
      expect(repository.mutations.length, 1);
      repository.pending!.complete({
        'version': 1,
        'chat': _summary(_source, 'Keep this edited title', 300),
      });
      await tester.pumpAndSettle();
      expect(find.byType(RenameChatDialog), findsNothing);
      expect(model.conversation.chat?.title, 'Keep this edited title');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final malformed in [false, true]) {
    testWidgets(
      'rename ${malformed ? 'malformed reply' : 'known failure'} keeps the dialog and input for explicit retry',
      (tester) async {
        final repository = _Actions();
        final model = await _show(tester, repository);
        await tester.enterText(_composer, 'Unsent source draft');
        await _menu(tester, 'Rename chat');
        await tester.enterText(
          find.byType(TextFormField),
          '  Retry this title  ',
        );
        final input = tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!;
        if (malformed) {
          repository.reply = {'version': 1};
        } else {
          repository.failure = ChatFailure.denied;
        }
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(RenameChatDialog), findsOneWidget);
        expect(input.text, '  Retry this title  ');
        expect(model.conversation.chat?.title, 'Original chat');
        expect(_draft(tester), 'Unsent source draft');
        expect(
          find.descendant(
            of: find.byType(RenameChatDialog),
            matching: find.text(
              malformed
                  ? ChatFailure.invalid.message
                  : ChatFailure.denied.message,
            ),
          ),
          findsOneWidget,
        );
        expect(
          tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
          isTrue,
        );
        expect(tester.widget<FilledButton>(_dialogSave).onPressed, isNotNull);
        expect(repository.mutations.length, 1);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(input.text, '  Retry this title  ');
        expect(repository.mutations.length, 1);
        repository.failure = null;
        repository.reply = null;
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(RenameChatDialog), findsNothing);
        expect(model.conversation.chat?.title, 'Retry this title');
        expect(_draft(tester), 'Unsent source draft');
        expect(repository.mutations.length, 2);
        expect(model.error, isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'trust loss during a pending rename clears and dismisses the dialog before its late ack',
    (tester) async {
      final repository = _Actions();
      final model = await _show(tester, repository);
      await tester.enterText(_composer, 'Sensitive source draft');
      await _menu(tester, 'Rename chat');
      await tester.enterText(
        find.byType(TextFormField),
        'Sensitive edited title',
      );
      final input = tester
          .widget<TextFormField>(find.byType(TextFormField))
          .controller!;
      repository.pending = Completer<Map<String, dynamic>>();
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Saving'), findsOneWidget);
      final callsBeforeTrustLoss = repository.calls.length;
      repository.trusted = false;
      repository.online = false;
      repository.changes.add(null);
      expect(input.text, isEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(RenameChatDialog), findsNothing);
      expect(find.text('Sensitive edited title'), findsNothing);
      expect(find.text('Sensitive source draft'), findsNothing);
      repository.pending!.complete({
        'version': 1,
        'chat': _summary(_source, 'Sensitive edited title', 300),
      });
      await tester.pumpAndSettle();
      expect(model.trustLost, isTrue);
      expect(model.conversation.chat, isNull);
      expect(model.projects.projects, isEmpty);
      expect(model.conversation.messages, isEmpty);
      expect(model.conversation.canRename, isFalse);
      expect(find.text('Sensitive edited title'), findsNothing);
      expect(repository.calls.length, callsBeforeTrustLoss);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'fork menu preserves the source draft and opens an empty destination composer',
    (tester) async {
      final repository = _Actions();
      final model = await _show(tester, repository);
      await tester.enterText(_composer, 'Unsent source draft');
      repository.pending = Completer<Map<String, dynamic>>();
      await _menu(tester, 'Fork chat', settle: false);
      expect(model.conversation.chat?.id, _source);
      expect(_draft(tester), 'Unsent source draft');
      expect(model.conversation.isSending, isFalse);
      repository.pending!.complete({
        'version': 1,
        'chat': _summary(_fork, 'Forked chat', 300),
      });
      await tester.pumpAndSettle();
      expect(model.conversation.chat?.id, _fork);
      expect(_draft(tester), isEmpty);
      expect(find.text('Authoritative fork history'), findsOneWidget);
      await tester.enterText(_composer, 'Separate fork draft');
      model.back();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Original chat'));
      await tester.pumpAndSettle();
      expect(_draft(tester), 'Unsent source draft');
      expect(model.conversation.messages.single.text, 'Original history');
      model.back();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forked chat'));
      await tester.pumpAndSettle();
      expect(_draft(tester), 'Separate fork draft');
      expect(repository.mutations.single.$1, 'chat.fork');
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final transition in ['navigation', 'background', 'trust']) {
    testWidgets(
      'rename dialog handles $transition without submitting stale input',
      (tester) async {
        final repository = _Actions();
        final model = await _show(tester, repository);
        await tester.enterText(_composer, 'Sensitive draft');
        await _menu(tester, 'Rename chat');
        await tester.enterText(find.byType(TextFormField), 'Stale title');
        final input = tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!;
        if (transition == 'navigation') {
          model.back();
          expect(input.text, isEmpty);
          await tester.pumpAndSettle();
          await model.openChat(
            model.chatList.chats.singleWhere((c) => c.id == 'recent'),
          );
        } else if (transition == 'background') {
          model.setActive(false);
        } else {
          repository.trusted = false;
          repository.online = false;
          repository.changes.add(null);
          expect(input.text, isEmpty);
        }
        await tester.pumpAndSettle();
        if (transition == 'background') {
          expect(find.byType(RenameChatDialog), findsOneWidget);
          expect(input.text, 'Stale title');
          expect(tester.widget<FilledButton>(_dialogSave).onPressed, isNull);
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(find.byType(RenameChatDialog), findsOneWidget);
          model.setActive(true);
          await tester.pumpAndSettle();
          expect(input.text, 'Stale title');
          expect(tester.widget<FilledButton>(_dialogSave).onPressed, isNotNull);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
        } else {
          expect(find.byType(RenameChatDialog), findsNothing);
          expect(find.text('Stale title'), findsNothing);
        }
        expect(repository.mutations, isEmpty);
        if (transition == 'trust') {
          expect(model.conversation.messages, isEmpty);
          expect(find.text('Sensitive draft'), findsNothing);
          expect(find.text('Original history'), findsNothing);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'details pause hidden chat polling and accept explicit authoritative refresh',
    (tester) async {
      final repository = _Actions();
      final model = await _show(tester, repository);
      await tester.enterText(_composer, 'Unsent source draft');
      final key = model.conversation.composerKey;
      await tester.tap(find.byTooltip('Original chat'));
      await tester.pumpAndSettle();
      for (final status in {
        'busy': 'Working',
        'retry': 'Retrying',
        'unknown': 'Synchronizing',
        'idle': 'Idle',
      }.entries) {
        repository.rows[_source] = _summary(
          _source,
          'Updated ${status.key} title',
          300,
        );
        repository.status = status.key;
        final reads = repository.calls.length;
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(repository.calls.skip(reads), isEmpty);
        await model.refresh();
        await tester.pumpAndSettle();
        expect(repository.calls.skip(reads).map((c) => c.$1), [
          'project.list',
          'chat.snapshot',
        ]);
        expect(find.byType(ChatDetailsScreen), findsOneWidget);
        expect(find.text('Updated ${status.key} title'), findsOneWidget);
        expect(find.text('Original chat'), findsNothing);
        expect(find.text('Chat status: ${status.value}'), findsNothing);
        expect(find.text('Online'), findsNothing);
        expect(model.conversation.composerKey, key);
      }
      repository.online = false;
      repository.changes.add(null);
      await tester.pumpAndSettle();
      expect(find.byType(ChatDetailsScreen), findsOneWidget);
      expect(find.text('Offline'), findsNothing);
      expect(find.text('Chat status: Idle'), findsNothing);
      expect(
        find.text('OpenCode must be online for current chat status.'),
        findsNothing,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Updated idle title'), findsOneWidget);
      expect(find.byTooltip('Offline'), findsOneWidget);
      final dot = tester.widget<Icon>(find.byIcon(Icons.circle_outlined));
      expect(dot.size, 10);
      expect(dot.color, AppTheme.muted);
      expect(find.byIcon(Icons.circle), findsNothing);
      expect(_draft(tester), 'Unsent source draft');
      expect(repository.mutations, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'details fork opens the confirmed destination and preserves the source draft',
    (tester) async {
      final repository = _Actions();
      final model = await _show(tester, repository);
      await tester.enterText(_composer, 'Source details draft');
      await tester.tap(find.byTooltip('Original chat'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.widgetWithText(TextButton, 'Fork chat'),
        160,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Fork chat'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatDetailsScreen), findsNothing);
      expect(model.conversation.chat!.id, _fork);
      expect(_draft(tester), isEmpty);
      expect(repository.mutations.map((c) => c.$1), ['chat.fork']);
      await model.openChat(
        model.chatList.chats.singleWhere((chat) => chat.id == _source),
      );
      await tester.pumpAndSettle();
      expect(_draft(tester), 'Source details draft');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'details uncertain fork keeps its error visible and cannot be repeated',
    (tester) async {
      final repository = _Actions()..failure = ChatFailure.uncertain;
      final model = await _show(tester, repository);
      await tester.tap(find.byTooltip('Original chat'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.widgetWithText(TextButton, 'Fork chat'),
        160,
      );
      final press = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Fork chat'))
          .onPressed!;
      press();
      press();
      await tester.pumpAndSettle();
      expect(model.conversation.chat!.id, _source);
      expect(find.byType(ChatDetailsScreen), findsOneWidget);
      expect(find.text(model.error!), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Fork chat'))
            .onPressed,
        isNull,
      );
      press();
      await tester.pumpAndSettle();
      expect(repository.mutations.map((c) => c.$1), ['chat.fork']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final state in ['busy', 'unknown', 'offline', 'unsupported', 'draft']) {
    testWidgets('details fork and delete are disabled for $state', (
      tester,
    ) async {
      final repository = _Actions();
      final model = await _show(tester, repository);
      if (state == 'draft') {
        model.back();
        await tester.pumpAndSettle();
        model.startNewChat();
      } else if (state == 'busy' || state == 'unknown') {
        repository.status = state;
        await model.refresh();
      } else if (state == 'offline') {
        repository.online = false;
        repository.changes.add(null);
      } else {
        repository.unsupported.addAll(['chat.fork', 'chat.delete']);
      }
      await tester.pumpAndSettle();
      await tester.tap(
        find.byTooltip(state == 'draft' ? 'New chat' : 'Original chat'),
      );
      await tester.pumpAndSettle();
      for (final label in ['Fork chat', 'Delete chat']) {
        await tester.scrollUntilVisible(
          find.widgetWithText(TextButton, label),
          160,
        );
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, label))
              .onPressed,
          isNull,
        );
      }
      expect(repository.mutations, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'switching the source chat dismisses details without returning to the old source',
    (tester) async {
      final repository = _Actions();
      final model = await _show(tester, repository);
      await tester.enterText(_composer, 'Source-only draft');
      await tester.tap(find.byTooltip('Original chat'));
      await tester.pumpAndSettle();
      await model.openChat(
        model.chatList.chats.singleWhere((c) => c.id == 'recent'),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(ChatDetailsScreen, skipOffstage: false),
          matching: find.byType(TextButton, skipOffstage: false),
        ),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChatDetailsScreen, skipOffstage: false), findsNothing);
      expect(model.page, ChatPage.conversation);
      expect(model.conversation.chat?.id, 'recent');
      expect(_draft(tester), isEmpty);
      await tester.tap(find.byTooltip('Recent chat'));
      await tester.pumpAndSettle();
      expect(find.text('Recent chat'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(model.conversation.chat?.id, 'recent');
      expect(repository.mutations, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Refresh menu reads the authoritative snapshot and disables while loading or offline',
    (tester) async {
      final repository = _Actions();
      final model = await _show(tester, repository);
      await tester.enterText(_composer, 'Preserve the draft');
      final key = model.conversation.composerKey;
      final revision = model.conversation.messageHistoryRevision;
      repository.calls.clear();
      final pending = Completer<Map<String, dynamic>>();
      repository.snapshotPending = pending;
      expect(find.byTooltip('Refresh'), findsNothing);
      expect(find.byIcon(Icons.refresh), findsNothing);
      await _menu(tester, 'Refresh', settle: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(repository.calls.map((c) => c.$1), [
        'project.list',
        'chat.snapshot',
      ]);
      expect(repository.calls.last.$2, {
        'projectId': _projectId,
        'sessionId': _source,
        'includeSubtasks': true,
        'includeTools': true,
        'includeShell': true,
        'includeTodos': true,
      });
      expect(model.loading, isTrue);
      expect(model.canRefresh, isFalse);
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byType(PopupMenuButton<String>),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pump();
      expect(find.text('Refresh'), findsNothing);
      expect(repository.calls.length, 2);
      pending.complete({
        'version': 1,
        'chat': _summary(_source, 'Authoritative title', 300),
        'status': 'idle',
        'messages': [
          _message('new-message', 'Authoritative replacement history'),
        ],
        'cursor': null,
      });
      repository.snapshotPending = null;
      await tester.pumpAndSettle();
      expect(model.loading, isFalse);
      expect(model.conversation.composerKey, key);
      expect(model.conversation.messageHistoryRevision, greaterThan(revision));
      expect(model.conversation.messages.single.id, 'new-message');
      expect(find.text('Original history'), findsNothing);
      expect(find.text('Authoritative replacement history'), findsOneWidget);
      expect(_draft(tester), 'Preserve the draft');
      repository.online = false;
      repository.changes.add(null);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(PopupMenuItem<String>, 'Refresh'),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(repository.calls.length, 2);
      expect(find.text('Refresh'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_draft(tester), 'Preserve the draft');
      expect(repository.mutations, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Refresh is disabled during a quiet snapshot without showing loading',
    (tester) async {
      final repository = _Actions();
      final model = await _show(tester, repository);
      repository.snapshotPending = Completer<Map<String, dynamic>>();
      repository.calls.clear();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(model.loading, isFalse);
      expect(model.canRefresh, isFalse);
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(PopupMenuItem<String>, 'Refresh'),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(repository.calls.map((c) => c.$1), ['chat.snapshot']);
      repository.snapshotPending!.complete({
        'version': 1,
        'chat': repository.rows[_source],
        'status': 'idle',
        'messages': [_message('source-message', 'Original history')],
        'cursor': null,
      });
      repository.snapshotPending = null;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(model.canRefresh, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'small large-text header, action menu and keyboard dialog have labeled tap targets',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = _Actions();
      final model = await _show(tester, repository, largeText: true);
      await model.conversation.renameChat(
        'A long conversation name that cannot fit on a narrow phone',
      );
      await tester.pumpAndSettle();
      final semantics = tester.ensureSemantics();
      expect(find.byTooltip(model.conversation.chat!.title), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          '${model.conversation.chat!.title}, open chat details',
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Chat options'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      expect(find.text('Rename chat'), findsOneWidget);
      expect(find.text('Fork chat'), findsOneWidget);
      expect(find.text('Refresh'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await tester.tap(find.text('Rename chat'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpAndSettle();
      expect(find.text('Chat name'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unsupported and busy mutations are disabled and draft menu allows only Refresh',
    (tester) async {
      final repository = _Actions()
        ..unsupported.addAll(['chat.rename', 'chat.fork']);
      final model = await _show(tester, repository);
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      for (final label in ['Rename chat', 'Fork chat']) {
        expect(
          tester
              .widget<PopupMenuItem<String>>(
                find.widgetWithText(PopupMenuItem<String>, label),
              )
              .enabled,
          isFalse,
        );
      }
      expect(find.textContaining('Restart OpenCode'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      repository.unsupported.remove('chat.fork');
      await model.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      expect(
        find.text('Rename is not supported by this connector.'),
        findsOneWidget,
      );
      expect(find.textContaining('Restart OpenCode'), findsNothing);
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(PopupMenuItem<String>, 'Fork chat'),
            )
            .enabled,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      repository.unsupported.clear();
      repository.status = 'busy';
      await model.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(PopupMenuItem<String>, 'Rename chat'),
            )
            .enabled,
        isTrue,
      );
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(PopupMenuItem<String>, 'Fork chat'),
            )
            .enabled,
        isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      model.back();
      await tester.pumpAndSettle();
      model.startNewChat();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byType(PopupMenuButton<String>),
            )
            .enabled,
        isTrue,
      );
      await tester.enterText(_composer, 'Keep the new draft');
      final key = model.conversation.composerKey;
      repository.calls.clear();
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      for (final label in ['Rename chat', 'Fork chat', 'Refresh']) {
        expect(
          tester
              .widget<PopupMenuItem<String>>(
                find.widgetWithText(PopupMenuItem<String>, label),
              )
              .enabled,
          label == 'Refresh',
        );
      }
      expect(find.byType(PopupMenuDivider), findsOneWidget);
      expect(find.textContaining('Restart OpenCode'), findsNothing);
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(repository.calls.map((c) => c.$1), ['project.list']);
      expect(model.conversation.isDraft, isTrue);
      expect(model.conversation.composerKey, key);
      expect(model.conversation.chat, isNull);
      expect(_draft(tester), 'Keep the new draft');
      expect(repository.mutations, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final operation in ['chat.rename', 'chat.fork', 'chat.snapshot']) {
    for (final duringSeal in [false, true]) {
      test(
        'relay disconnect ${duringSeal ? 'during sealing' : 'after send'} classifies $operation',
        () async {
          final crypto = _WireCrypto();
          if (duringSeal) crypto.sealing = Completer<Map<String, dynamic>>();
          final relay = _connected(crypto);
          final sent = <String>[];
          final result = relay.request(
            operation: operation,
            body: {
              'projectId': _projectId,
              'sessionId': _source,
              if (operation == 'chat.rename') 'title': 'Name',
            },
            identity: _own,
            peer: _peer,
            send: sent.add,
          );
          final checked = expectLater(
            result,
            throwsA(
              operation == 'chat.snapshot'
                  ? ChatFailure.offline
                  : ChatFailure.uncertain,
            ),
          );
          await _flush();
          expect(sent.length, duringSeal ? 0 : 1);
          relay.disconnect();
          await checked;
          if (duringSeal) {
            crypto.sealing!.complete({});
            await _flush();
            expect(sent, isEmpty);
          }
          relay.disconnect();
        },
      );
    }
  }
}

Finder get _composer => find.byKey(const ValueKey('chat-composer'));
Finder get _sparkles => find.byTooltip('Model and effort');
Finder get _bannerTitle => find.byKey(const ValueKey('model-banner-title'));

/// Taps the effort slider where its [stop] of [stops] dots sits, the way a
/// thumb comes to rest on one. The track is inset by a thumb radius at either
/// end -- see ModelBanner -- so the stops span that narrower span.
Future<void> _tapEffort(WidgetTester tester, int stop, int stops) async {
  const thumb = 16.0;
  final rect = tester.getRect(find.byType(Slider));
  final track = rect.width - thumb * 2;
  await tester.tapAt(
    Offset(rect.left + thumb + track * stop / (stops - 1), rect.center.dy),
  );
  await tester.pumpAndSettle();
}

Finder get _dialogSave => find.descendant(
  of: find.byType(RenameChatDialog),
  matching: find.byType(FilledButton),
);
String _draft(WidgetTester tester) =>
    tester.widget<TextField>(_composer).controller!.text;
Future<void> _flush() => Future<void>.delayed(Duration.zero);

Future<ChatViewModel> _open(_Actions repository) async {
  final model = ChatViewModel(repository, 'connector');
  addTearDown(() async {
    model.dispose();
    await repository.changes.close();
    expect(repository.unexpected, isEmpty);
  });
  await model.refresh();
  await model.openProject(model.projects.projects.single);
  await model.openChat(
    model.chatList.chats.singleWhere((c) => c.id == _source),
  );
  expect(model.error, isNull);
  return model;
}

Future<ChatViewModel> _show(
  WidgetTester tester,
  _Actions repository, {
  bool largeText = false,
}) async {
  addTearDown(() async {
    await repository.changes.close();
    expect(repository.unexpected, isEmpty);
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            // Control-flow tests settle routes; activity animation is exercised
            // separately with explicit frame pumping and lifecycle assertions.
            .copyWith(
              textScaler: TextScaler.linear(largeText ? 2 : 1),
              disableAnimations: true,
            ),
        child: child!,
      ),
      home: ChatFlowScreen(
        repository: repository,
        connectorId: 'connector',
        connectionName: 'Laptop',
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Sample project'));
  await tester.pumpAndSettle();
  final model = tester.widget<ChatListView>(find.byType(ChatListView)).model;
  await tester.scrollUntilVisible(
    find.text('Original chat'),
    150,
    scrollable: find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Original chat'));
  await tester.pumpAndSettle();
  return model;
}

Future<void> _menu(
  WidgetTester tester,
  String label, {
  bool settle = true,
}) async {
  await tester.tap(find.byTooltip('Chat options'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Map<String, dynamic> _summary(String id, String title, int updatedAt) => {
  'id': id,
  'title': title,
  'updatedAt': updatedAt,
};
Map<String, dynamic> _message(String id, String text) => {
  'id': id,
  'role': 'user',
  'text': text,
  'truncated': false,
};

final class _Actions implements ChatRepository {
  final changes = StreamController<void>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>)>[];
  final unexpected = <String>[];
  final unsupported = <String>{};
  final rows = <String, Map<String, dynamic>>{
    _source: _summary(_source, 'Original chat', 100),
    'recent': _summary('recent', 'Recent chat', 200),
    'pinned': _summary('pinned', 'Pinned chat', 50),
  };
  bool online = true, trusted = true;
  String status = 'idle';
  String? cursor;
  ChatFailure? failure, listFailure, modelsFailure;
  List<Map<String, dynamic>> models = [];
  Map<String, dynamic>? snapshotModel;
  Map<String, dynamic>? reply;
  Completer<Map<String, dynamic>>? pending, snapshotPending;
  List<(String, Map<String, dynamic>)> get mutations => calls
      .where((c) => ['chat.rename', 'chat.fork', 'chat.prompt'].contains(c.$1))
      .toList();

  @override
  Stream<void> get chatConnectionChanges => changes.stream;
  @override
  Stream<ChatEvent> get chatEvents => const Stream.empty();
  @override
  Object chatConnectionGeneration(String connectorId) => 0;
  @override
  bool chatOnline(String connectorId) => online;
  @override
  bool chatTrusted(String connectorId) => trusted;
  @override
  bool chatSupports(String connectorId, String operation) =>
      !operation.startsWith('project.mcp.') &&
      !operation.startsWith('chat.stream.') &&
      operation != 'chat.activities' &&
      operation != 'chat.images' &&
      operation != 'chat.permissions' &&
      operation != 'chat.permission.reply' &&
      operation != 'chat.questions' &&
      operation != 'chat.question.reply' &&
      !unsupported.contains(operation);
  @override
  Future<Set<String>> pinnedChatIds(
    String connectorId,
    String projectPath,
  ) async => {'pinned'};
  @override
  Future<Set<String>> setChatPinned(
    String connectorId,
    String projectPath,
    String sessionId,
    bool pinned,
  ) async {
    unexpected.add('setChatPinned');
    throw StateError('Unexpected pin mutation');
  }

  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async {
    calls.add((operation, Map.of(body)));
    final fields = switch (operation) {
      'project.list' => <String>{},
      'chat.list' => {'projectId'},
      'chat.snapshot' => {
        'projectId',
        'sessionId',
        if (body.containsKey('cursor')) 'cursor',
        if (body.containsKey('includeSubtasks')) 'includeSubtasks',
        if (body.containsKey('includeTools')) 'includeTools',
        if (body.containsKey('includeShell')) 'includeShell',
        if (body.containsKey('includeTodos')) 'includeTodos',
      },
      'chat.rename' => {'projectId', 'sessionId', 'title'},
      'chat.fork' => {'projectId', 'sessionId'},
      'chat.abort' => {'projectId', 'sessionId'},
      'chat.prompt' => {
        'projectId',
        'sessionId',
        'text',
        if (body.containsKey('mode')) 'mode',
        if (body.containsKey('model')) 'model',
      },
      'chat.models' => {'projectId'},
      _ => null,
    };
    if (connectorId != 'connector' ||
        fields == null ||
        !fields.containsAll(body.keys) ||
        !body.keys.toSet().containsAll(fields) ||
        (operation != 'project.list' && body['projectId'] != _projectId)) {
      unexpected.add('$operation ${body.keys.toList()}');
      throw StateError('Unexpected chat request');
    }
    if (operation == 'project.list') {
      return {
        'version': 1,
        'projects': [
          {'id': _projectId, 'name': 'Sample project', 'path': '/work/sample'},
        ],
        'pathEntry': false,
      };
    }
    if (operation == 'chat.list') {
      if (listFailure != null) throw listFailure!;
      return {'version': 1, 'chats': rows.values.toList(), 'cursor': null};
    }
    if (operation == 'chat.models') {
      if (modelsFailure != null) throw modelsFailure!;
      return {'version': 1, 'models': models};
    }
    final id = body['sessionId'] as String;
    if (!rows.containsKey(id)) {
      unexpected.add('Unknown session $id');
      throw StateError('Unknown session');
    }
    if (operation == 'chat.snapshot') {
      if (snapshotPending != null) return snapshotPending!.future;
      final older = body.containsKey('cursor');
      return {
        'version': 1,
        'chat': rows[id],
        'status': status,
        'messages': [
          id == _fork
              ? _message('fork-message', 'Authoritative fork history')
              : _message(
                  older ? 'source-old' : 'source-message',
                  older ? 'Older source history' : 'Original history',
                ),
        ],
        'cursor': older || id == _fork ? null : cursor,
        if (!older && snapshotModel != null) 'model': snapshotModel,
      };
    }
    if (failure != null) throw failure!;
    final result = pending != null
        ? await pending!.future
        : reply ??
              switch (operation) {
                'chat.rename' => {
                  'version': 1,
                  'chat': _summary(id, body['title'] as String, 300),
                },
                'chat.fork' => {
                  'version': 1,
                  'chat': _summary(_fork, 'Forked chat', 300),
                },
                'chat.abort' => {'version': 1},
                'chat.prompt' => {'version': 1, 'accepted': true},
                _ => throw StateError('Unhandled operation $operation'),
              };
    if (result['version'] == 1 && result['chat'] is Map<String, dynamic>) {
      final summary = result['chat'] as Map<String, dynamic>;
      if (summary['id'] is String &&
          summary['parentId'] == null &&
          summary['title'] is String &&
          (summary['title'] as String).length <= 512 &&
          (operation != 'chat.fork' || summary['id'] != id)) {
        rows[summary['id'] as String] = summary;
      }
    }
    return result;
  }
}

const _own = <String, dynamic>{'keyId': 'client-key'};
const _peer = PublicIdentity(
  keyId: 'connector-key',
  publicKey: 'unused-test-key',
);
final _testEpoch = 'e' * 43;
int _nextSequence = 0;

/// Relay requests only flow once a peer's hello has established an epoch.
RelayRequests _connected(RelayCrypto crypto) {
  final relay = RelayRequests(crypto: crypto);
  relay.connect(peerKeyId: _peer.keyId, epoch: _testEpoch);
  return relay;
}

// Only the crypto boundary is faked; correlation, wire version and disconnect
// classification execute the production RelayRequests implementation.
final class _WireCrypto implements RelayCrypto {
  late Map<String, dynamic> payload;
  Map<String, dynamic> response = {};
  Completer<Map<String, dynamic>>? sealing;
  @override
  Future<Map<String, dynamic>> seal(
    Map<String, dynamic> own,
    PublicIdentity peer,
    Map<String, dynamic> payload,
    String epoch,
    int sequence,
  ) async {
    this.payload = payload;
    return sealing != null ? sealing!.future : <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> open(
    Map<String, dynamic> own,
    PublicIdentity peer,
    Map<String, dynamic> envelope,
    String epoch,
  ) async => response;
  Map<String, dynamic> envelope() => {
    'protocolVersion': 2,
    'type': 'relay.envelope',
    'messageId': requestId(),
    'senderKeyId': _peer.keyId,
    'recipientKeyId': _own['keyId'],
    'epoch': _testEpoch,
    'sequence': _nextSequence++,
    'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
    'suite': identitySuite,
    'encapsulatedKey': base64Url(List.filled(65, 1)),
    'ciphertext': base64Url([1]),
  };
}
