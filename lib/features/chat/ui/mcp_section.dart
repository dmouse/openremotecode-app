import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../domain/mcp_models.dart';
import '../mcp_view_model.dart';

class McpSection extends StatelessWidget {
  const McpSection({super.key, required this.model});
  final McpViewModel model;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final snapshot = model.snapshot;
      final live = model.live;
      final label = switch (model.phase) {
        McpPhase.loading => 'Loading MCP server status...',
        McpPhase.ready => live ? null : 'Status unavailable',
        McpPhase.unsupported => 'MCP status is not supported by this connector. Restart OpenCode with the updated Remote plugin.',
        McpPhase.offline => 'Offline. MCP status is not live.',
        McpPhase.paused => 'Updates paused. MCP status is not live.',
        McpPhase.untrusted => 'Connection is no longer verified.',
        McpPhase.unavailable => 'MCP status unavailable.',
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'MCP servers',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (label != null) ...[
            const SizedBox(height: 8),
            Semantics(liveRegion: true, child: Text(label)),
          ],
          if (snapshot != null && !live) ...[
            const SizedBox(height: 8),
            const Text(
              'Last-known status. Not live.',
              style: TextStyle(color: AppTheme.muted),
            ),
          ],
          if (snapshot?.available == true && snapshot!.servers.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              live
                  ? 'No MCP servers configured.'
                  : 'No MCP servers in the last-known snapshot.',
            ),
          ],
          for (final server in snapshot?.servers ?? const <McpServer>[]) ...[
            const SizedBox(height: 12),
            Semantics(
              container: true,
              label:
                  '${server.name}: ${live ? server.status.label : 'Last known: ${server.status.label}. Not live.'}',
              excludeSemantics: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Icon(
                      live && server.status == McpStatus.connected
                          ? Icons.circle
                          : Icons.circle_outlined,
                      size: 10,
                      color: live && server.status == McpStatus.connected
                          ? AppTheme.success
                          : AppTheme.muted,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(server.name),
                        if (server.status != McpStatus.connected)
                          Text(
                            live
                                ? server.status.label
                                : 'Last known: ${server.status.label}',
                            style: const TextStyle(color: AppTheme.muted),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    },
  );
}
