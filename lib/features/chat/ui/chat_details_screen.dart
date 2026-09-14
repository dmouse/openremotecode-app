import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../conversation_view_model.dart';
import '../mcp_view_model.dart';
import 'chat_details_actions.dart';
import 'mcp_section.dart';

class ChatDetailsScreen extends StatefulWidget {
  const ChatDetailsScreen({super.key, required this.model});

  final ConversationViewModel model;

  @override
  State<ChatDetailsScreen> createState() => _ChatDetailsScreenState();
}

class _ChatDetailsScreenState extends State<ChatDetailsScreen>
    with WidgetsBindingObserver {
  late final String? _source, _projectPath;
  late final McpViewModel _mcp;
  bool _foreground = true, _visible = false;

  bool get _valid =>
      !widget.model.trustLost() &&
      widget.model.isConversationPage() &&
      widget.model.composerKey == _source &&
      widget.model.project()?.path == _projectPath;

  @override
  void initState() {
    super.initState();
    _source = widget.model.composerKey;
    _projectPath = widget.model.project()?.path;
    _mcp = McpViewModel(
      widget.model.repository,
      widget.model.connectorId,
      widget.model.project()!.id,
    );
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.model.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = ModalRoute.of(context)?.isCurrent == true;
    _mcp.setActive(_valid && _visible && _foreground);
    if (!_valid && _visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _changed();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _mcp.setActive(_valid && _visible && _foreground);
  }

  void _changed() {
    _mcp.setProject(_valid ? widget.model.project()!.id : null);
    if (!_valid && mounted && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    _mcp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final model = widget.model;
      final theme = Theme.of(context);
      return PopScope<void>(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            _visible = false;
            _mcp.setActive(false);
          }
        },
        child: Scaffold(
          backgroundColor: AppTheme.background,
          appBar: AppBar(
            backgroundColor: AppTheme.background,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            title: const Text('Chat details'),
          ),
          // Do not retain visible details during an invalidated route's exit.
          body: !_valid
              ? const SizedBox.shrink()
              : SafeArea(
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text(
                        model.chat?.title ?? 'New chat',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.ink,
                        ),
                      ),
                      const Divider(
                        height: 40,
                        thickness: 1,
                        color: AppTheme.border,
                      ),
                      McpSection(model: _mcp),
                      const Divider(
                        height: 40,
                        thickness: 1,
                        color: AppTheme.border,
                      ),
                      _ImagePreviewToggle(model: model),
                      const Divider(
                        height: 40,
                        thickness: 1,
                        color: AppTheme.border,
                      ),
                      ChatDetailsActions(model: model),
                    ],
                  ),
                ),
        ),
      );
    },
  );
}

class _ImagePreviewToggle extends StatelessWidget {
  const _ImagePreviewToggle({required this.model});
  final ConversationViewModel model;

  @override
  Widget build(BuildContext context) {
    // Match the MCP server list, which leaves its rows at the body text size
    // rather than the larger default a list tile gives its title. Weight and a
    // smaller explanation, not size, separate the label from its description.
    final style = Theme.of(context).textTheme.bodyMedium;
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      value: model.showImages,
      onChanged: (value) => unawaited(model.setShowImages(value)),
      title: Text(
        'Show image previews',
        style: style?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        'Preview photos and screenshots inline in this chat.',
        style: style?.copyWith(fontSize: 12),
      ),
    );
  }
}
