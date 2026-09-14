import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../conversation_view_model.dart';
import 'activity_presentation.dart';

/// A persistent, non-dismissible banner for a pending permission request --
/// high-visibility and time-sensitive, per mobile/AGENTS.md. Actions are
/// replaced by an explanatory message rather than merely disabled once the
/// connector is offline or no longer live, since a stale request may
/// already be answered or expired. See CHAT-PERMISSIONS.md.
class PermissionBanner extends StatelessWidget {
  const PermissionBanner({super.key, required this.model});
  final ConversationViewModel model;

  @override
  Widget build(BuildContext context) {
    final permission = model.permission;
    if (permission == null) return const SizedBox.shrink();
    final (label, icon) = ActivityPresentation.forKind(permission.operation);
    final stale = !model.online() || !model.activityLive;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.warningSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.warning),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: AppTheme.warning, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        permission.description,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppTheme.ink,
                        ),
                        semanticsLabel:
                            '$label permission requested: '
                            '${permission.description}',
                      ),
                      if (permission.pattern case final pattern?)
                        Text(
                          pattern,
                          style: const TextStyle(color: AppTheme.muted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (stale)
              Text(
                model.online()
                    ? 'No longer live -- this request may already be answered or out of date.'
                    : 'Connector offline -- this request may already be answered or out of date.',
                style: const TextStyle(color: AppTheme.muted),
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () =>
                        unawaited(model.respondToPermission('reject')),
                    child: const Text('Deny'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () =>
                        unawaited(model.respondToPermission('once')),
                    child: const Text('Allow once'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
