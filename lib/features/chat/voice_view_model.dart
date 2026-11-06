import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'data/chat_repository.dart';
import 'data/voice_transport.dart';
import 'domain/voice_recorder.dart';
import 'domain/voice_note.dart';
import 'data/relay_crypto.dart';

enum VoiceMode { note, call }

enum VoicePhase {
  idle,
  starting,
  listening,
  transcribing,
  preview,
  sending,
  stopping,
}

/// One foreground capture, with a bounded queue while Hex finishes a turn.
/// Partial transcriptions never become prompts. Only explicit call mode auto-sends.
final class VoiceViewModel extends ChangeNotifier {
  VoiceViewModel({
    required this.transport,
    required this.recorder,
    required this.context,
    required this.send,
    required this.appendDraft,
    this.sendNote,
    this.beforeRecording,
    this.canSubmitNote,
  });
  final VoiceTransport transport;
  final VoiceRecorder recorder;
  final VoiceContext? Function() context;
  final Future<bool> Function(String) send;
  final bool Function(String) appendDraft;
  final Future<bool> Function(VoiceNote)? sendNote;
  final Future<void> Function()? beforeRecording;
  final bool Function()? canSubmitNote;
  final level = ValueNotifier<double>(0);
  final recordedDuration = ValueNotifier<int>(0);
  final _noteAudio = BytesBuilder(copy: true);
  VoiceNote? pendingNote;
  int get recordedMilliseconds => _noteAudio.length ~/ 32;
  bool _noteAttempted = false;
  bool get noteDeliveryUnconfirmed =>
      _noteAttempted && phase == VoicePhase.preview;
  bool get canSendNote =>
      phase == VoicePhase.preview &&
      pendingNote != null &&
      !_noteAttempted &&
      available &&
      sendNote != null &&
      (canSubmitNote?.call() ?? true);
  DateTime _lastLevel = DateTime.fromMillisecondsSinceEpoch(0);
  VoicePhase phase = VoicePhase.idle;
  VoiceMode? mode;
  String? error;
  String? lastTranscript;
  bool muted = false;
  bool _disposed = false;
  int _generation = 0;
  VoiceContext? _context;
  Object? _peer;
  VoiceTurn? _turn;
  StreamSubscription<Uint8List>? _capture;
  Completer<void>? _captureDone;
  Timer? _watchdog;
  DateTime _lastAudio = DateTime.now();
  final _queue = Queue<Uint8List>();
  final _remainder = BytesBuilder(copy: true);
  int _queuedBytes = 0;
  int _turnBytes = 0;
  int _speechMs = 0;
  int _silenceMs = 0;
  bool _finishingNote = false;
  bool _stoppingNote = false;
  bool _pumping = false;
  bool _starting = false;
  Future<void>? _closing;
  bool _available = false;
  Object? _availabilityPeer;
  int _availabilityRevision = 0;
  bool _monitoring = false;
  Timer? _availabilityTimer;
  Future<void>? _availabilityCheck;

  bool get available =>
      !_disposed &&
      _available &&
      _availabilityPeer == transport.generation &&
      transport.supported &&
      transport.online;
  bool get showControls => available || active;
  bool get active => phase != VoicePhase.idle;
  bool get isCall => active && mode == VoiceMode.call;
  bool get isNote => active && mode == VoiceMode.note;
  bool get canStart =>
      !_disposed &&
      !active &&
      !_starting &&
      !_pumping &&
      available &&
      context() != null;
  String get status => switch (phase) {
    VoicePhase.idle => 'Voice ready',
    VoicePhase.starting => 'Connecting microphone…',
    VoicePhase.listening =>
      muted
          ? 'Microphone muted'
          : isCall
          ? 'Listening · speech sends after a pause'
          : 'Recording voice note · tap Stop to preview',
    VoicePhase.transcribing => 'Transcribing…',
    VoicePhase.preview => 'Voice note preview · not sent',
    VoicePhase.sending => 'Sending voice message…',
    VoicePhase.stopping => 'Ending recording…',
  };

