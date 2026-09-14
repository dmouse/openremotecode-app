import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/connections/data/device_identity.dart';
import 'package:openremotecode/platform/remote_api.dart';
import 'package:pointycastle/export.dart';

import 'support/auth_fakes.dart';

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/pairing_v1.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final transcript = requiredMap(fixture, 'transcript');

  test('safety code matches the TypeScript protocol fixture', () {
    expect(pairingSafetyCode(transcript), fixture['safetyCode']);
    expect(
      pairingSafetyCode({...transcript, 'serviceId': 'another-origin'}),
      isNot(fixture['safetyCode']),
    );
    expect(
      pairingSafetyCode({
        ...transcript,
        'connectorIdentity': transcript['deviceIdentity'],
        'deviceIdentity': transcript['connectorIdentity'],
      }),
      isNot(fixture['safetyCode']),
    );
  });

  test(
    'P256 verifier accepts the WebCrypto proof fixture and rejects tampering',
    () {
      final public = PublicIdentity.parse(
        requiredMap(transcript, 'connectorIdentity'),
      );
      final proof = requiredMap(fixture, 'proof');
      expect(verify(public, proof), isTrue);
      expect(
        verify(public, {...proof, 'challenge': base64Url(List.filled(32, 8))}),
        isFalse,
      );
    },
  );

  test('generated device signs the versioned proof and never exports private key in public identity', () {
    final identity = generateDeviceKey(null);
    final public = PublicIdentity.parse(identity);
    final proof = signDeviceChallenge({
      'identity': identity,
      'challenge': base64Url(List.filled(32, 9)),
    });
    expect(verify(public, proof), isTrue);
    expect(public.toJson().containsKey('privateKey'), isFalse);
    expect(
      () => validateDeviceKey({
        ...identity,
        'privateKey': base64Url(List.filled(32, 0)),
      }),
      throwsA(isA<ApiException>()),
    );
    expect(
      () => PublicIdentity.parse({
        ...public.toJson(),
        'keyId': base64Url(List.filled(32, 0)),
      }),
      throwsA(isA<ApiException>()),
    );
  });

  test('private identity persists per account and corrupt storage cannot regenerate it', () async {
    final store = MemorySecureStore();
    final first = DeviceIdentityStore(store, 'https://one.test|account1');
    final second = DeviceIdentityStore(store, 'https://one.test|account2');
    final saved = await first.loadOrCreate();
    expect((await first.loadOrCreate())['identity'], saved['identity']);
    expect((await second.loadOrCreate())['identity'], isNot(saved['identity']));
    store.values[first.key] = '{}';
    await expectLater(first.loadOrCreate(), throwsA(isA<ApiException>()));
    expect(store.values[first.key], '{}');
  });
}

bool verify(PublicIdentity public, Map<String, dynamic> proof) {
  final domain = ECDomainParameters('prime256v1');
  final signer = ECDSASigner(SHA256Digest())
    ..init(
      false,
      PublicKeyParameter(
        ECPublicKey(
          domain.curve.decodePoint(decodeUrl(public.publicKey)),
          domain,
        ),
      ),
    );
  final raw = decodeUrl(proof['signature'] as String);
  BigInt integer(List<int> bytes) => BigInt.parse(
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    radix: 16,
  );
  return signer.verifySignature(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode([
          'opencode-remote/identity-proof/v1',
          proof['challenge'],
          ...public.tuple,
        ]),
      ),
    ),
    ECSignature(integer(raw.sublist(0, 32)), integer(raw.sublist(32))),
  );
}
