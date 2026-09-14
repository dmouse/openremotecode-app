import '../../platform/remote_api.dart';
import '../server_settings/domain/server_endpoint.dart';

/// A pending account and the ticket that proves ownership of its address.
///
/// The ticket is not a bearer credential: it reaches only `/v1/auth/verify-email`
/// and `/v1/auth/resend-verification`, and it is never persisted. If the app is
/// killed mid-verification, signing in again reissues a fresh code, which is
/// cheaper than introducing a new class of stored secret.
final class VerificationChallenge {
  const VerificationChallenge({
    required this.server,
    required this.accountId,
    required this.email,
    required this.ticket,
    required this.ticketExpiresAt,
  });

  final ServerEndpoint server;
  final String accountId;
  final String email;
  final String ticket;
  final DateTime ticketExpiresAt;

  factory VerificationChallenge.parse(
    ServerEndpoint server,
    Map<String, dynamic> json,
  ) {
    final user = requiredMap(json, 'user');
    // A challenge only ever describes a pending account. Anything else means the
    // response is not what this screen is built to handle.
    if (user['status'] != 'pending' || user['emailVerified'] is! bool) {
      throw const ApiException(0, 'invalid_response');
    }
    requiredDate(user, 'createdAt');
    return VerificationChallenge(
      server: server,
      accountId: requiredString(user, 'id', max: 64),
      email: requiredString(user, 'email', max: 254),
      ticket: requiredString(json, 'verificationTicket', max: 512),
      ticketExpiresAt: requiredDate(json, 'verificationTicketExpiresAt'),
    );
  }

  /// True when the response carries a verification challenge rather than a
  /// session. Registering always does; signing in does only for a pending account.
  static bool isChallenge(Map<String, dynamic> json) =>
      json['verificationTicket'] is String;
}
