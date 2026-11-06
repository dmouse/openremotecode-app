import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/domain/voice_note.dart';
import 'package:openremotecode/features/chat/ui/chat_flow_screen.dart';
import 'package:openremotecode/features/chat/ui/voice_controls.dart';
import 'package:openremotecode/features/chat/ui/voice_note_bubble.dart';
import 'package:openremotecode/features/chat/voice_view_model.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

import 'voice_test.dart' as voice;

final fixture = jsonDecode(
  File('../packages/protocol/test/fixtures/voice-note-v2.json')
      .readAsStringSync(),
) as Map<String, dynamic>;

VoiceNote note() => VoiceNote(
  id: fixture['id'] as String,
  duration: Duration(milliseconds: fixture['durationMs'] as int),
  transcript: fixture['transcript'] as String,
);

void main() {
  test('voice metadata agrees with the shared encrypted text fixture', () {
    final n = note();
    expect(n.prompt, fixture['prompt']);
    final parsed = VoiceNote.parse(n.prompt)!;
    expect(parsed.id, n.id);
    expect(parsed.transcript, n.transcript);
    expect(parsed.duration, n.duration);
    final legacy = VoiceNote.parse(fixture['legacyPrompt'] as String)!;
    expect(legacy.id, n.id);
    expect(legacy.duration, isNull);
    expect(legacy.transcript, n.transcript);
    for (final text in fixture['invalidPrompts'] as List) {
      expect(VoiceNote.parse(text as String), isNull, reason: text);
    }
    expect(VoiceNote.parse('${n.prompt}${'a' * 32000}'), isNull);
    for (final ms in [0, -1, 60001]) {
      expect(
        () => VoiceNote(
          id: n.id,
          duration: Duration(milliseconds: ms),
          transcript: 'Hi',
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'a 60-second note stops without sending or filling the text draft',
    () async {
      final h = voice.Harness();
      await h.model.refreshAvailability();
      await h.model.start(VoiceMode.note);
      await h.frames(600);
      await voice.flush();
      expect(h.model.phase, VoicePhase.preview);
      expect(h.model.pendingNote!.duration, const Duration(seconds: 60));
      expect(h.sent, isEmpty);
      expect(h.drafts, isEmpty);
      await h.close();
    },
  );

  test(
    'explicit Send ends capture and sends metadata and transcript once',
    () async {
      final h = voice.Harness();
      await h.model.refreshAvailability();
      await h.model.start(VoiceMode.note);
      await h.frames(5);
      await Future.wait([
        h.model.finishNote(send: true),
        h.model.finishNote(send: true),
      ]);
      await voice.flush();
      expect(h.sent, hasLength(1));
      final parsed = VoiceNote.parse(h.sent.single)!;
      expect(parsed.duration, const Duration(milliseconds: 500));
      expect(parsed.transcript, h.repo.transcript);
      expect(h.recorder.audio!.isClosed, isTrue);
      expect(h.drafts, isEmpty);
      expect(h.model.active, isFalse);
      expect(h.model.pendingNote, isNull);
      expect(h.model.recordedMilliseconds, 0);
      await h.close();
    },
  );

  test(
    'an unconfirmed note cannot be resubmitted or fill the composer',
    () async {
      final h = voice.Harness()..accepted = false;
      await h.model.refreshAvailability();
      await h.model.start(VoiceMode.note);
      await h.frames(5);
      await h.model.finishNote(send: true);
      await voice.flush();
      expect(h.model.noteDeliveryUnconfirmed, isTrue);
      expect(h.model.canSendNote, isFalse);
      await h.model.submitNote();
      expect(h.sent, hasLength(1));
      expect(h.drafts, isEmpty);
      await h.close();
    },
  );

  test(
    'cancelled transcription cannot submit a note or retain a transcript',
    () async {
      final h = voice.Harness();
      await h.model.refreshAvailability();
      await h.model.start(VoiceMode.note);
      await h.frames(5);
      h.repo.finish = Completer<Map<String, dynamic>>();
      await h.model.finishNote(send: true);
      await voice.flush();
      final id = h.repo.calls.first.$2['voiceId'];
      await h.model.cancel();
      h.repo.finish!.complete({
        'version': 1,
        'voiceId': id,
        'text': 'Late private words',
      });
      await voice.flush();
      expect(h.model.pendingNote, isNull);
      expect(h.model.lastTranscript, isNull);
      expect(h.model.waveform.value, isEmpty);
      expect(h.sent, isEmpty);
      expect(h.drafts, isEmpty);
      await h.close();
    },
  );

  test(
    'empty transcripts and oversized prompts never become voice messages',
    () async {
      for (final text in ['', 'a' * 32000]) {
        final h = voice.Harness()..repo.transcript = text;
        await h.model.refreshAvailability();
        await h.model.start(VoiceMode.note);
        await h.frames(5);
        await h.model.finishNote(send: true);
        await voice.flush();
        expect(h.model.error, isNotNull);
        expect(h.model.pendingNote, isNull);
        expect(h.sent, isEmpty);
        expect(h.drafts, isEmpty);
        await h.close();
      }
    },
  );

  testWidgets('voice card has no playback, and only reveals text on demand', (
    tester,
  ) async {
    final platformCalls = <MethodCall>[];
    const channel = MethodChannel('openremotecode/voice-playback');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      platformCalls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(body: VoiceNoteBubble(note: note())),
        ),
      );
      expect(find.text(note().transcript), findsNothing);
      expect(find.text('Voice message'), findsOneWidget);
      expect(find.text('0:18'), findsOneWidget);
      expect(find.text('Sent as text · Audio not saved'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.tap(find.text('Show transcript'));
      await tester.pump();
      expect(find.text(note().transcript), findsOneWidget);
      await tester.tap(find.text('Hide transcript'));
      await tester.pump();
      expect(find.text(note().transcript), findsNothing);
      await tester.pumpWidget(const SizedBox());
    }
    expect(platformCalls, isEmpty);
  });

  testWidgets(
    'a fresh chat screen recovers voice metadata from authoritative history',
    (tester) async {
      final repo = voice.ScreenRepository()..prompts.add(note().prompt);
      for (var reopen = 0; reopen < 2; reopen++) {
        await tester.pumpWidget(
          MaterialApp(
            home: ChatFlowScreen(
              repository: repo,
              connectorId: 'connector',
              connectionName: 'Computer',
              initialProject: const RemoteProject(
                '22222222-2222-4222-8222-222222222222',
                'Voice project',
                '/sample',
              ),
              initialChat: RemoteChat(
                'session_voice',
                'Voice chat',
                DateTime(2026),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Voice message'), findsOneWidget);
        expect(find.text('0:18'), findsOneWidget);
        expect(find.text(note().transcript), findsNothing);
        await tester.tap(find.text('Show transcript'));
        await tester.pump();
        expect(find.text(note().transcript), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(voice.flush);
      }
      expect(repo.prompts, hasLength(1));
      await repo.changes.close();
    },
  );

  testWidgets(
    'recording waveform reacts to speech and reduced motion stays static',
    (tester) async {
      final h = voice.Harness();
      await h.model.refreshAvailability();
      await h.model.start(VoiceMode.note);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: VoiceStatusBar(voice: h.model)),
        ),
      );
      h.recorder.frame();
      await tester.pump(const Duration(milliseconds: 150));
      expect(h.model.level.value, greaterThan(0));
      expect(h.model.waveform.value, isNotEmpty);
      final bars = find.descendant(
        of: find.byKey(const ValueKey('voice-live-waveform')),
        matching: find.byType(AnimatedContainer),
      );
      expect(
        tester
            .widgetList<AnimatedContainer>(bars)
            .any((bar) => bar.constraints!.maxHeight > 4),
        isTrue,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(body: VoiceStatusBar(voice: h.model)),
          ),
        ),
      );
      expect(
        tester
            .widgetList<AnimatedContainer>(bars)
            .every(
              (bar) =>
                  bar.constraints!.maxHeight == 4 &&
                  bar.duration == Duration.zero,
            ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    },
  );
}
