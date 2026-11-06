import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/data/voice_transport.dart';
import 'package:openremotecode/features/chat/domain/voice_recorder.dart';
import 'package:openremotecode/features/chat/domain/voice_note.dart';
import 'package:openremotecode/features/chat/ui/voice_controls.dart';
import 'package:openremotecode/features/chat/ui/chat_flow_screen.dart';
import 'package:openremotecode/features/chat/voice_view_model.dart';

final fixture = jsonDecode(
  File('../packages/protocol/test/fixtures/voice-v1.json').readAsStringSync(),
) as Map<String, dynamic>;

Future<void> flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> settleVoice(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await tester.runAsync(flush);
  }
}

class Recorder implements VoiceRecorder {
  bool permitted = true;
  int starts = 0, stops = 0;
  StreamController<Uint8List>? audio;
  Completer<bool>? permission;
  @override
  Future<bool> requestPermission() async => permission?.future ?? permitted;
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    audio = StreamController<Uint8List>(sync: true);
    return audio!.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (audio != null && !audio!.isClosed) await audio!.close();
  }

  @override
  Future<void> dispose() => stop();
  void frame({bool speech = true}) {
    if (audio == null || audio!.isClosed) return;
    final bytes = Uint8List(3200);
    if (speech) {
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < 3200; i += 2) {
        data.setInt16(i, i % 4 == 0 ? 3000 : -3000, Endian.little);
      }
    }
    audio!.add(bytes);
  }
}

