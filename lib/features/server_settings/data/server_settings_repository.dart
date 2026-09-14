import 'package:shared_preferences/shared_preferences.dart';

/// This replaceable platform boundary stores only a non-secret server origin.
abstract interface class ServerSettingsRepository {
  Future<String?> readServer();
  Future<void> writeServer(String server);
}

final class PreferencesServerSettingsRepository
    implements ServerSettingsRepository {
  PreferencesServerSettingsRepository({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const _key = 'remote_server_origin_v1';
  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> readServer() => _preferences.getString(_key);

  @override
  Future<void> writeServer(String server) =>
      _preferences.setString(_key, server);
}
