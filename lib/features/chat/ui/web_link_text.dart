import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../data/external_link_opener.dart';
import '../domain/web_link.dart';

Future<void> showMessageLink(
  BuildContext context,
  String? destination,
  ExternalLinkOpener opener,
) async {
  final uri = parseWebLink(destination);
  if (uri == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Only HTTP and HTTPS web links can be opened.'),
      ),
    );
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Open external link?'),
      content: SingleChildScrollView(child: SelectableText(uri.toString())),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final opened = await opener.open(destination);
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Could not open this link. Check that a browser is installed.',
        ),
      ),
    );
  }
}

/// User prompts stay selectable, with bounded, explicitly tapped web links.
/// PR labels hide their parenthesized URLs only in the presentation. Owned
/// recognizers are replaced on streamed edits and disposed.
class WebLinkText extends StatefulWidget {
  const WebLinkText({
    super.key,
    required this.text,
    this.style,
    this.linkOpener = const ExternalLinkOpener(),
  });
  final String text;
  final TextStyle? style;
  final ExternalLinkOpener linkOpener;

  @override
  State<WebLinkText> createState() => _WebLinkTextState();
}

class _WebLinkTextState extends State<WebLinkText> {
  final _recognizers = <TapGestureRecognizer>[];
  String? _source;
  List<InlineSpan> _spans = [];
  bool _opening = false;

  Future<void> _open(String destination) async {
    if (_opening) return;
    _opening = true;
    try {
      await showMessageLink(context, destination, widget.linkOpener);
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_source != widget.text) {
      for (final recognizer in _recognizers) {
        recognizer.dispose();
      }
      _recognizers.clear();
      _source = widget.text;
      _spans = [];
      var offset = 0;
      for (final link in messageWebLinks(widget.text)) {
        _spans.add(TextSpan(text: widget.text.substring(offset, link.start)));
        final recognizer = TapGestureRecognizer()
          ..onTap = () {
            unawaited(_open(link.text));
          };
        _recognizers.add(recognizer);
        _spans.add(
          TextSpan(
            text: link.label,
            recognizer: recognizer,
            style: const TextStyle(
              color: AppTheme.info,
              decoration: TextDecoration.underline,
            ),
          ),
        );
        offset = link.end;
      }
      _spans.add(TextSpan(text: widget.text.substring(offset)));
    }
    if (_recognizers.isEmpty) {
      return SelectableText(widget.text, style: widget.style);
    }
    return SelectableText.rich(TextSpan(children: _spans), style: widget.style);
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }
}
