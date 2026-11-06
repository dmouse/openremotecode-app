import 'dart:async';

import 'package:flutter/foundation.dart';

import 'domain/voice_audio_player.dart';
import 'domain/voice_note.dart';

/// One foreground player shared by previews and history. No autoplay or disk cache.
final class VoicePlaybackViewModel extends ChangeNotifier {
  VoicePlaybackViewModel(this.player, {this.allowPlayback});
  final bool Function()? allowPlayback;
  bool get canPlay => !_disposed && (allowPlayback?.call() ?? true);
  final VoiceAudioPlayer player;
  String? id, error;
  bool playing = false, busy = false, _disposed = false;
  bool _paused = false;
  int position = 0, _generation = 0;
  Timer? _timer;
  Future<void> _operations = Future.value();
  Future<void> toggle(VoiceNote note) async {
    if (!canPlay || busy) return;
    final generation = _generation;
    busy = true;
    error = null;
    notifyListeners();
    final operation = _operations.then((_) async {
      if (_disposed || generation != _generation) return;
      if (id == note.id && playing) {
        await player.pause();
        if (_disposed || generation != _generation) return;
        playing = false;
        _paused = true;
      } else if (id == note.id && _paused) {
        await player.resume();
        if (_disposed || generation != _generation) return;
        playing = true;
        _paused = false;
      } else {
        await player.stop();
        if (_disposed || generation != _generation) return;
        await player.play(note.audio);
        if (_disposed || generation != _generation) return;
        id = note.id;
        position = 0;
        playing = true;
        _paused = false;
      }
      if (generation != _generation || _disposed) return;
      _timer?.cancel();
      if (playing) {
        _timer = Timer.periodic(
          const Duration(milliseconds: 250),
          (_) => unawaited(_poll(generation)),
        );
      }
    });
    _operations = operation.catchError((Object _) {});
    try {
      await operation;
    } catch (_) {
      error = 'Audio playback is unavailable.';
    }
    busy = false;
    if (!_disposed) notifyListeners();
  }

  bool _polling = false;
  Future<void> _poll(int generation) async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      final state = await player.state();
      if (_disposed || generation != _generation) return;
      position = state.milliseconds;
      playing = state.playing;
      if (!playing) _timer?.cancel();
      notifyListeners();
    } catch (_) {
      await stop();
    } finally {
      _polling = false;
    }
  }

  Future<void> stop() {
    ++_generation;
    _timer?.cancel();
    id = null;
    playing = false;
    _paused = false;
    position = 0;
    if (!_disposed) notifyListeners();
    final operation = _operations.then((_) => player.stop());
    _operations = operation.catchError((Object _) {});
    return _operations;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
