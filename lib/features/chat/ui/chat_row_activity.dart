import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../domain/chat_models.dart';

class ChatRowActivity extends StatelessWidget {
  const ChatRowActivity({
    super.key,
    required this.activity,
    required this.online,
  });
  final ChatActivity? activity;
  final bool online;
  @override
  Widget build(BuildContext context) {
    final state = activity;
    if (state == null || (!state.working && !state.unread)) {
      return const SizedBox.shrink();
    }
    final colors = AppTheme.of(context);
    final label = state.working
        ? (online ? 'Agent working' : 'Last known: agent working')
        : 'Finished · Unread';
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Semantics(
          label: label,
          child: ExcludeSemantics(
            child:
                state.working &&
                    online &&
                    !MediaQuery.disableAnimationsOf(context)
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.info,
                    ),
                  )
                : Icon(
                    state.working ? Icons.autorenew : Icons.check,
                    size: 18,
                    color: state.working ? colors.muted : colors.success,
                  ),
          ),
        ),
      ),
    );
  }
}
