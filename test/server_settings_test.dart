import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/features/server_settings/server_settings_view_model.dart';

import 'support/memory_server_settings_repository.dart';

void main() {
  for (final host in ['127.0.0.1', 'localhost', '[::1]']) {
    test('HTTP on $host requires the explicit local-testing policy', () {
      final address = 'http://$host:8080';
      expect(() => ServerEndpoint.parse(address), throwsFormatException);
      expect(
        ServerEndpoint.parse(address, allowLoopbackHttp: true).toString(),
        address,
      );
    });
  }

  test('local-testing policy rejects non-loopback hosts and URL disguises', () {
    for (final address in [
      'http://remote.example.com',
      'http://192.168.1.10:8080',
      'http://0.0.0.0:8080',
      'http://127.0.0.1.example.com:8080',
      'http://localhost.example.com:8080',
      'http://127.0.0.1@remote.example.com:8080',
      'http://user@127.0.0.1:8080',
      'http://127.0.0.1:8080/api',
      'http://127.0.0.1:8080?token=secret',
      'http://127.0.0.1:8080#fragment',
      'http://%31%32%37.0.0.1:8080',
    ]) {
      expect(
        () => ServerEndpoint.parse(address, allowLoopbackHttp: true),
        throwsFormatException,
        reason: address,
      );
    }
  });

  test(
    'local HTTP validates, saves and restores only with the debug policy',
    () async {
      const address = 'http://127.0.0.1:8080';
      final repository = MemoryServerSettingsRepository();
      final debug = ServerSettingsViewModel(
        repository,
        defaultServer: address,
        allowLoopbackHttp: true,
      );
      addTearDown(debug.dispose);
      await debug.load();
      expect(debug.endpoint.toString(), address);
      expect(debug.validateServer(address), isNull);
      expect(await debug.save('$address/'), isTrue);
      final restored = ServerSettingsViewModel(
        repository,
        allowLoopbackHttp: true,
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.endpoint.toString(), address);
      final release = ServerSettingsViewModel(repository);
      addTearDown(release.dispose);
      await release.load();
      expect(release.endpoint, isNull);
      expect(release.loadError, isNotNull);
      expect(await release.save(address), isFalse);
    },
  );

  test('normalizes HTTPS origin and preserves explicit ports and IPv6', () {
    expect(
      ServerEndpoint.parse('  HTTPS://Remote.Example.com/ ').toString(),
      'https://remote.example.com',
    );
    expect(
      ServerEndpoint.parse('https://remote.example.com:8443/').toString(),
      'https://remote.example.com:8443',
    );
    expect(
      ServerEndpoint.parse('https://[::1]:8443').toString(),
      'https://[::1]:8443',
    );
  });

  for (final input in [
    '',
    'remote.example.com',
    'http://remote.example.com',
    'http://localhost:8080',
    'javascript:alert(1)',
    'https://',
    'https://user:password@remote.example.com',
    'https://@remote.example.com',
    'https://remote.example.com/api',
    'https://remote.example.com?token=secret',
    'https://remote.example.com?',
    'https://remote.example.com#fragment',
    'https://remote.example.com#',
    'https://remote .example.com',
    'https://remote.example.com\\evil',
    'https://remote.example.com:0',
    'https://remote.example.com:65536',
    'https://remote.example.com:invalid',
    'https://%65xample.com',
  ]) {
    test('rejects unsafe or unsupported endpoint: $input', () {
      expect(() => ServerEndpoint.parse(input), throwsFormatException);
    });
  }

  test(
    'stored origin overrides build default and restores on new view model',
    () async {
      final repository = MemoryServerSettingsRepository();
      final first = ServerSettingsViewModel(
        repository,
        defaultServer: 'https://default.example.com',
      );
      await first.load();
      expect(first.endpoint.toString(), 'https://default.example.com');
      expect(await first.save('https://selfhost.example.com/'), isTrue);
      first.dispose();
      final second = ServerSettingsViewModel(repository);
      addTearDown(second.dispose);
      await second.load();
      expect(second.endpoint.toString(), 'https://selfhost.example.com');
    },
  );

  test(
    'read failure and corrupt values do not silently select a default',
    () async {
      for (final repository in [
        MemoryServerSettingsRepository()..failRead = true,
        MemoryServerSettingsRepository(value: 'http://unsafe.example.com'),
      ]) {
        final model = ServerSettingsViewModel(
          repository,
          defaultServer: 'https://default.example.com',
        );
        await model.load();
        expect(model.endpoint, isNull);
        expect(model.loadError, isNotNull);
        expect(model.isLoading, isFalse);
        expect(await model.save('https://recovered.example.com'), isTrue);
        expect(model.loadError, isNull);
        model.dispose();
      }
    },
  );

  test(
    'failed save preserves the previous origin and supports retry',
    () async {
      final repository = MemoryServerSettingsRepository(
        value: 'https://old.example.com',
      );
      final model = ServerSettingsViewModel(repository);
      addTearDown(model.dispose);
      await model.load();
      repository.failWrite = true;
      expect(await model.save('https://new.example.com'), isFalse);
      expect(model.endpoint.toString(), 'https://old.example.com');
      expect(model.saveError, isNotNull);
      expect(model.isSaving, isFalse);
      repository.failWrite = false;
      expect(await model.save('https://new.example.com'), isTrue);
      expect(model.saveError, isNull);
    },
  );

  test('invalid input never reaches storage', () async {
    final repository = MemoryServerSettingsRepository();
    final model = ServerSettingsViewModel(repository);
    addTearDown(model.dispose);
    await model.load();
    expect(await model.save('http://unsafe.example.com'), isFalse);
    expect(repository.writes, 0);
  });

  test(
    'loading and saving block overlapping writes; disposal is safe',
    () async {
      final repository = MemoryServerSettingsRepository()
        ..pendingRead = Completer<void>();
      final model = ServerSettingsViewModel(repository);
      final load = model.load();
      expect(await model.save('https://early.example.com'), isFalse);
      repository.pendingRead!.complete();
      await load;
      repository.pendingWrite = Completer<void>();
      final firstSave = model.save('https://first.example.com');
      expect(model.isSaving, isTrue);
      expect(await model.save('https://second.example.com'), isFalse);
      expect(repository.writes, 1);
      model.dispose();
      repository.pendingWrite!.complete();
      expect(await firstSave, isFalse);
    },
  );

  test('completing a read after disposal does not notify listeners', () async {
    final repository = MemoryServerSettingsRepository()
      ..pendingRead = Completer<void>();
    final model = ServerSettingsViewModel(repository);
    final load = model.load();
    model.dispose();
    repository.pendingRead!.complete();
    await load;
  });
}
