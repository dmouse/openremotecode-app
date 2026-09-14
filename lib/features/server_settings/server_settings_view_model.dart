import 'package:flutter/foundation.dart';

import 'data/server_settings_repository.dart';
import 'domain/server_endpoint.dart';

final class ServerSettingsViewModel extends ChangeNotifier {
  ServerSettingsViewModel(
    this._repository, {
    this.defaultServer = '',
    this.allowLoopbackHttp = false,
  });

  final ServerSettingsRepository _repository;
  final String defaultServer;
  final bool allowLoopbackHttp;
  ServerEndpoint? _endpoint;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _disposed = false;
  String? _loadError;
  String? _saveError;

  ServerEndpoint? get endpoint => _endpoint;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  String? get loadError => _loadError;
  String? get saveError => _saveError;
  String get addressInstructions => allowLoopbackHttp
      ? 'Enter your Open Remote Code server address. HTTP on localhost, '
            '127.0.0.1, or [::1] is allowed for local testing.'
      : 'Enter the HTTPS address of your Open Remote Code server.';

  ServerEndpoint _parseServer(String value) =>
      ServerEndpoint.parse(value, allowLoopbackHttp: allowLoopbackHttp);

  Future<void> load() async {
    try {
      final saved = await _repository.readServer();
      if (_disposed) return;
      final value = saved ?? defaultServer;
      _endpoint = value.isEmpty ? null : _parseServer(value);
    } on FormatException {
      _loadError =
          'The saved server address is invalid. Choose your server again.';
    } catch (_) {
      _loadError = 'Could not load your server. Choose and save it again.';
    } finally {
      _isLoading = false;
      _notify();
    }
  }

  String? validateServer(String? value) {
    try {
      _parseServer(value ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  void clearSaveError() {
    if (_saveError == null) return;
    _saveError = null;
    _notify();
  }

  Future<bool> save(String input) async {
    if (_disposed || _isLoading || _isSaving) return false;
    final error = validateServer(input);
    if (error != null) {
      _saveError = error;
      _notify();
      return false;
    }
    final next = _parseServer(input);
    _isSaving = true;
    _saveError = null;
    _notify();
    try {
      await _repository.writeServer(next.toString());
      if (_disposed) return false;
      _endpoint = next;
      _loadError = null;
      return true;
    } catch (_) {
      _saveError = 'Could not save the server. Please try again.';
      return false;
    } finally {
      _isSaving = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