  bool _valid(int run) =>
      !_disposed &&
      run == _generation &&
      active &&
      _context?.same(context()) == true &&
      _peer == transport.generation &&
      available;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// The screen enables polling only for a visible foreground conversation.
  void setMonitoring(bool enabled) {
    if (_disposed || enabled == _monitoring) return;
    _monitoring = enabled;
    _availabilityRevision++;
    _available = false;
    _availabilityPeer = null;
    _availabilityTimer?.cancel();
    _availabilityTimer = null;
    if (enabled) {
      _availabilityTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        unawaited(refreshAvailability());
      });
      unawaited(refreshAvailability());
    } else {
      unawaited(cancel());
    }
    _notify();
  }

  Future<void> refreshAvailability() {
    if (_disposed) return Future.value();
    if (!transport.online || !transport.supported) {
      _available = false;
      _availabilityPeer = null;
      unawaited(cancel());
      _notify();
      return Future.value();
    }
    if (_availabilityCheck case final check?) return check;
    final revision = _availabilityRevision;
    final peer = transport.generation;
    return _availabilityCheck =
        () async {
          var result = false;
          try {
            result = await transport.available();
          } catch (_) {
            // Status is advisory: fail closed, without interrupting typed chat.
          }
          if (_disposed ||
              revision != _availabilityRevision ||
              peer != transport.generation ||
              !transport.online ||
              !transport.supported) {
            return;
          }
          _available = result;
          _availabilityPeer = peer;
          if (!result) unawaited(cancel());
          _notify();
        }().whenComplete(() {
          _availabilityCheck = null;
          if (!_disposed &&
              _monitoring &&
              (revision != _availabilityRevision ||
                  peer != transport.generation)) {
            unawaited(refreshAvailability());
          }
        });
  }

  Future<void> start(VoiceMode selected) async {
    if (!canStart) return;
    _starting = true;
    final run = ++_generation;
    _context = context();
    _peer = transport.generation;
    mode = selected;
    error = lastTranscript = null;
    muted = _finishingNote = _stoppingNote = false;
    pendingNote = null;
    _noteAttempted = false;
    _noteAudio.clear();
    level.value = 0;
    recordedDuration.value = 0;
    phase = VoicePhase.starting;
    _notify();
    try {
      await beforeRecording?.call();
      if (!_valid(run)) return;
      if (!await recorder.requestPermission()) {
        throw const _VoiceFailure(
          'Allow microphone access to use voice input.',
        );
      }
      if (!_valid(run)) {
        await cancel();
        return;
      }
      await _openTurn(run);
      if (!_valid(run)) return;
      final audio = await recorder.start();
      if (!_valid(run)) {
        await recorder.stop();
        return;
      }
      _captureDone = Completer<void>();
      _capture = audio.listen(
        (bytes) => _receive(bytes, run),
        onError: (_) => unawaited(
          _fail('The microphone was interrupted. Start voice again.'),
        ),
        onDone: () {
          if (!(_captureDone?.isCompleted ?? true)) _captureDone!.complete();
          if (_valid(run) && !_stoppingNote) {
            unawaited(_fail('The microphone stopped. Start voice again.'));
          }
        },
      );
      _lastAudio = DateTime.now();
      _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!_valid(run)) {
          unawaited(cancel());
          return;
        }
        if (!muted &&
            !_stoppingNote &&
            DateTime.now().difference(_lastAudio).inSeconds >= 5) {
          unawaited(
            _fail('No microphone audio is arriving. Start voice again.'),
          );
        }
      });
      phase = VoicePhase.listening;
      _notify();
    } catch (failure) {
      if (run == _generation) await _fail(_message(failure));
    } finally {
      _starting = false;
      _notify();
    }
  }

  void contextChanged() {
    final next = context();
    // Explicit Send may create this draft's first session. No other context
    // transition is allowed to carry a recording into a different chat.
    if (isNote &&
        phase == VoicePhase.sending &&
        _context?.sessionId == null &&
        next != null &&
        next.sessionId != null &&
        next.projectId == _context?.projectId) {
      _context = next;
    }
    if (!transport.online ||
        !transport.supported ||
        (_availabilityPeer != null &&
            _availabilityPeer != transport.generation)) {
      _available = false;
      _availabilityPeer = null;
      _availabilityRevision++;
    }
    if (_monitoring && _availabilityPeer == null) {
      unawaited(refreshAvailability());
    }
    if (active && phase != VoicePhase.stopping && !_valid(_generation)) {
      unawaited(cancel());
    }
    _notify();
  }

  Future<void> _openTurn(int run) async {
    if (!_valid(run)) return;
    final turn = transport.turn(_context!);
    _turn = turn;
    _turnBytes = _speechMs = _silenceMs = 0;
    await turn.start();
    if (!_valid(run)) await turn.cancel();
  }

  void _receive(Uint8List bytes, int run) {
    if (!_valid(run) || phase == VoicePhase.stopping) return;
    _lastAudio = DateTime.now();
    if (muted) return;
    if (mode == VoiceMode.note) {
      if (bytes.length.isOdd || _noteAudio.length + bytes.length > 1920000) {
        unawaited(finishNote());
        return;
      }
      _noteAudio.add(bytes);
    }
    if (bytes.length > 160000 ||
        _queuedBytes + _remainder.length + bytes.length > 160000) {
      unawaited(
        _fail(
          'Voice could not keep up with the connection. Recording stopped.',
        ),
      );
      return;
    }
    if (DateTime.now().difference(_lastLevel).inMilliseconds >= 100 &&
        bytes.isNotEmpty) {
      final samples = ByteData.sublistView(bytes);
      var energy = 0.0;
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        final sample = samples.getInt16(i, Endian.little) / 32768;
        energy += sample * sample;
      }
      level.value = (sqrt(energy / max(1, bytes.length ~/ 2)) * 8).clamp(0, 1);
      recordedDuration.value = recordedMilliseconds;
      _lastLevel = DateTime.now();
    }
    _remainder.add(bytes);
    final data = _remainder.takeBytes();
    var offset = 0;
    while (offset + 3200 <= data.length) {
      _queue.add(Uint8List.fromList(data.sublist(offset, offset + 3200)));
      _queuedBytes += 3200;
      offset += 3200;
    }
    if (offset < data.length) _remainder.add(data.sublist(offset));
    unawaited(_pump(run));
  }

  // Measure every 100 ms frame; require 300 ms of voiced energy followed by
  // 1.5 seconds of quiet. This is a conservative pause heuristic, not semantic
  // end-of-turn detection. Ambient speech can still be transcribed in call mode.
  void _measure(Uint8List audio) {
    final data = ByteData.sublistView(audio);
    var energy = 0.0;
    for (var i = 0; i + 1 < audio.length; i += 2) {
      final sample = data.getInt16(i, Endian.little) / 32768;
      energy += sample * sample;
    }
    final ms = audio.length ~/ 32;
    final rms = sqrt(energy / max(1, audio.length ~/ 2));
    if (rms >= 0.0126) {
      // -38 dBFS.
      _speechMs += ms;
      _silenceMs = 0;
    } else {
      _silenceMs += ms;
    }
  }

  Future<void> _pump(int run) async {
    if (_pumping ||
        !_valid(run) ||
        muted ||
        (_queuedBytes < 16000 && !_finishingNote)) {
      return;
    }
    _pumping = true;
    try {
      while (_valid(run) &&
          !muted &&
          (_queuedBytes >= 16000 || (_finishingNote && _queuedBytes > 0))) {
        if (_turn == null) await _openTurn(run);
        if (!_valid(run)) return;
        final batch = BytesBuilder(copy: false);
        var boundary = false;
        while (_queue.isNotEmpty && batch.length < 16000) {
          final frame = _queue.removeFirst();
          _queuedBytes -= frame.length;
          batch.add(frame);
          _measure(frame);
          boundary =
              mode == VoiceMode.call && _speechMs >= 300 && _silenceMs >= 1500;
          if (boundary) break;
        }
        final audio = batch.takeBytes();
        _turnBytes += audio.length;
        await _turn!.append(audio);
        if (!_valid(run)) return;
        if (boundary) {
          await _finishTurn(run, autoSend: true);
        } else if (_turnBytes >= 1920000) {
          if (mode == VoiceMode.note) {
            await finishNote();
            break;
          }
          // Never split a long instruction into an automatically sent partial prompt.
          await _finishTurn(run, autoSend: false);
          if (_valid(run)) {
            await _fail('The 60-second recording was added to your draft.');
          }
          return;
        } else if (mode == VoiceMode.call &&
            _speechMs == 0 &&
            _turnBytes >= 960000) {
          // Rotate idle streams without asking the model to transcribe silence.
          await _turn!.cancel();
          _turn = null;
        }
      }
      if (_valid(run) && _finishingNote && _queuedBytes == 0) {
        await _finishTurn(run, autoSend: false);
        if (_valid(run) && mode != VoiceMode.note) await cancel();
      }
    } catch (failure) {
      if (run == _generation) await _fail(_message(failure));
    } finally {
      _pumping = false;
      _notify();
      if (_valid(run) && !muted && (_queuedBytes >= 16000 || _finishingNote)) {
        unawaited(_pump(run));
      }
    }
  }

  Future<void> _finishTurn(int run, {required bool autoSend}) async {
    final turn = _turn;
    if (turn == null || !_valid(run)) return;
    phase = VoicePhase.transcribing;
    _notify();
    final text = await turn.finish();
    if (!_valid(run)) return;
    _turn = null;
    lastTranscript = text.isEmpty ? null : text;
    if (mode == VoiceMode.note && !autoSend) {
      final audio = _noteAudio.takeBytes();
      if (text.isEmpty || audio.isEmpty) {
        await _fail('No speech was recognized. Record another voice note.');
        return;
      }
      final id = requestId();
      if (VoiceNote.formatPrompt(id, text).length > 32000) {
        await _fail('The transcript is too long. Record a shorter voice note.');
        return;
      }
      pendingNote = VoiceNote(id: id, audio: audio, transcript: text);
      _watchdog?.cancel();
      _watchdog = null;
      level.value = 0;
      phase = VoicePhase.preview;
      _finishingNote = false;
      _notify();
      return;
    }
    if (text.isNotEmpty) {
      if (autoSend) {
        phase = VoicePhase.sending;
        _notify();
        final accepted = await send(text);
        if (!_valid(run)) return;
        if (!accepted) {
          final saved = appendDraft(text);
          throw _VoiceFailure(
            saved
                ? 'Voice sending stopped. Check the chat before sending the draft again.'
                : 'Voice sending stopped and the draft is full. Check the chat before retrying.',
          );
        }
      } else {
        if (!appendDraft(text)) {
          throw const _VoiceFailure(
            'Your draft is full. Shorten it before recording another voice note.',
          );
        }
      }
    }
    phase = VoicePhase.listening;
    _notify();
  }

  Future<void> finishNote() async {
    if (!isNote || phase != VoicePhase.listening || _stoppingNote) return;
    _stoppingNote = true;
    phase = VoicePhase.transcribing;
    _notify();
    final run = _generation;
    try {
      await recorder.stop();
      if (!(_captureDone?.isCompleted ?? true)) {
        await _captureDone!.future.timeout(const Duration(seconds: 2));
      }
      if (!_valid(run)) return;
      final rest = _remainder.takeBytes();
      if (rest.length.isOdd) throw ChatFailure.invalid;
      if (rest.isNotEmpty) {
        _queue.add(rest);
        _queuedBytes += rest.length;
      }
      _finishingNote = true;
      unawaited(_pump(run));
    } catch (_) {
      if (_valid(run)) await _fail('Recording could not finish. Try again.');
    }
  }

  Future<void> submitNote() async {
    final note = pendingNote;
    if (!canSendNote || note == null || sendNote == null) return;
    final run = _generation;
    _noteAttempted = true;
    phase = VoicePhase.sending;
    _notify();
    bool accepted;
    try {
      accepted = await sendNote!(note);
    } catch (_) {
      accepted = false;
    }
    if (!_valid(run)) return;
    if (accepted) {
      await cancel();
    } else {
      phase = VoicePhase.preview;
      error = 'Delivery could not be confirmed. Check the conversation before recording again. This note will not be resent automatically.';
      _notify();
    }
  }

  Future<void> toggleMute() async {
    if (!isCall || phase != VoicePhase.listening || _pumping) return;
    muted = !muted;
    _queue.clear();
    _queuedBytes = 0;
    _remainder.clear();
    _noteAudio.clear();
    pendingNote = null;
    level.value = 0;
    final turn = _turn;
    _turn = null;
    // Muting discards the unfinished utterance and releases Hex's stream.
    if (turn != null) await turn.cancel();
    _notify();
  }

  Future<void> _fail(String message) async {
    await cancel();
    error = message;
    _notify();
  }

  void dismissError() {
    error = null;
    _notify();
  }

  Future<void> cancel() {
    if (_closing != null) return _closing!;
    if (!active) return Future.value();
    ++_generation;
    phase = VoicePhase.stopping;
    _watchdog?.cancel();
    _watchdog = null;
    _queue.clear();
    _queuedBytes = 0;
    _remainder.clear();
    _noteAudio.clear();
    pendingNote = null;
    level.value = 0;
    final turn = _turn;
    _turn = null;
    final capture = _capture;
    _capture = null;
    _notify();
    return _closing = () async {
      await capture?.cancel();
      try {
        await recorder.stop();
      } catch (_) {}
      // Local capture stops first, regardless of whether remote cleanup answers.
      if (turn != null) unawaited(turn.cancel());
      phase = VoicePhase.idle;
      mode = null;
      muted = false;
      _finishingNote = false;
      _stoppingNote = false;
      lastTranscript = null;
      _context = null;
      _peer = null;
      _closing = null;
      _notify();
    }();
  }

  static String _message(Object failure) => failure is _VoiceFailure
      ? failure.message
      : failure is ChatFailure
      ? failure.message
      : 'Voice transcription is unavailable. Check Hex on your computer.';

  @override
  void dispose() {
    _disposed = true;
    _availabilityRevision++;
    _availabilityTimer?.cancel();
    unawaited(
      cancel().then((_) => recorder.dispose()).catchError((Object _) {}),
    );
    super.dispose();
  }
}

final class _VoiceFailure implements Exception {
  const _VoiceFailure(this.message);
  final String message;
}
