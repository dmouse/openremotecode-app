import 'dart:convert';
import 'dart:typed_data';

import 'chat_repository.dart';
import 'relay_crypto.dart';

const voiceOperations = [
  'voice.status',
  'voice.start',
  'voice.audio',
  'voice.finish',
  'voice.cancel',
];

final class VoiceContext {
  const VoiceContext(this.projectId, this.composerKey, this.sessionId);
  final String projectId, composerKey;
  final String? sessionId;
  bool same(VoiceContext? other) =>
      other != null &&
      projectId == other.projectId &&
      composerKey == other.composerKey &&
      sessionId == other.sessionId;
}

final class VoiceTransport {
  VoiceTransport(this.repository, this.connectorId);
  final ChatRepository repository;
  final String connectorId;
  bool get supported =>
      voiceOperations.every((op) => repository.chatSupports(connectorId, op));
  bool get online =>
      repository.chatOnline(connectorId) && repository.chatTrusted(connectorId);
  Object get generation => repository.chatConnectionGeneration(connectorId);
  Future<bool> available() async {
    if (!supported || !online) return false;
    final peer = generation;
    final response = await repository.chatRequest(
      connectorId,
      'voice.status',
      const {},
    );
    if (!online || peer != generation) return false;
    if (response.length != 2 ||
        response['version'] != 1 ||
        response['available'] is! bool) {
      throw ChatFailure.invalid;
    }
    return response['available'] as bool;
  }

  VoiceTurn turn(VoiceContext context) => VoiceTurn(this, context);
}

final class VoiceTurn {
  VoiceTurn(this.transport, this.context) : generation = transport.generation;
  final VoiceTransport transport;
  final VoiceContext context;
  final Object generation;
  final String id = requestId();
  int _sequence = 0;
  bool _cancelled = false;
  bool get current =>
      !_cancelled && transport.online && generation == transport.generation;

  Future<Map<String, dynamic>> _request(
    String op, [
    Map<String, dynamic> body = const {},
  ]) async {
    if (!current) throw ChatFailure.offline;
    final result = await transport.repository.chatRequest(
      transport.connectorId,
      op,
      {'voiceId': id, ...body},
    );
    if (!current) throw ChatFailure.offline;
    if (result['version'] != 1 || result['voiceId'] != id) {
      throw ChatFailure.invalid;
    }
    return result;
  }

  Future<void> start() async {
    try {
      final response = await _request('voice.start', {
        'projectId': context.projectId,
        if (context.sessionId != null) 'sessionId': context.sessionId,
      });
      if (response.length != 6 ||
          response['sampleRate'] != 16000 ||
          response['sampleFormat'] != 's16le' ||
          response['maxChunkBytes'] != 16000 ||
          response['maxDurationMs'] != 60000) {
        throw ChatFailure.invalid;
      }
    } catch (_) {
      // A start may complete after local cancellation. Cancel again when it settles.
      await cancel();
      rethrow;
    }
  }

  Future<void> append(Uint8List audio) async {
    if (audio.isEmpty || audio.length > 16000 || audio.length.isOdd) {
      throw ChatFailure.invalid;
    }
    final sequence = _sequence++;
    final response = await _request('voice.audio', {
      'sequence': sequence,
      'audio': base64UrlEncode(audio).replaceAll('=', ''),
    });
    if (response.length != 3 || response['sequence'] != sequence) {
      throw ChatFailure.invalid;
    }
  }

  Future<String> finish() async {
    final response = await _request('voice.finish');
    final text = response['text'];
    if (response.length != 3 || text is! String || text.length > 32000) {
      throw ChatFailure.invalid;
    }
    return text.trim();
  }

  Future<void> cancel() async {
    _cancelled = true;
    if (!transport.online || generation != transport.generation) return;
    try {
      await transport.repository.chatRequest(
        transport.connectorId,
        'voice.cancel',
        {'voiceId': id},
      );
    } catch (_) {
      /* The connector and Hex also expire abandoned streams. */
    }
  }
}
