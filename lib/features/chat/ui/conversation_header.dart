import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../conversation_view_model.dart';
import 'activity_animation.dart';
import 'activity_presentation.dart';
import 'model_banner.dart' show effortLabel;

/// The conversation app bar's title: an avatar badged with presence/working
/// state, stacked with a title line and an optional model line. Tapping it
/// opens chat details unless this is a read-only subtask view, in which case
/// [onOpenDetails] is null and the title is inert.
class ConversationHeader extends StatelessWidget {
  const ConversationHeader({
    super.key,
    required this.online,
    required this.working,
    required this.model,
    required this.title,
    this.onOpenDetails,
  });

  final bool online;
  final bool working;
  final ConversationViewModel model;
  final String title;
  final VoidCallback? onOpenDetails;

  /// The selected model, plus its effort when one is set. Null (no second
  /// line at all) when no explicit model choice has been made -- OpenCode's
  /// own default stays unnamed in the header.
  static String? modelLine(ConversationViewModel model) {
    final selected = model.models.selectedModel;
    if (selected == null) return null;
    final effort = model.models.selectedEffort;
    return effort == null
        ? selected.modelName
        : '${selected.modelName} · ${effortLabel(effort)}';
  }

  /// Height the conversation bar needs for a title and a model line. The
  /// pair fits the default bar, so only scaled-up text stretches it.
  static double height(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final lines = scaler.scale(16) + scaler.scale(12) * 1.3;
    return lines + 16 > kToolbarHeight ? lines + 16 : kToolbarHeight;
  }

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      _HeaderAvatar(online: online, working: working),
      const SizedBox(width: 10),
      Expanded(
        child: onOpenDetails == null
            ? _headerLines(context, model, title, null)
            : Tooltip(
                message: title,
                child: TextButton(
                  onPressed: onOpenDetails,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    // The whole two-line block is the tap target, so
                    // neither line needs padding of its own to reach 48
                    // pixels.
                    minimumSize: const Size(0, 48),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    alignment: Alignment.centerLeft,
                  ),
                  child: _headerLines(
                    context,
                    model,
                    title,
                    '$title, open chat details',
                  ),
                ),
              ),
      ),
    ],
  );
}

/// The conversation title stacked directly on the model line, with no
/// spacing between them.
Widget _headerLines(
  BuildContext context,
  ConversationViewModel model,
  String title,
  String? semanticsLabel,
) => Column(
  mainAxisSize: MainAxisSize.min,
  mainAxisAlignment: MainAxisAlignment.center,
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(
      title,
      semanticsLabel: semanticsLabel ?? '$title, subtask',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1,
        color: AppTheme.ink,
      ),
    ),
    if (ConversationHeader.modelLine(model) case final line?)
      Text(
        line,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: AppTheme.muted, height: 1.3),
      ),
  ],
);

/// The chat header's agent mark, badged with its state: a spinner while the
/// agent works, otherwise a presence dot -- filled green when online,
/// outlined and muted when not, so status never rests on color alone. See
/// docs/design.md, "Conversation header and actions".
class _HeaderAvatar extends StatelessWidget {
  const _HeaderAvatar({required this.online, required this.working});

  final bool online;
  final bool working;

  static const double _size = 32;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: working
        ? 'Working'
        : online
        ? 'Online'
        : 'Offline',
    excludeFromSemantics: true,
    child: SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: _size,
            height: _size,
            decoration: const BoxDecoration(
              color: AppTheme.lime,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.smart_toy_outlined,
              size: 18,
              color: AppTheme.ink,
            ),
          ),
          // The badge rides the avatar's corner, on a ring of the bar's own
          // colour so it stays legible against the lime disc. The spinner is
          // the same activity pulse the conversation's rows use; the bar sits
          // outside their scope, so it carries its own clock -- one that only
          // exists while work is in flight and this route is current.
          Positioned(
            right: -3,
            bottom: -3,
            child: Container(
              width: ActivityPresentation.scaledIconSize(context) + 3,
              height: ActivityPresentation.scaledIconSize(context) + 3,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: AppTheme.background,
                shape: BoxShape.circle,
              ),
              child: working
                  ? Semantics(
                      label: 'Working',
                      liveRegion: true,
                      child: ActivityAnimations(
                        enabled: true,
                        child: const ActivityPulse(
                          running: true,
                          color: AppTheme.success,
                        ),
                      ),
                    )
                  : Icon(
                      online ? Icons.circle : Icons.circle_outlined,
                      size: 10,
                      semanticLabel: online ? 'Online' : 'Offline',
                      color: online ? AppTheme.success : AppTheme.muted,
                    ),
            ),
          ),
        ],
      ),
    ),
  );
}
