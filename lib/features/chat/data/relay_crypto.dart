import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../connections/data/device_identity.dart';

const relayProtocolVersion = 2;

String relayNonce() {
  final random = Random.secure();
  return base64Url(List.generate(16, (_) => random.nextInt(256)));
}

/// Mirrors `deriveRelayEpoch` in @openremotecode/protocol; the transcript is
/// role-ordered so both peers derive the same value from the same two nonces.
String deriveRelayEpoch({
  required String connectorKeyId,
  required String connectorNonce,
  required String clientKeyId,
  required String clientNonce,
}) {
  if (!_nonce.hasMatch(connectorNonce) || !_nonce.hasMatch(clientNonce)) {
    throw const FormatException();
  }
  final transcript = jsonEncode([
    'opencode-remote-relay-epoch',
    relayProtocolVersion,
    connectorKeyId,
    connectorNonce,
    clientKeyId,
    clientNonce,
  ]);
  return base64Url(sha256.convert(utf8.encode(transcript)).bytes);
}

/// Events the connector may push. An operation missing here is dropped before it is ever
/// decrypted into anything the UI can see, so a new event type must be added in both this
/// list and the dispatch gate in chat_repository.dart.
const connectorEventOperations = {
  'project.mcp.updated',
  'chat.stream.updated',
  'chat.stream.closed',
  'connector.credential.updated',
};

final _nonce = RegExp(r'^[A-Za-z0-9_-]{22}$');
final _epoch = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// Sliding anti-replay window over one peer's sequence numbers within an epoch,
/// mirroring `ReplayWindow` in @openremotecode/protocol.
final class ReplayWindow {
  ReplayWindow([this.size = 1024]) : _bits = Uint32List(size ~/ 32);
  final int size;
  final Uint32List _bits;
  int _highest = -1;

  bool accept(int sequence) {
    if (sequence < 0 || sequence > 9007199254740991) return false;
    if (sequence > _highest) {
      if (_highest >= 0) _shift(sequence - _highest);
      _highest = sequence;
      _mark(0);
      return true;
    }
    final offset = _highest - sequence;
    if (offset >= size || _marked(offset)) return false;
    _mark(offset);
    return true;
  }

  void _mark(int offset) => _bits[offset >> 5] |= 1 << (offset & 31);
  bool _marked(int offset) => _bits[offset >> 5] & (1 << (offset & 31)) != 0;

  void _shift(int distance) {
    if (distance >= size) {
      _bits.fillRange(0, _bits.length, 0);
      return;
    }
    final words = distance ~/ 32;
    final bits = distance % 32;
    for (var index = _bits.length - 1; index >= 0; index--) {
      final high = index - words >= 0 ? _bits[index - words] : 0;
      if (bits == 0) {
        _bits[index] = high;
        continue;
      }
      final low = index - words - 1 >= 0 ? _bits[index - words - 1] : 0;
      _bits[index] = (high << bits) | (low >> (32 - bits));
    }
  }
}

String requestId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

abstract interface class RelayCrypto {
  Future<Map<String, dynamic>> seal(
    Map<String, dynamic> own,
    PublicIdentity peer,
    Map<String, dynamic> payload,
    String epoch,
    int sequence,
  );
  Future<Map<String, dynamic>> open(
    Map<String, dynamic> own,
    PublicIdentity peer,
    Map<String, dynamic> envelope,
    String epoch,
  );
}

final class NativeRelayCrypto implements RelayCrypto {
  const NativeRelayCrypto();
  static const channel = MethodChannel('openremotecode/hpke');

