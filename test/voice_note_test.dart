import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/domain/voice_note.dart';
import 'package:openremotecode/features/chat/domain/voice_audio_player.dart';
import 'package:openremotecode/features/chat/ui/voice_note_bubble.dart';
import 'package:openremotecode/features/chat/voice_playback_view_model.dart';
import 'package:openremotecode/features/chat/voice_view_model.dart';
import 'package:openremotecode/platform/voice_audio_player.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

import 'voice_test.dart' as voice;

class Player implements VoiceAudioPlayer {
  final calls = <String>[];
  Completer<void>? starting;
  @override
  Future<void> play(Uint8List pcm) async {
    calls.add('play');
    await starting?.future;
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
  }

  @override
  Future<void> resume() async {
    calls.add('resume');
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
  }

  @override
  Future<({int milliseconds, bool playing})> state() async =>
      (milliseconds: 100, playing: true);
}

VoiceNote note([String id = '11111111-1111-4111-8111-111111111111']) =>
    VoiceNote(id: id, audio: Uint8List(32000), transcript: 'Do the next task.');

void main() {
  test(
    'a 60-second note stops in preview without becoming a prompt or text draft',
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
  test('playback is blocked during microphone capture', () async {
    final native = Player();
    var allowed = false;
    final player = VoicePlaybackViewModel(native, allowPlayback: () => allowed);
    await player.toggle(note());
    expect(native.calls, isEmpty);
    allowed = true;
    await player.toggle(note());
    expect(player.playing, isTrue);
    await player.stop();
    player.dispose();
  });
  test(
    'marker round-trips text and malformed/unbounded markers stay literal',
    () {
      final n = note();
      expect(VoiceNote.parse(n.prompt), (id: n.id, transcript: n.transcript));
      for (final text in [
        'not a note',
        '[Open Remote Code voice note v1: ------------------------------------]\nhello',
        '[Open Remote Code voice note v2: ${n.id}]\nhello',
        '[Open Remote Code voice note v1: ${n.id}]\n',
        '[Open Remote Code voice note v1: ${n.id}]\n${'a' * 32000}',
      ]) {
        expect(VoiceNote.parse(text), isNull);
      }
    },
  );
  test(
    'audio memory is bounded and isolated by connector, project and session',
    () {
      final memory = VoiceNoteMemory();
      final first = note('99999999-9999-4999-8999-999999999999');
      memory.add('a', '/project', 'session', first);
      expect(memory.find('a', '/project', 'session', first.id), same(first));
      expect(memory.find('b', '/project', 'session', first.id), isNull);
      expect(memory.find('a', '/other', 'session', first.id), isNull);
      expect(memory.find('a', '/project', 'other', first.id), isNull);
      for (var i = 0; i < 8; i++) {
        memory.add(
          'a',
          '/project',
          'session',
          note('11111111-1111-4111-8111-11111111111$i'),
        );
      }
      expect(memory.find('a', '/project', 'session', first.id), isNull);
      memory.clear(connector: 'a');
      expect(
        memory.find(
          'a',
          '/project',
          'session',
          '11111111-1111-4111-8111-111111111117',
        ),
        isNull,
      );
    },
  );
  test(
    'an unconfirmed note cannot be resubmitted and never fills the composer',
    () async {
      final h = voice.Harness()..accepted = false;
      await h.model.refreshAvailability();
      await h.model.start(VoiceMode.note);
      await h.frames(5);
      await h.model.finishNote();
      await voice.flush();
      await h.model.submitNote();
      expect(h.model.noteDeliveryUnconfirmed, isTrue);
      expect(h.model.canSendNote, isFalse);
      await h.model.submitNote();
      expect(h.sent, hasLength(1));
      expect(h.drafts, isEmpty);
      await h.model.cancel();
      expect(h.model.pendingNote, isNull);
      await h.close();
    },
  );
  test(
    'cancelled transcription cannot create a preview or submit a note',
    () async {
      final h = voice.Harness();
      await h.model.refreshAvailability();
      await h.model.start(VoiceMode.note);
      await h.frames(5);
      h.repo.finish = Completer<Map<String, dynamic>>();
      await h.model.finishNote();
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
      expect(h.sent, isEmpty);
      expect(h.drafts, isEmpty);
      await h.close();
    },
  );
  test(
    'play, pause and resume serialize, and a stop invalidates pending playback',
    () async {
      final native = Player();
      final player = VoicePlaybackViewModel(native);
      await player.toggle(note());
      await player.toggle(note());
      await player.toggle(note());
      expect(native.calls, ['stop', 'play', 'pause', 'resume']);
      await player.stop();
      native.starting = Completer<void>();
      final starting = player.toggle(note());
      await voice.flush();
      final stopping = player.stop();
      native.starting!.complete();
      await Future.wait([starting, stopping]);
      expect(player.playing, isFalse);
      expect(player.id, isNull);
      expect(native.calls.last, 'stop');
      player.dispose();
    },
  );
  testWidgets(
    'Transcribe only reveals text and a restarted client has no playback',
    (tester) async {
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(
              body: VoiceNoteBubble(transcript: 'Private transcript'),
            ),
          ),
        );
        expect(find.text('Private transcript'), findsNothing);
        expect(find.text('Audio unavailable on this device'), findsOneWidget);
        expect(
          tester.widget<IconButton>(find.byType(IconButton)).onPressed,
          isNull,
        );
        await tester.tap(find.text('Transcribe'));
        await tester.pump();
        expect(find.text('Private transcript'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets(
    'native playback accepts only bounded bytes, never file paths or URLs',
    (tester) async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('openremotecode/voice-playback');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      final player = NativeVoiceAudioPlayer();
      await player.play(Uint8List(320));
      expect(calls.single.method, 'play');
      expect(calls.single.arguments, isA<Uint8List>());
      await expectLater(player.play(Uint8List(1920002)), throwsFormatException);
      await expectLater(player.play(Uint8List(3)), throwsFormatException);
      expect(calls, hasLength(1));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    },
  );
}
