import '../domain/pairing_review.dart';
import '../domain/remote_connection.dart';

abstract interface class ConnectionsRepository {
  Future<List<RemoteConnection>> listConnections();
  Future<PairingReview> reviewPairing(String code);
  Future<RemoteConnection> confirmPairing(PairingReview review);
  Future<void> revokeConnection(String connectorId);
  Future<String> renameConnection(String connectorId, String name);
}

enum ConnectionFailure implements Exception {
  invalidCode,
  expiredCode,
  usedCode,
  unauthorized,
  unavailable,
  network,
  identityMismatch,
  connectorNotReady,
  tooManyAttempts,
  secureStorage;

  String get message => switch (this) {
    invalidCode => 'That code was not found. Check it and try again.',
    expiredCode => 'This code has expired. Get a new code from OpenCode.',
    usedCode =>
      'This code has already been used. Get a new code from OpenCode.',
    unauthorized => 'Your session has expired. Sign in again to connect.',
    unavailable => 'Pairing is unavailable. Please try again later.',
    network =>
      'Could not reach your server. Check your connection and try again.',
    identityMismatch => 'The device identity changed. Start a new pairing.',
    connectorNotReady => 'OpenCode has not approved this phone yet. Approve it in OpenCode, then confirm again.',
    tooManyAttempts =>
      'Too many attempts. Wait a few minutes, then try the code again.',
    secureStorage =>
      'Could not save device trust securely. Unlock your device and try again.',
  };
}

abstract interface class ConnectionsPresence {
  Stream<Map<String, ConnectionStatus>> get presence;
  void setActive(bool active);
  void dispose();
}
