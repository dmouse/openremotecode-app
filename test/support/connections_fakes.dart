import 'dart:async';

import 'package:openremotecode/features/connections/data/connections_repository.dart';
import 'package:openremotecode/features/connections/domain/pairing_review.dart';
import 'package:openremotecode/features/connections/domain/remote_connection.dart';

final class FakeConnectionsRepository implements ConnectionsRepository {
  List<RemoteConnection> connections = [];
  Object? failure;
  Completer<void>? gate;
  String? code;
  int claims = 0;
  int confirmations = 0;
  int revocations = 0;
  int renames = 0;
  Duration lifetime = const Duration(minutes: 5);
  final connection = const RemoteConnection(
    id: 'con_test',
    name: 'Development laptop',
    status: ConnectionStatus.unknown,
  );
  @override
  Future<List<RemoteConnection>> listConnections() async {
    if (gate case final pending?) await pending.future;
    if (failure case final error?) throw error;
    return connections;
  }

  @override
  Future<PairingReview> reviewPairing(String code) async {
    this.code = code;
    claims++;
    if (gate case final pending?) await pending.future;
    if (failure case final error?) throw error;
    return PairingReview(
      pairingId: 'par_test',
      safetyCode: '1234 5678 90AB CDEF 1234 5678',
      expiresAt: DateTime.now().add(lifetime),
    );
  }

  @override
  Future<RemoteConnection> confirmPairing(PairingReview review) async {
    confirmations++;
    if (gate case final pending?) await pending.future;
    if (failure case final error?) throw error;
    connections = [connection];
    return connection;
  }

  @override
  Future<void> revokeConnection(String connectorId) async {
    revocations++;
    if (gate case final pending?) await pending.future;
    if (failure case final error?) throw error;
    connections = connections.where((c) => c.id != connectorId).toList();
  }

  @override
  Future<String> renameConnection(String connectorId, String name) async {
    renames++;
    if (gate case final pending?) await pending.future;
    if (failure case final error?) throw error;
    connections = connections
        .map(
          (c) => c.id != connectorId
              ? c
              : RemoteConnection(id: c.id, name: name, status: c.status),
        )
        .toList();
    return name;
  }
}
