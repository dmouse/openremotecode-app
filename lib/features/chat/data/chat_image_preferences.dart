import 'package:shared_preferences/shared_preferences.dart';

/// Local, per-device preference for whether to request and render inline
/// image previews in chat. Purely a display choice: it never affects what
/// the connector retains and defaults on since previews are the point of
/// this feature.
abstract interface class ChatImagePreferences {
  Future<bool> readShowImages();
  Future<void> writeShowImages(bool value);
}

final class PreferencesChatImagePreferences implements ChatImagePreferences {
  PreferencesChatImagePreferences([this._preferences]);

  static const _key = 'chat_show_images_v1';
  // Constructed lazily: instantiating SharedPreferencesAsync throws if no
  // platform implementation is registered yet, so this must never happen
  // eagerly in a constructor -- only inside an awaited call callers can guard.
  SharedPreferencesAsync? _preferences;
  SharedPreferencesAsync get _prefs =>
      _preferences ??= SharedPreferencesAsync();

  @override
  Future<bool> readShowImages() async => await _prefs.getBool(_key) ?? true;

  @override
  Future<void> writeShowImages(bool value) => _prefs.setBool(_key, value);
}
