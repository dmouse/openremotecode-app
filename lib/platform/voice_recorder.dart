import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../features/chat/domain/voice_recorder.dart';

final class NativeVoiceRecorder implements VoiceRecorder {
  AudioRecorder? _instance;
  AudioRecorder get _recorder => _instance ??= AudioRecorder();
  StreamSubscription<RecordState>? _states;
  StreamSubscription<Uint8List>? _audio;
  StreamController<Uint8List>? _output;
  bool _stopping = false;

  @override
  Future<bool> requestPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() async {
    _stopping = false;
    final output = StreamController<Uint8List>();
    _output = output;
    void fail() {
      if (!_stopping && !output.isClosed) {
        output.addError(StateError('Microphone interrupted'));
      }
    }

    await _recorder.setOnConfigChanged((config) {
      if (config.sampleRate != 16000 ||
          config.numChannels != 1 ||
          config.encoder != AudioEncoder.pcm16bits) {
        fail();
      }
    });
    _states = _recorder.onStateChanged().listen((state) {
      if (state == RecordState.pause || state == RecordState.stop) fail();
    }, onError: (_) => fail());
    try {
      final audio = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          streamBufferSize: 3200,
          echoCancel: true,
          noiseSuppress: true,
          audioInterruption: AudioInterruptionMode.pause,
        ),
      );
      _audio = audio.listen(
        output.add,
        onError: (_) => fail(),
        onDone: () {
          if (!output.isClosed) unawaited(output.close());
        },
      );
      return output.stream;
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (_instance == null) return;
    _stopping = true;
    await _states?.cancel();
    _states = null;
    try {
      await _recorder.stop();
    } finally {
      await _audio?.cancel();
      _audio = null;
      final output = _output;
      _output = null;
      if (output != null && !output.isClosed) unawaited(output.close());
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await stop();
    } finally {
      await _instance?.dispose();
    }
  }
}
