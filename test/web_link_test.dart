import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/data/external_link_opener.dart';
import 'package:openremotecode/features/chat/domain/web_link.dart';
import 'package:openremotecode/features/chat/ui/web_link_text.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

void main() {
  test('only bounded absolute HTTP/S URLs without credentials or control characters are allowed', () {
    for (final value in [
      'https://example.invalid/page?q=hello%20world#section',
      'http://localhost:8080/path',
      'https://[::1]:8443/',
      'HTTPS://example.invalid/',
    ]) {
      expect(parseWebLink(value), isNotNull, reason: value);
    }
    for (final value in <String?>[
      null,
      '',
      '/local/file',
      '//example.invalid/',
      '#section',
      'javascript:alert(1)',
      'data:text/html,a',
      'file:///tmp/file',
      'mailto:a@example.invalid',
      'intent://test',
      'https://',
      'https:///path',
      'https://user:password@example.invalid/',
      'https://example.invalid:99999/',
      'https://example.invalid:0/',
      'https://example.invalid/\nsecret',
      'https://example.invalid/\u202ehidden',
      r'https://example.invalid\@other.invalid/',
      'https://example.invalid/${'a' * 4096}',
    ]) {
      expect(parseWebLink(value), isNull, reason: value);
    }
  });

  test('literal links retain text offsets and punctuation and are bounded', () {
    const text =
        'Use (https://example.invalid/a), then https://example.invalid/a_(b).';
    final links = messageWebLinks(text).toList();
    expect(links.map((link) => link.text), [
      'https://example.invalid/a',
      'https://example.invalid/a_(b)',
    ]);
    for (final link in links) {
      expect(text.substring(link.start, link.end), link.text);
    }
    expect(messageWebLinks('https://example.invalid/ ' * 100).length, 64);
    expect(messageWebLinks('https://example.invalid/${')' * 32000}'), isEmpty);
  });

  test('the native opener never receives blocked URLs and handles platform failures', () async {
    final launched = <Uri>[];
    final opener = ExternalLinkOpener(
      launch: (uri) async {
        launched.add(uri);
        return true;
      },
    );
    expect(await opener.open('file:///local/file'), isFalse);
    expect(await opener.open('https://example.invalid/path'), isTrue);
    expect(launched, [Uri.parse('https://example.invalid/path')]);
    expect(
      await ExternalLinkOpener(launch: (_) async => false)
          .open('https://example.invalid/'),
      isFalse,
    );
    expect(
      await ExternalLinkOpener(launch: (_) async => throw StateError('PRIVATE'))
          .open('https://example.invalid/'),
      isFalse,
    );
  });

  test('PR compaction retains source offsets, punctuation and destinations independently', () {
    const source =
        'Merged PR #17 (https://github.com/a/b/pull/17), '
        'then PR #18 (https://example.invalid/path_(v2)). '
        'See https://example.invalid/docs.';
    final links = messageWebLinks(source).toList();
    expect(links.map((link) => link.label), [
      'PR #17',
      'PR #18',
      'https://example.invalid/docs',
    ]);
    expect(links.map((link) => link.text), [
      'https://github.com/a/b/pull/17',
      'https://example.invalid/path_(v2)',
      'https://example.invalid/docs',
    ]);
    var offset = 0;
    final displayed = StringBuffer();
    for (final link in links) {
      displayed.write(source.substring(offset, link.start));
      displayed.write(link.label);
      offset = link.end;
    }
    displayed.write(source.substring(offset));
    expect(
      displayed.toString(),
      'Merged PR #17, then PR #18. See https://example.invalid/docs.',
    );
    expect(
      messageWebLinks('PR #17 (https://user:password@example.invalid)'),
      isEmpty,
    );
    expect(
      messageWebLinks('PR #17 (https://example.invalid').single.label,
      'https://example.invalid',
    );
  });

  testWidgets(
    'plain PR references display a selectable label and confirm the hidden destination',
    (tester) async {
      final opened = <Uri>[];
      final opener = ExternalLinkOpener(
        launch: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      const url = 'https://github.com';
      const source = 'PR #17 (https://github.com)';
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: WebLinkText(text: source, linkOpener: opener),
          ),
        ),
      );
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(selectable.textSpan!.toPlainText(), 'PR #17');
      expect(tester.widget<WebLinkText>(find.byType(WebLinkText)).text, source);
      final spans = selectable.textSpan!.children!
          .whereType<TextSpan>()
          .where((span) => span.recognizer != null)
          .toList();
      expect(spans.length, 1);
      expect(spans.single.text, 'PR #17');
      expect(opened, isEmpty);
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final caret = editable.getLocalRectForCaret(
        const TextPosition(offset: 3),
      );
      await tester.tapAt(editable.localToGlobal(caret.center));
      await tester.pumpAndSettle();
      expect(find.text('Open external link?'), findsOneWidget);
      expect(opened, isEmpty);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse(url)]);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
