import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import '../../../platform/remote_api.dart';
import '../../../platform/secure_store.dart';

const identitySuite = 'HPKE-Auth-P256-HKDF-SHA256-AES-256-GCM';
String base64Url(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');
Uint8List decodeUrl(String value) =>
    base64UrlCodec.decode(base64UrlCodec.normalize(value));
const base64UrlCodec = Base64Codec.urlSafe();

final class PublicIdentity {
  const PublicIdentity({required this.keyId, required this.publicKey});
  final String keyId;
  final String publicKey;

  factory PublicIdentity.parse(Map<String, dynamic> json) {
    final keyId = requiredString(json, 'keyId', max: 43);
    final publicKey = requiredString(json, 'publicKey', max: 87);
    if (json['version'] != 1 ||
        json['suite'] != identitySuite ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(keyId) ||
        !RegExp(r'^[A-Za-z0-9_-]{87}$').hasMatch(publicKey)) {
      throw const ApiException(0, 'invalid_response');
    }
    final raw = decodeUrl(publicKey);
    if (raw.length != 65 ||
        raw.first != 4 ||
        base64Url(raw) != publicKey ||
        base64Url(sha256.convert(raw).bytes) != keyId) {
      throw const ApiException(0, 'invalid_response');
    }
    final curve = ECDomainParameters('prime256v1').curve;
    final point = curve.decodePoint(raw);
    if (point == null ||
        point.isInfinity ||
        point.y!.square() !=
            point.x!.square() * point.x! + curve.a! * point.x! + curve.b!) {
      throw const ApiException(0, 'invalid_response');
    }
    return PublicIdentity(keyId: keyId, publicKey: publicKey);
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'suite': identitySuite,
    'keyId': keyId,
    'publicKey': publicKey,
  };
  List<Object> get tuple => [1, identitySuite, keyId, publicKey];
  bool matches(PublicIdentity other) =>
      keyId == other.keyId && publicKey == other.publicKey;
}

final class DeviceIdentityStore {
  DeviceIdentityStore(this.store, this.scope);
  final SecureStore store;
  final String scope;
  String get key => 'device_v1_${sha256.convert(utf8.encode(scope))}';

  Future<Map<String, dynamic>> loadOrCreate() async {
    String? existing;
    try {
      existing = await store.read(key);
    } catch (_) {
      throw const ApiException(0, 'secure_storage');
    }
    if (existing != null) {
      final record = jsonDecode(existing) as Map<String, dynamic>;
      if (record['version'] != 1 ||
          record['scope'] != scope ||
          record['bindings'] is! Map<String, dynamic>) {
        throw const ApiException(0, 'secure_storage');
      }
      await compute(validateDeviceKey, requiredMap(record, 'identity'));
      return record;
    }
    final identity = await compute(generateDeviceKey, null);
    final record = <String, dynamic>{
      'version': 1,
      'scope': scope,
      'identity': identity,
      'bindings': <String, dynamic>{},
    };
    await save(record);
    return record;
  }

  Future<void> save(Map<String, dynamic> record) async {
    try {
      await store.write(key, jsonEncode(record));
    } catch (_) {
      throw const ApiException(0, 'secure_storage');
    }
  }
}

Map<String, dynamic> generateDeviceKey(void _) {
  final random = Random.secure();
  final seed = Uint8List.fromList(
    List.generate(32, (_) => random.nextInt(256)),
  );
  final secureRandom = FortunaRandom()..seed(KeyParameter(seed));
  seed.fillRange(0, seed.length, 0);
  final generator = ECKeyGenerator()
    ..init(
      ParametersWithRandom(
        ECKeyGeneratorParameters(ECDomainParameters('prime256v1')),
        secureRandom,
      ),
    );
  final keys = generator.generateKeyPair();
  final public = (keys.publicKey).Q!.getEncoded(false);
  return {
    'version': 1,
    'suite': identitySuite,
    'keyId': base64Url(sha256.convert(public).bytes),
    'publicKey': base64Url(public),
    'privateKey': base64Url(_integerBytes((keys.privateKey).d!)),
  };
}

void validateDeviceKey(Map<String, dynamic> identity) {
  final public = PublicIdentity.parse(identity);
  final bytes = decodeUrl(requiredString(identity, 'privateKey', max: 43));
  if (bytes.length != 32) throw const ApiException(0, 'secure_storage');
  final d = _integer(bytes);
  final domain = ECDomainParameters('prime256v1');
  if (d <= BigInt.zero ||
      d >= domain.n ||
      base64Url((domain.G * d)!.getEncoded(false)) != public.publicKey) {
    throw const ApiException(0, 'secure_storage');
  }
}

Map<String, Object> signDeviceChallenge(Map<String, dynamic> input) {
  final identity = requiredMap(input, 'identity');
  validateDeviceKey(identity);
  final challenge = requiredString(input, 'challenge', max: 43);
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(challenge)) {
    throw const ApiException(0, 'invalid_response');
  }
  final public = PublicIdentity.parse(identity);
  final message = utf8.encode(
    jsonEncode([
      'opencode-remote/identity-proof/v1',
      challenge,
      ...public.tuple,
    ]),
  );
  final private = ECPrivateKey(
    _integer(decodeUrl(identity['privateKey'] as String)),
    ECDomainParameters('prime256v1'),
  );
  final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
    ..init(true, PrivateKeyParameter<ECPrivateKey>(private));
  final signature =
      signer.generateSignature(Uint8List.fromList(message)) as ECSignature;
  return {
    'challenge': challenge,
    'signature': base64Url([
      ..._integerBytes(signature.r),
      ..._integerBytes(signature.s),
    ]),
  };
}

String pairingSafetyCode(Map<String, dynamic> transcript) {
  if (transcript['version'] != 1) {
    throw const ApiException(0, 'invalid_response');
  }
  final connector = PublicIdentity.parse(
    requiredMap(transcript, 'connectorIdentity'),
  );
  final device = PublicIdentity.parse(
    requiredMap(transcript, 'deviceIdentity'),
  );
  final message = jsonEncode([
    'opencode-remote/pairing-safety/v1',
    1,
    requiredString(transcript, 'serviceId', max: 128),
    requiredString(transcript, 'pairingId', max: 64),
    connector.tuple,
    device.tuple,
  ]);
  final hex = sha256
      .convert(utf8.encode(message))
      .toString()
      .substring(0, 24)
      .toUpperCase();
  return [for (var i = 0; i < 24; i += 4) hex.substring(i, i + 4)].join(' ');
}

BigInt _integer(List<int> bytes) => BigInt.parse(
  bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
  radix: 16,
);
Uint8List _integerBytes(BigInt value) {
  final hex = value.toRadixString(16).padLeft(64, '0');
  return Uint8List.fromList([
    for (var i = 0; i < 64; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}
