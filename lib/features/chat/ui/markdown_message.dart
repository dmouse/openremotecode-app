import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../ui/core/app_theme.dart';
import '../data/external_link_opener.dart';
import '../domain/web_link.dart';
import 'web_link_text.dart';

class MarkdownMessage extends StatefulWidget {
  const MarkdownMessage({
    super.key,
    required this.text,
    this.linkOpener = const ExternalLinkOpener(),
  });
  final String text;
  final ExternalLinkOpener linkOpener;
  @override
  State<MarkdownMessage> createState() => _MarkdownMessageState();
}

class _MarkdownMessageState extends State<MarkdownMessage> {
  String get text => widget.text;
  String? _renderedText;
  ThemeData? _renderedTheme;
  Widget? _rendered;

  static final _deepBlock = RegExp(r'^[\t >*+\-\d.)]{16}', multiLine: true);
  bool _openingLink = false;

  Future<void> _openLink(String? destination) async {
    if (_openingLink) return;
    _openingLink = true;
    try {
      await showMessageLink(context, destination, widget.linkOpener);
    } finally {
      _openingLink = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_rendered == null || _renderedText != text || _renderedTheme != theme) {
      _renderedText = text;
      _renderedTheme = theme;
      _rendered = _render(context);
    }
    return _rendered!;
  }

  Widget _render(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyLarge!.copyWith(color: AppTheme.ink);
    final code = body.copyWith(
      fontFamily: 'monospace',
      fontSize: 14,
      height: 1.45,
      backgroundColor: AppTheme.codeSurface,
    );
    // Preserve the entire bounded wire message when rich layout is too costly
    // or deeply indented blocks would leave no readable width on a phone.
    if (text.length > 16000 ||
        '\n'.allMatches(text).length > 512 ||
        _deepBlock.hasMatch(text)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Large or deeply nested message shown as plain text.'),
          const SizedBox(height: 8),
          SelectableText(text, style: body),
        ],
      );
    }
    return SelectionArea(
      child: MarkdownBody(
        data: text,
        fitContent: false,
        softLineBreak: true,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        blockSyntaxes: const [_LiteralHtmlBlockSyntax()],
        inlineSyntaxes: [_PullRequestLinkSyntax()],
        onTapLink: (_, href, _) {
          unawaited(_openLink(href));
        },
        imageBuilder: (_, _, alt) => Text(
          alt == null || alt.isEmpty
              ? '[Image not loaded]'
              : '[Image not loaded: $alt]',
          style: body.copyWith(color: AppTheme.muted),
        ),
        checkboxBuilder: (checked) => Semantics(
          label: 'Task',
          checked: checked,
          child: ExcludeSemantics(
            child: Icon(
              checked
                  ? Icons.check_box_outlined
                  : Icons.check_box_outline_blank,
              size: 20,
              color: AppTheme.ink,
            ),
          ),
        ),
        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
          p: body,
          a: const TextStyle(
            color: AppTheme.info,
            decoration: TextDecoration.underline,
          ),
          strong: const TextStyle(
            fontWeight: FontWeight.bold,
            color: AppTheme.markdownBold,
          ),
          h1: body.copyWith(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
          h2: body.copyWith(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
          h3: body.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
          h4: body.copyWith(fontWeight: FontWeight.w700),
          h5: body.copyWith(fontWeight: FontWeight.w700),
          h6: body.copyWith(fontWeight: FontWeight.w700),
          blockSpacing: 12,
          listBullet: body,
          listIndent: 24,
          code: code,
          codeblockPadding: const EdgeInsets.all(12),
          codeblockDecoration: BoxDecoration(
            color: AppTheme.codeSurface,
            border: Border.all(color: AppTheme.border),
            borderRadius: BorderRadius.circular(8),
          ),
          blockquote: body.copyWith(color: AppTheme.muted),
          blockquotePadding: const EdgeInsets.all(12),
          blockquoteDecoration: const BoxDecoration(
            border: Border(
              left: BorderSide(color: AppTheme.selectedBorder, width: 3),
            ),
          ),
          tableHead: body.copyWith(fontWeight: FontWeight.w700),
          tableBody: body,
          tableHeadAlign: TextAlign.left,
          tableColumnWidth: const FixedColumnWidth(176),
          tableCellsPadding: const EdgeInsets.all(12),
          tableBorder: TableBorder.all(color: AppTheme.border),
          horizontalRuleDecoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppTheme.border)),
          ),
        ),
      ),
    );
  }
}

/// Inline parsing leaves fenced/inline code and literal HTML untouched. Avoid
/// rewriting an existing Markdown link's label into a nested anchor as well.
class _PullRequestLinkSyntax extends md.InlineSyntax {
  _PullRequestLinkSyntax()
    : super(pullRequestLinkPattern, caseSensitive: false);

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final position = startMatchPos ?? parser.pos;
    final match = pattern.matchAsPrefix(parser.source, position);
    if (match == null || parseWebLink(match.group(2)) == null) return false;
    if (parser.source.lastIndexOf('[', position) >
        parser.source.lastIndexOf(']', position)) {
      return false;
    }
    return super.tryMatch(parser, startMatchPos);
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element.text('a', match.group(1)!)
        ..attributes['href'] = match.group(2)!,
    );
    return true;
  }
}

class _LiteralHtmlBlockSyntax extends md.HtmlBlockSyntax {
  const _LiteralHtmlBlockSyntax();

  @override
  md.Node parse(md.BlockParser parser) =>
      md.Element('p', [super.parse(parser)]);
}
