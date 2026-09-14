import 'package:flutter/material.dart';

import 'activity_animation.dart';
import 'activity_presentation.dart';

class ActivityRow extends StatelessWidget {
  const ActivityRow({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.metadata,
    this.trailing,
    this.minHeight = ActivityPresentation.rowHeight,
    this.running = false,
    this.animate = true,
  });

  final IconData icon;
  final Color color;
  final Widget title;
  final Widget? metadata, trailing;
  final double minHeight;
  final bool running;
  final bool animate;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(minHeight: minHeight),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: ActivityPresentation.gutterFor(context),
            height: ActivityPresentation.firstLineHeight(context),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ActivitySpinner(
                running: running,
                animate: animate,
                color: color,
                icon: Icon(
                  icon,
                  color: color,
                  size: ActivityPresentation.iconSize,
                  applyTextScaling: true,
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                if (metadata != null) ...[const SizedBox(height: 4), metadata!],
              ],
            ),
          ),
          if (trailing != null)
            SizedBox(
              height: ActivityPresentation.firstLineHeight(context),
              child: Center(child: trailing),
            ),
        ],
      ),
    ),
  );
}