class Repository implements ChatRepository {
  final calls = <(String, Map<String, dynamic>)>[];
  bool online = true, supported = true;
  bool available = true;
  bool statusSupported = true;
  int statusCalls = 0;
  Completer<Map<String, dynamic>>? status;
  Map<String, dynamic>? statusResponse;
  bool failStatus = false;
  Object generation = Object();
  Completer<Map<String, dynamic>>? finish;
  Completer<Map<String, dynamic>>? opening;
  bool failAudio = false;
  String transcript = fixture['transcript']['text'] as String;
  @override
  bool chatOnline(String id) => online;
  @override
  bool chatTrusted(String id) => true;
  @override
  bool chatSupports(String id, String op) =>
      supported && (op != 'voice.status' || statusSupported);
  @override
  Object chatConnectionGeneration(String id) => generation;
  @override
  Future<Map<String, dynamic>> chatRequest(
    String id,
    String op,
    Map<String, dynamic> body,
  ) async {
    if (op == 'voice.status') {
      statusCalls++;
      if (failStatus) throw ChatFailure.unavailable;
      return status?.future ??
          statusResponse ??
          (available
              ? fixture['available'] as Map<String, dynamic>
              : fixture['unavailable'] as Map<String, dynamic>);
    }
    calls.add((op, body));
    if (op == 'voice.start' && opening != null) return opening!.future;
    if (op == 'voice.finish' && finish != null) return finish!.future;
    if (op == 'voice.audio' && failAudio) throw ChatFailure.unavailable;
    return switch (op) {
      'voice.start' => {
        ...fixture['ready'] as Map<String, dynamic>,
        'voiceId': body['voiceId'],
      },
      'voice.audio' => {
        'version': 1,
        'voiceId': body['voiceId'],
        'sequence': body['sequence'],
      },
      'voice.finish' => {
        'version': 1,
        'voiceId': body['voiceId'],
        'text': transcript,
      },
      'voice.cancel' => {
        'version': 1,
        'voiceId': body['voiceId'],
        'cancelled': true,
      },
      _ => throw StateError(op),
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected method');
}

class Harness {
  final recorder = Recorder();
  final repo = Repository();
  final sent = <String>[];
  final drafts = <String>[];
  bool accepted = true;
  VoiceContext? target = const VoiceContext(
    '22222222-2222-4222-8222-222222222222',
    'chat:session_voice',
    'session_voice',
  );
  late final model = VoiceViewModel(
    transport: VoiceTransport(repo, 'connector'),
    recorder: recorder,
    context: () => target,
    send: (text) async {
      sent.add(text);
      return accepted;
    },
    appendDraft: (text) {
      drafts.add(text);
      return true;
    },
    sendNote: (note) async {
      sent.add(note.prompt);
      return accepted;
    },
  );
  Future<void> frames(int count, {bool speech = true}) async {
    for (var i = 0; i < count; i++) {
      recorder.frame(speech: speech);
      await flush();
    }
  }

  Future<void> close() async {
    await model.cancel();
    model.dispose();
  }
}

class ScreenRepository extends Repository {
  final changes = StreamController<void>.broadcast();
  final prompts = <String>[];
  @override
  Stream<void> get chatConnectionChanges => changes.stream;
  @override
  Stream<ChatEvent> get chatEvents => const Stream.empty();
  @override
  bool chatSupports(String id, String op) =>
      (voiceOperations.contains(op) && super.chatSupports(id, op)) ||
      [
        'project.list',
        'project.open',
        'chat.list',
        'chat.get',
        'chat.snapshot',
        'chat.prompt',
        'chat.create',
      ].contains(op);
  @override
  Future<Set<String>> pinnedChatIds(String connectorId, String path) async =>
      {};
  Map<String, dynamic> get summary => {
    'id': 'session_voice',
    'title': 'Voice chat',
    'updatedAt': 1,
  };
  @override
  Future<Map<String, dynamic>> chatRequest(
    String id,
    String op,
    Map<String, dynamic> body,
  ) async {
    if (voiceOperations.contains(op)) return super.chatRequest(id, op, body);
    if (op == 'chat.prompt') prompts.add(body['text'] as String);
    return switch (op) {
      'project.list' => {
        'version': 1,
        'projects': [
          {
            'id': fixture['start']['projectId'],
            'name': 'Voice project',
            'path': '/sample',
          },
        ],
        'pathEntry': false,
      },
      'chat.list' => {
        'version': 1,
        'chats': [summary],
        'cursor': null,
      },
      'chat.get' || 'chat.create' => {'version': 1, 'chat': summary},
      'chat.snapshot' => {
        'version': 1,
        'chat': summary,
        'status': 'idle',
        'messages': [
          for (final entry in prompts.asMap().entries)
            {
              'id': 'voice-message-${entry.key}',
              'role': 'user',
              'text': entry.value,
              'truncated': false,
            },
        ],
        'cursor': null,
      },
      'chat.prompt' => {'version': 1, 'accepted': true},
      _ => throw StateError(op),
    };
  }
}

void main() {
  test('unknown, unavailable, malformed and unsupported status never enables capture', () async {
    final h = Harness();
    expect(h.model.showControls, isFalse);
    await h.model.start(VoiceMode.note);
    expect(h.recorder.starts, 0);
    for (final response in [
      fixture['unavailable'] as Map<String, dynamic>,
      {'version': 1, 'available': 'true'},
      {'version': 2, 'available': true},
      {'version': 1, 'available': true, 'token': 'unexpected'},
    ]) {
      h.repo.statusResponse = response;
      await h.model.refreshAvailability();
      expect(h.model.available, isFalse);
      expect(h.model.canStart, isFalse);
    }
    h.repo.statusResponse = null;
    h.repo.failStatus = true;
    await h.model.refreshAvailability();
    expect(h.model.showControls, isFalse);
    h.repo.failStatus = false;
    h.repo.statusSupported = false;
    final calls = h.repo.statusCalls;
    await h.model.refreshAvailability();
    expect(h.repo.statusCalls, calls);
    expect(h.model.showControls, isFalse);
    await h.close();
  });

  test('status checks coalesce and cannot enable voice after a peer or lifecycle change', () async {
    final h = Harness();
    h.repo.status = Completer<Map<String, dynamic>>();
    final a = h.model.refreshAvailability();
    final b = h.model.refreshAvailability();
    expect(h.repo.statusCalls, 1);
    h.repo.generation = Object();
    h.model.contextChanged();
    h.repo.status!.complete(fixture['available'] as Map<String, dynamic>);
    await Future.wait([a, b]);
    expect(h.model.available, isFalse);
    h.repo.status = null;
    await h.model.refreshAvailability();
    expect(h.model.available, isTrue);
    h.repo.online = false;
    h.model.contextChanged();
    h.repo.online = true;
    expect(h.model.available, isFalse);
    h.repo.status = Completer<Map<String, dynamic>>();
    h.model.setMonitoring(true);
    h.model.setMonitoring(false);
    h.repo.status!.complete(fixture['available'] as Map<String, dynamic>);
    await flush();
    expect(h.model.available, isFalse);
    await h.close();
  });

  test(
    'losing Hex availability stops capture without sending or changing a draft',
    () async {
      final h = Harness();
      await h.model.refreshAvailability();
      await h.model.start(VoiceMode.call);
      await h.frames(5);
      h.repo.available = false;
      await h.model.refreshAvailability();
      await flush();
      expect(h.model.active, isFalse);
      expect(h.model.showControls, isFalse);
      expect(h.recorder.audio?.isClosed, isTrue);
      expect(h.sent, isEmpty);
      expect(h.drafts, isEmpty);
      h.repo.available = true;
      await h.model.refreshAvailability();
      expect(h.model.canStart, isTrue);
      await h.close();
    },
  );

  testWidgets(
    'both entry buttons follow live Hex status, reconnect and foreground state',
    (tester) async {
      final repo = ScreenRepository()..available = false;
      final recorder = Recorder();
      await tester.pumpWidget(
        MaterialApp(
          home: ChatFlowScreen(
            repository: repo,
            connectorId: 'connector',
            connectionName: 'Computer',
            voiceRecorderFactory: () => recorder,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.statusCalls, 0); // No polling on the project or chat lists.
      await tester.tap(find.text('Voice project'));
      await tester.pumpAndSettle();
      expect(repo.statusCalls, 0);
      await tester.tap(find.text('Voice chat'));
      await tester.pumpAndSettle();
      final note = find.byKey(const ValueKey('voice-note'));
      final call = find.byKey(const ValueKey('voice-call'));
      expect(note, findsNothing);
      expect(call, findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        'Keep this draft',
      );
      repo.available = true;
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(note, findsOneWidget);
      expect(call, findsOneWidget);
      repo.available = false;
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(note, findsNothing);
      expect(call, findsNothing);
      expect(find.text('Keep this draft'), findsOneWidget);
      repo.available = true;
      repo.status = Completer<Map<String, dynamic>>();
      repo.generation = Object();
      repo.changes.add(null);
      await tester.pumpAndSettle();
      expect(note, findsNothing);
      repo.status!.complete(fixture['available'] as Map<String, dynamic>);
      repo.status = null;
      await tester.pumpAndSettle();
      expect(note, findsOneWidget);
      expect(call, findsOneWidget);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      final calls = repo.statusCalls;
      await tester.pump(const Duration(seconds: 30));
      expect(repo.statusCalls, calls);
      repo.status = Completer<Map<String, dynamic>>();
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(note, findsNothing);
      expect(call, findsNothing);
      repo.status!.complete(fixture['available'] as Map<String, dynamic>);
      repo.status = null;
      await tester.pumpAndSettle();
      expect(note, findsOneWidget);
      expect(call, findsOneWidget);
      expect(recorder.starts, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(flush);
      await repo.changes.close();
    },
  );

  testWidgets('connectors without voice.status hide both buttons', (
    tester,
  ) async {
    final repo = ScreenRepository()..statusSupported = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatFlowScreen(
          repository: repo,
          connectorId: 'connector',
          connectionName: 'Computer',
          voiceRecorderFactory: Recorder.new,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voice project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voice chat'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('voice-note')), findsNothing);
    expect(find.byKey(const ValueKey('voice-call')), findsNothing);
    expect(repo.statusCalls, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(flush);
    await repo.changes.close();
  });

  testWidgets(
    'chat screen places voice notes beside Send and calls in the header, preserving drafts',
    (tester) async {
      final repo = ScreenRepository();
      final recorder = Recorder();
      await tester.pumpWidget(
        MaterialApp(
          home: ChatFlowScreen(
            repository: repo,
            connectorId: 'connector',
            connectionName: 'Computer',
            voiceRecorderFactory: () => recorder,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voice project'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voice chat'));
      await tester.pumpAndSettle();
      final note = find.byKey(const ValueKey('voice-note'));
      final call = find.byKey(const ValueKey('voice-call'));
      final send = find.byKey(const ValueKey('chat-send'));
      expect(tester.getCenter(note).dy, closeTo(tester.getCenter(send).dy, 10));
      expect(tester.getCenter(call).dy, lessThan(tester.getCenter(note).dy));
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        'Typed draft',
      );
      await tester.tap(note);
      await settleVoice(tester);
      for (var i = 0; i < 5; i++) {
        recorder.frame();
      }
      await tester.runAsync(flush);
      await tester.tap(note);
      await settleVoice(tester);
      expect(find.text('Typed draft'), findsOneWidget);
      expect(find.text('Voice note · Not sent'), findsOneWidget);
      expect(repo.prompts, isEmpty);
      await tester.tap(find.text('Transcribe'));
      await tester.pump();
      expect(find.text(repo.transcript), findsOneWidget);
      expect(repo.prompts, isEmpty);
      await tester.tap(find.text('Send voice note'));
      await settleVoice(tester);
      expect(VoiceNote.parse(repo.prompts.single)!.transcript, repo.transcript);
      expect(find.text('Voice note'), findsOneWidget);
      expect(find.text(repo.transcript), findsNothing);
      await tester.tap(call);
      await settleVoice(tester);
      expect(find.byTooltip('End voice call'), findsOneWidget);
      for (var i = 0; i < 20; i++) {
        recorder.frame(speech: i < 5);
        await tester.runAsync(flush);
        await tester.pump();
      }
      expect(repo.prompts.last, repo.transcript);
      expect(repo.prompts.length, 2);
      expect(find.text('Typed draft'), findsOneWidget);
      // Leaving a conversation ends capture; the current text draft remains separate.
      await tester.tap(find.byType(BackButton));
      await tester.runAsync(flush);
      await tester.pumpAndSettle();
      expect(recorder.audio?.isClosed, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(flush);
      await repo.changes.close();
    },
  );
  test('Dart transport agrees with the shared voice contract', () async {
    final repo = Repository();
    final transport = VoiceTransport(repo, 'connector');
    expect(await transport.available(), fixture['available']['available']);
    repo.available = false;
    expect(await transport.available(), fixture['unavailable']['available']);
    final turn = transport.turn(
      const VoiceContext(
        '22222222-2222-4222-8222-222222222222',
        'chat:session_voice',
        'session_voice',
      ),
    );
    await turn.start();
    await turn.append(Uint8List(2));
    expect(
      repo.calls[0].$2,
      {...fixture['start'] as Map<String, dynamic>, 'voiceId': turn.id}
        ..remove('version'),
    );
    expect(
      repo.calls[1].$2,
      {...fixture['audio'] as Map<String, dynamic>, 'voiceId': turn.id}
        ..remove('version'),
    );
    expect(await turn.finish(), fixture['transcript']['text']);
    await expectLater(turn.append(Uint8List(1)), throwsA(ChatFailure.invalid));
  });

  test('quick note previews audio without filling the draft or automatically sending', () async {
    final h = Harness();
    await h.model.refreshAvailability();
    await h.model.start(VoiceMode.note);
    await h.model.start(VoiceMode.call);
    await h.frames(5);
    final finished = h.model.finishNote();
    await flush();
    await finished;
    await flush();
    expect(h.recorder.starts, 1);
    expect(h.sent, isEmpty);
    expect(h.drafts, isEmpty);
    expect(h.model.phase, VoicePhase.preview);
    expect(h.model.pendingNote!.audio.length, 16000);
    await h.model.submitNote();
    expect(h.sent.length, 1);
    expect(VoiceNote.parse(h.sent.single)!.transcript, h.repo.transcript);
    expect(h.model.active, isFalse);
    await h.close();
  });

  test('call sends only after speech and silence and keeps listening for the next turn', () async {
    final h = Harness();
    await h.model.refreshAvailability();
    await h.model.start(VoiceMode.call);
    await h.frames(30);
    expect(
      h.sent,
      isEmpty,
    ); // Processing segments cannot auto-send half a thought.
    await h.frames(15, speech: false);
    expect(h.sent, [h.repo.transcript]);
    expect(h.model.isCall, isTrue);
    expect(h.recorder.starts, 1);
    await h.frames(5);
    await h.frames(15, speech: false);
    expect(h.sent.length, 2);
    expect(h.drafts, isEmpty);
    await h.close();
  });

  test('silence alone never sends; mute discards an unfinished turn', () async {
    final h = Harness();
    await h.model.refreshAvailability();
    await h.model.start(VoiceMode.call);
    await h.frames(20, speech: false);
    expect(h.sent, isEmpty);
    await h.model.toggleMute();
    final count = h.repo.calls.where((c) => c.$1 == 'voice.audio').length;
    await h.frames(10);
    expect(h.repo.calls.where((c) => c.$1 == 'voice.audio').length, count);
    expect(h.model.muted, isTrue);
    await h.model.toggleMute();
    await h.frames(5);
    await h.frames(15, speech: false);
    expect(h.sent.length, 1);
    await h.close();
  });

  test('uncertain prompt submission ends the call and keeps text for review without retrying', () async {
    final h = Harness()..accepted = false;
    await h.model.refreshAvailability();
    await h.model.start(VoiceMode.call);
    await h.frames(5);
    await h.frames(15, speech: false);
    expect(h.sent.length, 1);
    expect(h.drafts, [h.repo.transcript]);
    expect(h.model.active, isFalse);
    expect(h.model.error, contains('Check the chat'));
    await flush();
    expect(h.sent.length, 1);
    await h.close();
  });

  for (final change in ['navigation', 'epoch', 'offline', 'hangup']) {
    test('$change discards an in-flight transcription', () async {
      final h = Harness();
      await h.model.refreshAvailability();
      h.repo.finish = Completer<Map<String, dynamic>>();
      await h.model.start(VoiceMode.call);
      await h.frames(5);
      await h.frames(15, speech: false);
      expect(h.model.phase, VoicePhase.transcribing);
      if (change == 'navigation') {
        h.target = const VoiceContext('other', 'chat:other', 'other');
      }
      if (change == 'epoch') h.repo.generation = Object();
      if (change == 'offline') h.repo.online = false;
      if (change == 'hangup') {
        await h.model.cancel();
      } else {
        h.model.contextChanged();
      }
      await flush();
      final id = h.repo.calls.first.$2['voiceId'];
      h.repo.finish!.complete({
        'version': 1,
        'voiceId': id,
        'text': h.repo.transcript,
      });
      await flush();
      expect(h.sent, isEmpty);
      expect(h.drafts, isEmpty);
      expect(h.model.active, isFalse);
      await h.close();
    });
  }

  test(
    'slow inference bounds queued audio and stops instead of dropping speech',
    () async {
      final h = Harness();
      await h.model.refreshAvailability();
      h.repo.finish = Completer<Map<String, dynamic>>();
      await h.model.start(VoiceMode.call);
      await h.frames(5);
      await h.frames(15, speech: false);
      await h.frames(55);
      expect(h.model.active, isFalse);
      expect(h.model.error, contains('keep up'));
      h.repo.finish!.complete({
        'version': 1,
        'voiceId': h.repo.calls.first.$2['voiceId'],
        'text': h.repo.transcript,
      });
      await flush();
      expect(h.sent, isEmpty);
      await h.close();
    },
  );

  test(
    'permission denial does not create a remote stream or open the microphone',
    () async {
      final h = Harness();
      await h.model.refreshAvailability();
      h.recorder.permitted = false;
      await h.model.start(VoiceMode.note);
      expect(h.repo.calls, isEmpty);
      expect(h.recorder.starts, 0);
      expect(h.model.error, contains('microphone access'));
      await h.close();
    },
  );

  test(
    'cancellation during permission prompt prevents late microphone start',
    () async {
      final h = Harness();
      await h.model.refreshAvailability();
      h.recorder.permission = Completer<bool>();
      final start = h.model.start(VoiceMode.note);
      await h.model.cancel();
      h.recorder.permission!.complete(true);
      await start;
      expect(h.recorder.starts, 0);
      expect(h.repo.calls, isEmpty);
      await h.close();
    },
  );

  test('lost audio acknowledgement is never retried', () async {
    final h = Harness();
    await h.model.refreshAvailability();
    h.repo.failAudio = true;
    await h.model.start(VoiceMode.call);
    await h.frames(10);
    expect(h.repo.calls.where((c) => c.$1 == 'voice.audio').length, 1);
    expect(h.model.active, isFalse);
    expect(h.sent, isEmpty);
    await h.close();
  });

  testWidgets(
    'voice buttons have distinct actions and status fits narrow large-text layouts',
    (tester) async {
      final h = Harness();
      await h.model.refreshAvailability();
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: ListenableBuilder(
              listenable: h.model,
              builder: (_, _) => Scaffold(
                appBar: AppBar(
                  actions: [
                    VoiceCallButton(
                      voice: h.model,
                      enabled: true,
                      onStart: () => unawaited(h.model.start(VoiceMode.call)),
                    ),
                  ],
                ),
                body: Column(
                  children: [
                    VoiceStatusBar(voice: h.model),
                    VoiceNoteButton(voice: h.model, enabled: true),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('voice-note')));
      await tester.pump();
      expect(h.model.isNote, isTrue);
      expect(find.byTooltip('Stop recording and preview'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(h.model.cancel);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('voice-call')));
      await tester.pump();
      expect(h.model.isCall, isTrue);
      expect(find.byTooltip('End voice call'), findsOneWidget);
      expect(find.textContaining('speech sends after a pause'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('End voice call'));
      await tester.runAsync(h.model.cancel);
      await tester.pump();
      expect(h.model.active, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    },
  );
}
