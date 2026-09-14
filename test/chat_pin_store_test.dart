import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/data/chat_pin_store.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';

import 'support/auth_fakes.dart';

void main() {
  test(
    'pins persist with account, server, connector, peer and folder isolation',
    () async {
      final secure = MemorySecureStore();
      final store = ChatPinStore(secure, 'server|account');
      await store.set('connector', 'peer', '/work/app', 'ses_main', true);
      final restored = ChatPinStore(secure, 'server|account');
      expect(await restored.read('connector', 'peer', '/work/app'), {
        'ses_main',
      });
      for (final scope in ['other-server|account', 'server|other-account']) {
        expect(
          await ChatPinStore(
            secure,
            scope,
          ).read('connector', 'peer', '/work/app'),
          isEmpty,
        );
      }
      expect(
        await restored.read('other-connector', 'peer', '/work/app'),
        isEmpty,
      );
      expect(
        await restored.read('connector', 'new-peer', '/work/app'),
        isEmpty,
      );
      expect(await restored.read('connector', 'peer', '/work/other'), isEmpty);
      expect(secure.values.toString(), isNot(contains('/work/app')));
      await restored.set('connector', 'peer', '/work/app', 'ses_main', false);
      expect(secure.values, isEmpty);
    },
  );

  test(
    'pin writes serialize and a failed save does not erase existing pins',
    () async {
      final secure = MemorySecureStore();
      final store = ChatPinStore(secure, 'scope');
      await Future.wait([
        store.set('c', 'k', '/p', 'a', true),
        store.set('c', 'k', '/p', 'b', true),
      ]);
      secure.failWrite = true;
      await expectLater(
        store.set('c', 'k', '/p', 'a', false),
        throwsA(ChatFailure.pinStorage),
      );
      secure.failWrite = false;
      expect(await store.read('c', 'k', '/p'), {'a', 'b'});
      await store.set('c', 'k', '/p', 'a', false);
      expect(await store.read('c', 'k', '/p'), {'b'});
    },
  );

  test(
    'pin limits and malformed storage fail without overwriting data',
    () async {
      final secure = MemorySecureStore();
      final store = ChatPinStore(secure, 'scope');
      for (var i = 0; i < 20; i++) {
        await store.set('c', 'k', '/p', 'ses_$i', true);
      }
      await expectLater(
        store.set('c', 'k', '/p', 'ses_overflow', true),
        throwsA(ChatFailure.pinLimit),
      );
      expect((await store.read('c', 'k', '/p')).length, 20);
      final key = secure.values.keys.single;
      secure.values[key] = '{invalid';
      await expectLater(
        store.set('c', 'k', '/p', 'ses_0', false),
        throwsA(ChatFailure.pinStorage),
      );
      expect(secure.values[key], '{invalid');
    },
  );
}
