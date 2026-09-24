import 'dart:async';

import 'package:flutter/foundation.dart';

import 'data/connections_repository.dart';
import 'domain/pairing_code.dart';
import 'domain/pairing_review.dart';
import 'domain/remote_connection.dart';

final class PairingViewModel extends ChangeNotifier {
  PairingViewModel(this._repository, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final ConnectionsRepository _repository;
  final DateTime Function() _now;
  PairingReview? _review;
  Timer? _expiryTimer;
  bool _working = false;
  bool _disposed = false;
  String? _error;

  PairingReview? get review => _review;
  bool get isWorking => _working;
  String? get error => _error;

  String? validateCode(String? input) {
    try {
      PairingCode.parse(input ?? '');
      return null;
    } on FormatException catch (error) {
      return error.message;
    }
  }

  void clearError() {
    if (_error == null || _working || _disposed) return;
    _error = null;
    notifyListeners();
  }

  Future<void> checkCode(String input) async {
    if (_working || _disposed) return;
    final validation = validateCode(input);
    if (validation != null) {
      _error = validation;
      notifyListeners();
      return;
    }
    _working = true;
    _review = null;
    _error = null;
    _expiryTimer?.cancel();
    notifyListeners();
    try {
      final review = await _repository.reviewPairing(
        PairingCode.parse(input).value,
      );
      if (_disposed) return;
      if (!review.expiresAt.isAfter(_now())) {
        throw ConnectionFailure.expiredCode;
      }
      _review = review;
      _expiryTimer = Timer(review.expiresAt.difference(_now()), _expire);
    } catch (error) {
      if (!_disposed) _error = _message(error);
    } finally {
      if (!_disposed) {
        _working = false;
        notifyListeners();
      }
    }
  }

  Future<RemoteConnection?> confirm() async {
    final review = _review;
    if (_disposed || _working || review == null) return null;
    if (!review.expiresAt.isAfter(_now())) {
      _expire();
      return null;
    }
    _working = true;
    _error = null;
    notifyListeners();
    try {
      final connection = await _repository.confirmPairing(review);
      if (_disposed) return null;
      _expiryTimer?.cancel();
      _review = null;
      return connection;
    } catch (error) {
      if (!_disposed) {
        // A request may have reached the server. Never automatically retry a
        // confirmation with an uncertain outcome or keep stale trust material.
        if (error != ConnectionFailure.connectorNotReady &&
            error != ConnectionFailure.tooManyAttempts &&
            error != ConnectionFailure.secureStorage &&
            error != ConnectionFailure.network) {
          _review = null;
          _expiryTimer?.cancel();
        }
        _error = _message(error);
      }
      return null;
    } finally {
      if (!_disposed) {
        _working = false;
        notifyListeners();
      }
    }
  }

  void reject() {
    if (_working || _disposed) return;
    _expiryTimer?.cancel();
    _review = null;
    _error = 'The codes did not match. Start a new pairing from OpenCode.';
    notifyListeners();
  }

  void _expire() {
    if (_disposed) return;
    _review = null;
    _error = ConnectionFailure.expiredCode.message;
    notifyListeners();
  }

  String _message(Object error) => error is ConnectionFailure
      ? error.message
      : 'Pairing could not be completed. Please try again.';

  @override
  void dispose() {
    _disposed = true;
    _expiryTimer?.cancel();
    super.dispose();
  }
}
