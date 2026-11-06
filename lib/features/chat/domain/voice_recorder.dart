import 'dart:typed_data';

/// Foreground microphone capture. PCM16, little endian, mono, exactly 16 kHz.
/// Implementations never persist audio and report interruptions as stream errors.
abstract interface class VoiceRecorder {
  Future<bool> requestPermission();
  Future<Stream<Uint8List>> start();
  Future<void> stop();
  Future<void> dispose();
}
