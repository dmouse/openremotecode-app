/// A remote relay origin, never a direct local OpenCode API address.
final class ServerEndpoint {
  const ServerEndpoint._(this.uri);

  final Uri uri;

  static ServerEndpoint parse(String input, {bool allowLoopbackHttp = false}) {
    final value = input.trim();
    final uri = Uri.tryParse(value);
    if (value.isEmpty) {
      throw const FormatException('Enter your server address.');
    }
    if (uri == null ||
        (uri.scheme != 'https' &&
            !(allowLoopbackHttp &&
                uri.scheme == 'http' &&
                const {'127.0.0.1', 'localhost', '::1'}.contains(uri.host))) ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        RegExp(r'\s|\\|%|[^\x21-\x7E]').hasMatch(value) ||
        uri.host.contains('%') ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw FormatException(
        allowLoopbackHttp
            ? 'Use a valid HTTPS address, or HTTP on localhost, 127.0.0.1, or [::1] for local testing.'
            : 'Use a valid HTTPS address, such as https://remote.example.com.',
      );
    }
    if (uri.userInfo.isNotEmpty ||
        value.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException(
        'Use only the server origin, without a path, credentials, query, or fragment.',
      );
    }
    return ServerEndpoint._(uri.replace(path: ''));
  }

  @override
  String toString() => uri.toString();
}
