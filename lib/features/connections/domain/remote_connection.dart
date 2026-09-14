enum ConnectionStatus {
  online,
  offline,
  verificationRequired,
  identityChanged,
  unknown,
}

final class RemoteConnection {
  const RemoteConnection({
    required this.id,
    required this.name,
    required this.status,
    this.lastSeen,
  });

  final String id;
  final String name;
  final ConnectionStatus status;
  final DateTime? lastSeen;

  String get statusLabel => switch (status) {
    ConnectionStatus.online => 'Online',
    ConnectionStatus.offline => 'Offline',
    ConnectionStatus.verificationRequired => 'Verification required',
    ConnectionStatus.identityChanged => 'Connection identity changed',
    ConnectionStatus.unknown => 'Status unavailable',
  };

  String? get verificationMessage => switch (status) {
    ConnectionStatus.verificationRequired => 'This connection is on your account, but has not been paired with this device. Pairing in another browser or device does not verify it here.',
    ConnectionStatus.identityChanged => 'This connection no longer matches the identity verified on this device. Check OpenCode on your computer before starting a new pairing.',
    _ => null,
  };

  bool get needsVerification =>
      status == ConnectionStatus.verificationRequired ||
      status == ConnectionStatus.identityChanged;
}
