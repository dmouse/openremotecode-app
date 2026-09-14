import '../../platform/remote_api.dart';
import '../server_settings/domain/server_endpoint.dart';

final class AuthSession {
  const AuthSession({
    required this.server,
    required this.accountId,
    required this.email,
    required this.accessToken,
    required this.expiresAt,
  });

  final ServerEndpoint server;
  final String accountId;
  final String email;
  final String accessToken;
  final DateTime expiresAt;
  String get scope => '${server.toString()}|$accountId';

  factory AuthSession.parse(ServerEndpoint server, Map<String, dynamic> json) {
    final user = requiredMap(json, 'user');
    if (user['status'] != 'active' || user['emailVerified'] is! bool) {
      throw const ApiException(403, 'unauthorized');
    }
    final expires = requiredDate(json, 'accessTokenExpiresAt');
    if (!expires.isAfter(DateTime.now())) {
      throw const ApiException(0, 'invalid_response');
    }
    requiredDate(user, 'createdAt');
    return AuthSession(
      server: server,
      accountId: requiredString(user, 'id', max: 64),
      email: requiredString(user, 'email', max: 254),
      accessToken: requiredString(json, 'accessToken', max: 4096),
      expiresAt: expires,
    );
  }
}
