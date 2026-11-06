import 'dart:typed_data';

abstract interface class VoiceAudioPlayer {
  Future<void> play(Uint8List pcm);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<({int milliseconds, bool playing})> state();
}
