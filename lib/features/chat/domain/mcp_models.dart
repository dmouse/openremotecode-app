enum McpStatus {
  connected('Connected'),
  disabled('Disabled'),
  failed('Failed'),
  needsAuth('Needs authentication'),
  needsClientRegistration('Needs client registration');

  const McpStatus(this.label);
  final String label;
}

final class McpServer {
  const McpServer(this.name, this.status);
  final String name;
  final McpStatus status;
}

/// One bounded project snapshot; no URLs, tool lists, or diagnostic payloads.
final class McpSnapshot {
  const McpSnapshot._(
    this.projectId,
    this.available,
    this.servers,
    this.subscriptionId,
    this.revision,
  );
  final String projectId;
  final bool available;
  final List<McpServer> servers;
  final String? subscriptionId;
  final int? revision;

  static const capabilities = {
    'project.mcp.snapshot',
    'project.mcp.subscribe',
    'project.mcp.unsubscribe',
    'project.mcp.updated',
  };
  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static final _unsafeName = RegExp(
    r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]',
  );

  static Map<String, dynamic> request(
    String projectId, {
    String? subscriptionId,
  }) {
    if (!_uuid.hasMatch(projectId) ||
        (subscriptionId != null && !_uuid.hasMatch(subscriptionId))) {
      throw const FormatException('Invalid MCP scope');
    }
    return {
      'version': 1,
      'projectId': projectId,
      'subscriptionId': ?subscriptionId,
    };
  }

  static McpSnapshot parse(Object? raw, {bool subscription = false}) {
    final keys = {
      'version',
      'projectId',
      'state',
      'servers',
      if (subscription) ...['subscriptionId', 'revision'],
    };
    if (raw is! Map<String, dynamic> ||
        raw.length != keys.length ||
        !keys.containsAll(raw.keys) ||
        raw['version'] is! int ||
        raw['version'] != 1 ||
        raw['projectId'] is! String ||
        !_uuid.hasMatch(raw['projectId'] as String) ||
        !['ready', 'unavailable'].contains(raw['state']) ||
        raw['servers'] is! List) {
      throw const FormatException('Invalid MCP snapshot');
    }
    if (subscription &&
        (raw['subscriptionId'] is! String ||
            !_uuid.hasMatch(raw['subscriptionId'] as String) ||
            raw['revision'] is! int ||
            (raw['revision'] as int) < 0 ||
            (raw['revision'] as int) > 9007199254740991)) {
      throw const FormatException('Invalid MCP subscription');
    }
    final rows = raw['servers'] as List;
    if (rows.length > 100 ||
        (raw['state'] == 'unavailable' && rows.isNotEmpty)) {
      throw const FormatException('Invalid MCP servers');
    }
    final names = <String>{};
    final servers = <McpServer>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic> ||
          row.length != 2 ||
          !row.containsKey('status') ||
          row['name'] is! String) {
        throw const FormatException('Invalid MCP server');
      }
      final name = row['name'] as String;
      if (name.isEmpty ||
          name.length > 128 ||
          _unsafeName.hasMatch(name) ||
          !names.add(name)) {
        throw const FormatException('Invalid MCP name');
      }
      final status = switch (row['status']) {
        'connected' => McpStatus.connected,
        'disabled' => McpStatus.disabled,
        'failed' => McpStatus.failed,
        'needs_auth' => McpStatus.needsAuth,
        'needs_client_registration' => McpStatus.needsClientRegistration,
        _ => throw const FormatException('Invalid MCP status'),
      };
      servers.add(McpServer(name, status));
    }
    return McpSnapshot._(
      raw['projectId'] as String,
      raw['state'] == 'ready',
      List.unmodifiable(servers),
      raw['subscriptionId'] as String?,
      raw['revision'] as int?,
    );
  }
}
