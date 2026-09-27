import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/app.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/features/settings/data/settings_repository.dart';
import 'package:openremotecode/features/settings/settings_view_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/memory_settings_repository.dart';
import 'support/auth_fakes.dart';
import 'support/connections_fakes.dart';
import 'support/memory_server_settings_repository.dart';

void main() {
  test('defaults on; both switches persist across view models', () async {
    final repository = MemorySettingsRepository();
    final first = SettingsViewModel(repository);
    expect(first.showImages, isTrue);
    expect(first.showThinkingMessages, isTrue);
    await first.setShowImages(false);
    await first.setShowThinkingMessages(false);
    first.dispose();

    final second = SettingsViewModel(repository);
    await second.load();
    expect(second.showImages, isFalse);
    expect(second.showThinkingMessages, isFalse);
    second.dispose();
  });

  test(
    'existing image storage key is preserved and thinking defaults on',
    () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final preferences = SharedPreferencesAsync();
      await preferences.setBool('chat_show_images_v1', false);
      final model = SettingsViewModel(
        PreferencesSettingsRepository(preferences),
      );
      await model.load();
      expect(model.showImages, isFalse);
      expect(model.showThinkingMessages, isTrue);
      await model.setShowThinkingMessages(false);
      final again = SettingsViewModel(
        PreferencesSettingsRepository(preferences),
      );
      await again.load();
      expect(again.showImages, isFalse);
      expect(again.showThinkingMessages, isFalse);
      model.dispose();
      again.dispose();
    },
  );

  test(
    'independent read failures retain defaults for only the failed key',
    () async {
      final repository = MemorySettingsRepository(
        images: false,
        thinking: false,
      )..failImagesRead = true;
      final model = SettingsViewModel(repository);
      await model.load();
      expect(model.showImages, isTrue);
      expect(model.showThinkingMessages, isFalse);
      model.dispose();
    },
  );

  test('write failure keeps immediate choice for this process', () async {
    final repository = MemorySettingsRepository()
      ..failImagesWrite = true
      ..failThinkingWrite = true;
    final model = SettingsViewModel(repository);
    await model.setShowImages(false);
    await model.setShowThinkingMessages(false);
    expect(model.showImages, isFalse);
    expect(model.showThinkingMessages, isFalse);
    model.dispose();
  });

  test(
    'a late read cannot overwrite a newer user choice or a disposed model',
    () async {
      final read = Completer<bool>();
      final repository = _DelayedSettingsRepository(read.future);
      final model = SettingsViewModel(repository);
      final loading = model.load();
      expect(identical(model.load(), loading), isTrue);
      await model.setShowImages(false);
      read.complete(true);
      await loading;
      expect(model.showImages, isFalse);
      model.dispose();
      await model.setShowImages(true);
      expect(model.showImages, isFalse);

      final pending = Completer<bool>();
      final late = SettingsViewModel(
        _DelayedSettingsRepository(pending.future),
      );
      final lateLoad = late.load();
      late.dispose();
      pending.complete(false);
      await lateLoad;
    },
  );

  testWidgets(
    'app waits for settings before showing an authenticated workspace',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = fakeAuth();
      expect(
        await auth.login(
          ServerEndpoint.parse('https://remote.example.com'),
          'person@example.com',
          'password',
        ),
        isTrue,
      );
      final pending = Completer<bool>();
      await tester.pumpWidget(
        MainApp(
          authRepository: auth,
          serverSettingsRepository: MemoryServerSettingsRepository(
            value: 'https://remote.example.com',
          ),
          settingsRepository: _DelayedSettingsRepository(pending.future),
          connectionsRepositoryFactory: (_) => FakeConnectionsRepository(),
        ),
      );
      expect(find.bySemanticsLabel('Restoring session'), findsOneWidget);
      expect(find.text('Connections'), findsNothing);
      pending.complete(false);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      final tiles = tester.widgetList<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      expect(tiles.map((tile) => tile.value), [true, false]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
}

final class _DelayedSettingsRepository implements SettingsRepository {
  _DelayedSettingsRepository(this.read);
  final Future<bool> read;

  @override
  Future<bool> readShowImages() => read;
  @override
  Future<bool> readShowThinkingMessages() async => true;
  @override
  Future<void> writeShowImages(bool value) async {}
  @override
  Future<void> writeShowThinkingMessages(bool value) async {}
}
