import 'package:flutter/material.dart';

import '../../features/connections/domain/connection_color.dart';
import 'app_theme.dart';

Color connectionAccent(ConnectionColor color) => switch (color) {
  ConnectionColor.lime => AppTheme.lime,
  ConnectionColor.blue => const Color(0xFFAFD8F5),
  ConnectionColor.purple => const Color(0xFFD4C2F2),
  ConnectionColor.teal => const Color(0xFFA4DFCF),
  ConnectionColor.orange => const Color(0xFFF5CD9D),
  ConnectionColor.rose => const Color(0xFFF0B7CC),
};

class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    this.color = ConnectionColor.lime,
    this.size = 40,
  });
  final ConnectionColor color;
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: connectionAccent(color),
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.chat_bubble_outline,
        color: AppTheme.ink,
        size: size * .55,
      ),
    ),
  );
}