  @override
  Future<Map<String, dynamic>> seal(
    Map<String, dynamic> own,
    PublicIdentity peer,
    Map<String, dynamic> payload,
    String epoch,
    int sequence,
  ) async {
    if (!_epoch.hasMatch(epoch)) throw const FormatException();
    final header = <String, dynamic>{
      'protocolVersion': relayProtocolVersion,
      'type': 'relay.envelope',
      'messageId': requestId(),
      'senderKeyId': own['keyId'],
      'recipientKeyId': peer.keyId,
      'epoch': epoch,
      'sequence': sequence,
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
      'suite': identitySuite,
    };
    final sealed = await channel.invokeMapMethod<String, dynamic>('seal', {
      ..._keys(own, peer),
      'aad': _aad(header),
      'content': Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    });
    if (sealed == null) throw const FormatException();
    return {
      ...header,
      'encapsulatedKey': base64Url(sealed['enc'] as Uint8List),
      'ciphertext': base64Url(sealed['ciphertext'] as Uint8List),
    };
  }

  @override
  Future<Map<String, dynamic>> open(
    Map<String, dynamic> own,
    PublicIdentity peer,
    Map<String, dynamic> envelope,
    String epoch,
  ) async {
    validateEnvelope(envelope, own['keyId'] as String, peer.keyId, epoch);
    final opened = await channel.invokeMethod<Uint8List>('open', {
      ..._keys(own, peer),
      'aad': _aad(envelope),
      'enc': decodeUrl(envelope['encapsulatedKey'] as String),
      'content': decodeUrl(envelope['ciphertext'] as String),
    });
    if (opened == null || opened.length > 1000000) {
      throw const FormatException();
    }
    final payload = jsonDecode(utf8.decode(opened)) as Map<String, dynamic>;
    if (payload.length != 6 ||
        payload['protocolVersion'] != relayProtocolVersion ||
        (payload['kind'] != 'response' &&
            !(payload['kind'] == 'event' &&
                connectorEventOperations.contains(payload['operation']))) ||
        payload['requestId'] is! String ||
        !_uuid.hasMatch(payload['requestId'] as String) ||
        payload['operation'] is! String ||
        (payload['operation'] as String).length > 64 ||
        !_safeInteger(payload['sentAt']) ||
        payload['body'] is! Map<String, dynamic>) {
      throw const FormatException();
    }
    return payload;
  }

  static Map<String, Object> _keys(
    Map<String, dynamic> own,
    PublicIdentity peer,
  ) => {
    'privateKey': decodeUrl(own['privateKey'] as String),
    'publicKey': decodeUrl(own['publicKey'] as String),
    'peerKey': decodeUrl(peer.publicKey),
  };
  static Uint8List _aad(Map<String, dynamic> header) => Uint8List.fromList(
    utf8.encode(
      jsonEncode([
        'opencode-remote-relay',
        header['protocolVersion'],
        header['type'],
        header['messageId'],
        header['senderKeyId'],
        header['recipientKeyId'],
        header['epoch'],
        header['sequence'],
        header['expiresAt'],
        header['suite'],
      ]),
    ),
  );
}

final _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
bool _safeInteger(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991;

void validateEnvelope(
  Map<String, dynamic> value,
  String recipient,
  String sender,
  String epoch,
) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (value.length != 11 ||
      value['protocolVersion'] != relayProtocolVersion ||
      value['type'] != 'relay.envelope' ||
      value['suite'] != identitySuite ||
      value['recipientKeyId'] != recipient ||
      value['senderKeyId'] != sender ||
      value['epoch'] != epoch ||
      !_epoch.hasMatch(epoch) ||
      value['messageId'] is! String ||
      !_uuid.hasMatch(value['messageId'] as String) ||
      !_safeInteger(value['sequence']) ||
      !_safeInteger(value['expiresAt']) ||
      (value['expiresAt'] as int) <= now ||
      (value['expiresAt'] as int) > now + 300000) {
    throw const FormatException();
  }
  for (final field in ['encapsulatedKey', 'ciphertext']) {
    final encoded = value[field];
    if (encoded is! String ||
        encoded.isEmpty ||
        encoded.length > (field == 'ciphertext' ? 1500000 : 256) ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded) ||
        base64Url(decodeUrl(encoded)) != encoded) {
      throw const FormatException();
    }
  }
  if (decodeUrl(value['encapsulatedKey'] as String).length != 65) {
    throw const FormatException();
  }
}
