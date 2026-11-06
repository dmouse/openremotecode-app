import 'package:shared_preferences/shared_preferences.dart';

import '../domain/app_appearance.dart';

abstract interface class AppearanceRepository {
  Future<AppAppearance> readAppearance();
  Future<void> writeAppearance(AppAppearance value);
}

/// Per-device chat display choices. No conversation content is stored here.
abstract interface class SettingsRepository {
  Future<bool> readShowImages();
  Future<void> writeShowImages(bool value);
  Future<bool> readShowThinkingMessages();
  Future<void> writeShowThinkingMessages(bool value);
}

final class PreferencesSettingsRepository
    implements SettingsRepository, AppearanceRepository {
  PreferencesSettingsRepository([this._preferences]);

  // Keep the existing image key so upgrades preserve the user's choice.
  static const _imagesKey = 'chat_show_images_v1';
  static const _thinkingKey = 'chat_show_thinking_v1';
  static const _appearanceKey = 'app_appearance_v1';

  @override
  Future<AppAppearance> readAppearance() async {
    final value = await _prefs.getString(_appearanceKey);
    return AppAppearance.values
            .where((mode) => mode.name == value)
            .firstOrNull ??
        AppAppearance.system;
  }

  @override
  Future<void> writeAppearance(AppAppearance value) =>
      _prefs.setString(_appearanceKey, value.name);

  // Construct lazily: a platform implementation may not be registered yet
  // when the repository is created (notably in widget tests).
  SharedPreferencesAsync? _preferences;
  SharedPreferencesAsync get _prefs =>
      _preferences ??= SharedPreferencesAsync();

  @override
  Future<bool> readShowImages() async =>
      await _prefs.getBool(_imagesKey) ?? true;

  @override
  Future<void> writeShowImages(bool value) => _prefs.setBool(_imagesKey, value);

  @override
  Future<bool> readShowThinkingMessages() async =>
      await _prefs.getBool(_thinkingKey) ?? true;

  @override
  Future<void> writeShowThinkingMessages(bool value) =>
      _prefs.setBool(_thinkingKey, value);
}
