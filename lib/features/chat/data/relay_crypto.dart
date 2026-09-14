import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import '../../connections/data/device_identity.dart';

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
    int sequence,
  );
  Future<Map<String, dynamic>> open(
    Map<String, dynamic> own,
    PublicIdentity peer,
    Map<String, dynamic> envelope,
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
    int sequence,
  ) async {
    final header = <String, dynamic>{
      'protocolVersion': 1,
      'type': 'relay.envelope',
      'messageId': requestId(),
      'senderKeyId': own['keyId'],
      'recipientKeyId': peer.keyId,
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
  ) async {
    validateEnvelope(envelope, own['keyId'] as String, peer.keyId);
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
        payload['protocolVersion'] != 1 ||
        (payload['kind'] != 'response' &&
            !(payload['kind'] == 'event' &&
                [
                  'project.mcp.updated',
                  'chat.stream.updated',
                  'chat.stream.closed',
                ].contains(payload['operation']))) ||
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
) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (value.length != 10 ||
      value['protocolVersion'] != 1 ||
      value['type'] != 'relay.envelope' ||
      value['suite'] != identitySuite ||
      value['recipientKeyId'] != recipient ||
      value['senderKeyId'] != sender ||
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
