import 'package:flutter/foundation.dart';

import 'data/settings_repository.dart';
import 'domain/app_appearance.dart';
export 'domain/app_appearance.dart';

/// App-wide, per-device chat display settings. Both choices default on.
final class SettingsViewModel extends ChangeNotifier {
  SettingsViewModel(this._repository);

  final SettingsRepository _repository;
  bool _disposed = false;
  bool _showImages = true;
  bool _showThinkingMessages = true;
  int _imageRevision = 0;
  int _thinkingRevision = 0;
  Future<void>? _loading;
  Future<void> _imageWrites = Future<void>.value();
  Future<void> _thinkingWrites = Future<void>.value();
  AppAppearance _appearance = AppAppearance.system;
  int _appearanceRevision = 0;
  Future<void> _appearanceWrites = Future<void>.value();
  AppAppearance get appearance => _appearance;

  Future<void> setAppearance(AppAppearance value) {
    if (_disposed || _appearance == value) return Future<void>.value();
    _appearanceRevision++;
    _appearance = value;
    notifyListeners();
    return _appearanceWrites = _appearanceWrites.then((_) async {
      try {
        if (_repository case final AppearanceRepository repository) {
          await repository.writeAppearance(value);
        }
      } catch (_) {
        // An unavailable preference store must not block the effective theme.
      }
    });
  }

  bool get showImages => _showImages;
  bool get showThinkingMessages => _showThinkingMessages;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final imageRevision = _imageRevision;
    final thinkingRevision = _thinkingRevision;
    final appearanceRevision = _appearanceRevision;
    try {
      if (_repository case final AppearanceRepository repository) {
        final appearance = await repository.readAppearance();
        if (!_disposed && appearanceRevision == _appearanceRevision) {
          _appearance = appearance;
          notifyListeners();
        }
      }
    } catch (_) {
      // Keep the system default or a newer choice.
    }
    // A failure reading one key must not prevent the other from loading.
    try {
      final value = await _repository.readShowImages();
      if (!_disposed &&
          imageRevision == _imageRevision &&
          value != _showImages) {
        _showImages = value;
        notifyListeners();
      }
    } catch (_) {
      // Keep the default or a more recent in-memory choice.
    }
    try {
      final value = await _repository.readShowThinkingMessages();
      if (!_disposed &&
          thinkingRevision == _thinkingRevision &&
          value != _showThinkingMessages) {
        _showThinkingMessages = value;
        notifyListeners();
      }
    } catch (_) {
      // Keep the default or a more recent in-memory choice.
    }
  }

  Future<void> setShowImages(bool value) {
    if (_disposed || _showImages == value) return Future<void>.value();
    _imageRevision++;
    _showImages = value;
    notifyListeners();
    // Serialize rapid toggles so an earlier write cannot win the last race.
    return _imageWrites = _imageWrites.then((_) async {
      try {
        await _repository.writeShowImages(value);
      } catch (_) {
        // The in-memory setting remains effective for this process.
      }
    });
  }

  Future<void> setShowThinkingMessages(bool value) {
    if (_disposed || _showThinkingMessages == value) {
      return Future<void>.value();
    }
    _thinkingRevision++;
    _showThinkingMessages = value;
    notifyListeners();
    return _thinkingWrites = _thinkingWrites.then((_) async {
      try {
        await _repository.writeShowThinkingMessages(value);
      } catch (_) {
        // The in-memory setting remains effective for this process.
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
