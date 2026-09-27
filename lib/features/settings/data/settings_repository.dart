import 'package:shared_preferences/shared_preferences.dart';

/// Per-device chat display choices. No conversation content is stored here.
abstract interface class SettingsRepository {
  Future<bool> readShowImages();
  Future<void> writeShowImages(bool value);
  Future<bool> readShowThinkingMessages();
  Future<void> writeShowThinkingMessages(bool value);
}

final class PreferencesSettingsRepository implements SettingsRepository {
  PreferencesSettingsRepository([this._preferences]);

  // Keep the existing image key so upgrades preserve the user's choice.
  static const _imagesKey = 'chat_show_images_v1';
  static const _thinkingKey = 'chat_show_thinking_v1';

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
