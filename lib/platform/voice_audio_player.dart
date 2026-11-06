import 'package:flutter/services.dart';

import '../features/chat/domain/voice_audio_player.dart';

/// Only bounded PCM bytes cross this channel. No file paths or URLs are accepted.
final class NativeVoiceAudioPlayer implements VoiceAudioPlayer {
  static const _channel = MethodChannel('openremotecode/voice-playback');
  @override
  Future<void> play(Uint8List pcm) async {
    if (pcm.isEmpty || pcm.length.isOdd || pcm.length > 1920000) {
      throw const FormatException();
    }
    await _channel.invokeMethod<void>('play', pcm);
  }

  @override
  Future<void> pause() => _channel.invokeMethod<void>('pause');
  @override
  Future<void> resume() => _channel.invokeMethod<void>('resume');
  @override
  Future<void> stop() => _channel.invokeMethod<void>('stop');
  @override
  Future<({int milliseconds, bool playing})> state() async {
    final state = await _channel.invokeMapMethod<String, dynamic>('state');
    return (
      milliseconds: state?['milliseconds'] as int? ?? 0,
      playing: state?['playing'] == true,
    );
  }
}
