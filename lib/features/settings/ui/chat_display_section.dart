import 'dart:async';

import 'package:flutter/material.dart';

import '../settings_view_model.dart';

class ChatDisplaySection extends StatelessWidget {
  const ChatDisplaySection({super.key, required this.settings});

  final SettingsViewModel settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) {
      final style = Theme.of(context).textTheme.bodyMedium;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Chat', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: settings.showThinkingMessages,
            onChanged: (value) =>
                unawaited(settings.setShowThinkingMessages(value)),
            title: Text(
              'Show thinking messages',
              style: style?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Show the agent’s Thought rows in every chat.',
              style: style?.copyWith(fontSize: 12),
            ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: settings.showImages,
            onChanged: (value) => unawaited(settings.setShowImages(value)),
            title: Text(
              'Show image previews',
              style: style?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Preview photos and screenshots in every chat.',
              style: style?.copyWith(fontSize: 12),
            ),
          ),
        ],
      );
    },
  );
}
