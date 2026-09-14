import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/features/chat/ui/markdown_message.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

const _plainNotice = 'Large or deeply nested message shown as plain text.';

void main() {
  testWidgets('inline GFM has styled selectable text without source markers', (
    tester,
  ) async {
    final copied = _interceptClipboard(tester);
    await _show(tester, 'Body **bold** *italic* ~~removed~~ `inline()`');

    expect(_selectableText(tester), 'Body bold italic removed inline()');
    expect(_style(tester, 'Body').fontSize, 16);
    expect(_style(tester, 'Body').color, AppTheme.ink);
    expect(_style(tester, 'bold').fontWeight, FontWeight.bold);
    expect(_style(tester, 'bold').color, AppTheme.markdownBold);
    expect(_style(tester, 'bold').backgroundColor, isNull);
    expect(_style(tester, 'italic').fontStyle, FontStyle.italic);
    expect(_style(tester, 'removed').decoration, TextDecoration.lineThrough);
    expect(_style(tester, 'inline()').fontFamily, 'monospace');
    expect(_style(tester, 'inline()').fontSize, 14);
    expect(_style(tester, 'inline()').color, AppTheme.ink);
    expect(_style(tester, 'inline()').backgroundColor, AppTheme.codeSurface);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(EditableText), findsNothing);
    final richText = _markdownText();
    expect(richText, findsOneWidget);
    expect(tester.widget<RichText>(richText).selectionRegistrar, isNotNull);
    expect(
      tester.getSemantics(richText),
      isSemantics(
        label: 'Body bold italic removed inline()',
        isTextField: false,
        hasSetTextAction: false,
      ),
    );
    await tester.longPressAt(_wordCenter(tester, richText, 0, 4));
    await tester.pumpAndSettle();
    expect(tester.renderObject<RenderParagraph>(richText).selections, [
      const TextSelection(baseOffset: 0, extentOffset: 4),
    ]);
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, ['Body']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('headings use the app hierarchy rather than literal hashes', (
    tester,
  ) async {
    await _show(tester, '# First\n\n## Second\n\n### Third\n\nBody');
    expect(_selectableText(tester), 'First\nSecond\nThird\nBody');
    for (final (text, size) in [('First', 24), ('Second', 22), ('Third', 18)]) {
      expect(_style(tester, text).fontSize, size);
      expect(_style(tester, text).fontWeight, FontWeight.w700);
      expect(_style(tester, text).color, AppTheme.ink);
    }
    expect(_style(tester, 'Body').fontSize, 16);
    expect(tester.takeException(), isNull);
  });

  testWidgets('paragraphs, lists, quotes and tasks retain their structure', (
    tester,
  ) async {
    await _show(
      tester,
      'First line\nsoft break\n\nNext paragraph\n\n'
      '- Apple\n- Pear\n\n7. Seven\n8. Eight\n\n'
      '> Quoted **words**\n\n- [x] Complete\n- [ ] Pending',
    );
    expect(
      find.text('First line\nsoft break', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Next paragraph', findRichText: true), findsOneWidget);
    final text = _selectableText(tester);
    for (final content in [
      'Apple',
      'Pear',
      'Seven',
      'Eight',
      'Quoted words',
      'Complete',
      'Pending',
    ]) {
      expect(text, contains(content));
    }
    for (final marker in ['- ', '> ', '**', '[x]', '[ ]']) {
      expect(text, isNot(contains(marker)));
    }
    expect(find.text('7.'), findsOneWidget);
    expect(find.text('8.'), findsOneWidget);
    expect(text, contains('7.\nSeven'));
    expect(text, contains('8.\nEight'));
    expect(_style(tester, 'Quoted').color, AppTheme.muted);
    expect(_style(tester, 'words').fontWeight, FontWeight.bold);
    final tasks = find.bySemanticsLabel('Task');
    expect(tasks, findsNWidgets(2));
    expect(
      tester.getSemantics(tasks.at(0)),
      isSemantics(label: 'Task', hasCheckedState: true, isChecked: true),
    );
    expect(
      tester.getSemantics(tasks.at(1)),
      isSemantics(label: 'Task', hasCheckedState: true, isChecked: false),
    );
    expect(find.byIcon(Icons.check_box_outlined), findsOneWidget);
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
    expect(tester.takeException(), isNull);

    final copied = _interceptClipboard(tester);
    await _show(tester, 'First **paragraph**.\n\nSecond *paragraph*.');
    final paragraphs = _markdownText();
    expect(paragraphs, findsNWidgets(2));
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byType(EditableText), findsNothing);
    await tester.longPressAt(_wordCenter(tester, paragraphs.first, 0, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      final paragraph = tester.renderObject<RenderParagraph>(paragraphs.at(i));
      expect(paragraph.selections, [
        TextSelection(
          baseOffset: 0,
          extentOffset: paragraph.text.toPlainText().length,
        ),
      ]);
    }
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    // Flutter concatenates selected leaves; paragraph spacing is layout only.
    expect(copied, ['First paragraph.Second paragraph.']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('raw code survives an unclosed fence and same-widget updates', (
    tester,
  ) async {
    const code = '  <b>**literal**</b>\n\tvalue = `raw`;\n    end';
    await _show(tester, '```html\n$code');
    final element = tester.element(find.byType(MarkdownMessage));
    expect(_selectableText(tester), code);
    expect(_style(tester, 'literal').fontFamily, 'monospace');
    expect(_style(tester, 'literal').fontSize, 14);
    final decoration =
        tester
                .widget<MarkdownBody>(find.byType(MarkdownBody))
                .styleSheet!
                .codeblockDecoration!
            as BoxDecoration;
    expect(decoration.color, AppTheme.codeSurface);
    expect(decoration.border, Border.all(color: AppTheme.border));
    expect(_style(tester, 'literal').fontWeight, isNot(FontWeight.bold));
    final codeText = _markdownText();
    expect(codeText, findsOneWidget);
    final start = code.indexOf('value');
    await tester.longPressAt(_wordCenter(tester, codeText, start, start + 5));
    await tester.pumpAndSettle();
    expect(tester.renderObject<RenderParagraph>(codeText).selections, [
      TextSelection(baseOffset: start, extentOffset: start + 5),
    ]);
    expect(find.text('Copy'), findsOneWidget);

    await _show(tester, '```html\n$code\n```\n\n**Finished**');
    expect(tester.element(find.byType(MarkdownMessage)), same(element));
    expect(_selectableText(tester), '$code\nFinished');
    expect(_style(tester, 'Finished').fontWeight, FontWeight.bold);
    await _show(tester, '**Final**');
    expect(tester.element(find.byType(MarkdownMessage)), same(element));
    expect(_selectableText(tester), 'Final');
    expect(_style(tester, 'Final').fontWeight, FontWeight.bold);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HTML blocks remain literal native text without resource IO', (
    tester,
  ) async {
    final calls = _interceptPlatform(tester);
    var httpClients = 0;
    const html =
        '<div>literal HTML</div>\n\n'
        '<script>alert("synthetic")</script>\n\n'
        '<img src="https://example.invalid/html.png">';
    await HttpOverrides.runZoned(
      () => _show(tester, html),
      createHttpClient: (_) {
        httpClients++;
        throw StateError('Unexpected HTTP client in synthetic Markdown test');
      },
    );
    expect(httpClients, 0);
    expect(calls, isEmpty);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(AndroidView), findsNothing);
    expect(find.byType(UiKitView), findsNothing);
    expect(tester.takeException(), isNull);
    final rendered = _selectableText(tester);
    expect(rendered, contains('<div>literal HTML</div>'));
    expect(rendered, contains('<script>alert("synthetic")</script>'));
    expect(rendered, contains('<img src="https://example.invalid/html.png">'));
  });

  testWidgets('links expose destinations without even no-op link recognizers', (
    tester,
  ) async {
    final calls = _interceptPlatform(tester);
    var httpClients = 0;
    const destinations = [
      'https://example.invalid/page',
      'http://example.invalid/plain',
      'javascript:alert%281%29',
      'data:text/html,synthetic',
      'file:///synthetic.txt',
      'mailto:test@example.invalid',
      'intent://synthetic',
      '/relative/path',
      '#section',
    ];
    await HttpOverrides.runZoned(
      () async {
        for (final destination in destinations) {
          await _show(tester, '[**Label**](<$destination>)');
          expect(_selectableText(tester), 'Label ($destination)');
          expect(_style(tester, 'Label').fontWeight, FontWeight.bold);
          _expectPassiveText(tester);
          expect(
            tester.getSemantics(_markdownText()),
            isSemantics(
              label: 'Label ($destination)',
              isLink: false,
              isTextField: false,
              hasTapAction: false,
              hasSetTextAction: false,
            ),
          );
          await tester.tap(_markdownText());
          await tester.pumpAndSettle();
          expect(_selectableText(tester), 'Label ($destination)');
          expect(tester.takeException(), isNull);
        }
        await _show(
          tester,
          '<https://example.invalid/auto>\n\n'
          '[Reference][ref]\n\n[ref]: https://example.invalid/reference',
        );
        expect(
          _selectableText(tester),
          'https://example.invalid/auto\n'
          'Reference (https://example.invalid/reference)',
        );
        _expectPassiveText(tester);
        await tester.pumpWidget(const SizedBox());
      },
      createHttpClient: (_) {
        httpClients++;
        throw StateError('Unexpected HTTP client in synthetic Markdown test');
      },
    );
    expect(httpClients, 0);
    expect(calls, isEmpty);
  });

  testWidgets('all image sources become blocked alt text without resource IO', (
    tester,
  ) async {
    final calls = _interceptPlatform(tester);
    var httpClients = 0;
    const sources = [
      'https://example.invalid/image.png',
      'http://example.invalid/image.png',
      'file:///synthetic/image.png',
      '/synthetic/image.png',
      'data:image/png;base64,AA==',
      'asset:synthetic/image.png',
      'images/synthetic.png',
      '//example.invalid/image.png',
    ];
    await HttpOverrides.runZoned(
      () async {
        for (final source in sources) {
          await _show(tester, '![Synthetic alt](<$source>)\n\n![](<$source>)');
          expect(
            find.text('[Image not loaded: Synthetic alt]'),
            findsOneWidget,
          );
          expect(find.text('[Image not loaded]'), findsOneWidget);
          expect(find.byType(Image), findsNothing);
          expect(find.byType(RawImage), findsNothing);
          expect(find.byType(AndroidView), findsNothing);
          expect(find.byType(UiKitView), findsNothing);
          expect(tester.takeException(), isNull);
        }
        await _show(
          tester,
          '[![Linked alt](https://example.invalid/image.png)]'
          '(javascript:synthetic)',
        );
        expect(find.text('[Image not loaded: Linked alt]'), findsOneWidget);
        expect(_selectableText(tester), contains('(javascript:synthetic)'));
        _expectPassiveText(tester);
        await tester.tap(find.text('[Image not loaded: Linked alt]'));
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      createHttpClient: (_) {
        httpClients++;
        throw StateError('Unexpected HTTP client in synthetic Markdown test');
      },
    );
    expect(httpClients, 0);
    expect(calls, isEmpty);
  });

  testWidgets('320px large text scrolls code and wide tables horizontally', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final code = 'start_${'long_value_' * 40}end';
    final model = ChatViewModel(_NoChatIO(), 'synthetic-connector')
      ..conversation.messages = [
        ChatMessage(
          'wide',
          'assistant',
          '${'Context paragraph.\n\n' * 12}```text\n$code\n```\n\n'
              '| First | Middle | Last |\n| --- | --- | --- |\n'
              '| Alpha | Beta | Omega |',
          false,
        ),
      ];
    final scrollController = ScrollController();
    try {
      // Exercise the renderer independently, then repeat in the real chat list.
      for (final surface in [
        ListView(
          controller: scrollController,
          reverse: true,
          padding: const EdgeInsets.all(20),
          children: [
            MarkdownMessage(text: model.conversation.messages.single.text),
          ],
        ),
        ConversationView(model: model.conversation),
      ]) {
        await tester.pumpWidget(_app(surface, scale: 2));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byType(MarkdownMessage),
          findsOneWidget,
          reason: '${surface.runtimeType} must render the assistant message',
        );
        expect(_selectableText(tester), contains(code));
        for (final cell in [
          'First',
          'Middle',
          'Last',
          'Alpha',
          'Beta',
          'Omega',
        ]) {
          expect(_selectableText(tester), contains(cell));
        }
        final table = tester.widget<Table>(find.byType(Table));
        expect((table.defaultColumnWidth as FixedColumnWidth).value, 176);
        expect(_style(tester, 'First').fontWeight, FontWeight.w700);
        expect(_style(tester, 'Alpha').fontSize, 16);
        expect(find.byType(EditableText), findsNothing);
        for (final richText in tester.widgetList<RichText>(_markdownText())) {
          expect(richText.textScaler.scale(16), 32);
          expect(richText.selectionRegistrar, isNotNull);
        }
        expect(find.byType(ListView), findsOneWidget);
        final horizontal = find.byWidgetPredicate(
          (widget) =>
              widget is SingleChildScrollView &&
              widget.scrollDirection == Axis.horizontal,
        );
        expect(horizontal, findsNWidgets(2));
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is SingleChildScrollView &&
                widget.scrollDirection == Axis.vertical,
          ),
          findsNothing,
        );
        final outer = tester
            .widget<ListView>(find.byType(ListView))
            .controller!;
        expect(outer.position.maxScrollExtent, greaterThan(0));
        final verticalOffset = outer.offset;
        final offsets = <String, double>{};
        for (var i = 0; i < 2; i++) {
          final scroll = tester.widget<SingleChildScrollView>(horizontal.at(i));
          expect(scroll.controller!.position.maxScrollExtent, greaterThan(0));
          await tester.drag(horizontal.at(i), const Offset(-180, 0));
          await tester.pumpAndSettle();
          offsets[i == 0 ? 'code' : 'table'] = scroll.controller!.offset;
          expect(outer.offset, verticalOffset);
          expect(tester.takeException(), isNull);
        }
        expect(offsets, {
          'code': greaterThan(0),
          'table': greaterThan(0),
        }, reason: 'Both regions must scroll when their content is swiped');
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      scrollController.dispose();
      model.dispose();
    }
  });

  testWidgets(
    'character budget preserves the entire message only above 16000',
    (tester) async {
      final boundary = '**${'x' * 15996}**';
      expect(boundary.length, 16000);
      await _show(tester, boundary);
      expect(find.text(_plainNotice), findsNothing);
      expect(_selectableText(tester), 'x' * 15996);
      final oversized = '$boundary!';
      await _show(tester, oversized);
      expect(find.text(_plainNotice), findsOneWidget);
      expect(_selectableText(tester), oversized);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        oversized,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('newline budget falls back above 512 without losing the ending', (
    tester,
  ) async {
    final boundary = '**Start**${'\n' * 512}End';
    await _show(tester, boundary);
    expect(find.text(_plainNotice), findsNothing);
    expect(_selectableText(tester), 'Start\nEnd');
    final oversized = '$boundary\n';
    await _show(tester, oversized);
    expect(find.text(_plainNotice), findsOneWidget);
    expect(_selectableText(tester), oversized);
    expect(tester.takeException(), isNull);
  });

  testWidgets('16 leading markup characters trigger whole-message fallback', (
    tester,
  ) async {
    for (final prefix in [' ' * 16, '\t' * 16, '> ' * 8, '1. ' * 6, '- ' * 8]) {
      final text = '**Before**\n\n${prefix}nested\n\n**After**';
      await _show(tester, text);
      expect(find.text(_plainNotice), findsOneWidget);
      expect(_selectableText(tester), text);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        text,
      );
      expect(tester.takeException(), isNull);
    }
    await _show(tester, '${' ' * 15}literal\n\n**After**');
    expect(find.text(_plainNotice), findsNothing);
    expect(_style(tester, 'After').fontWeight, FontWeight.bold);
    await _show(tester, 'Text ${' ' * 16}**not a leading prefix**');
    expect(find.text(_plainNotice), findsNothing);
    expect(_style(tester, 'not a leading prefix').fontWeight, FontWeight.bold);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ConversationView keeps users raw and updates assistant Markdown',
    (tester) async {
      const source =
          '**Synthetic** `code` [Label](https://example.invalid/page)';
      final model = ChatViewModel(_NoChatIO(), 'synthetic-connector')
        ..conversation.messages = const [
          ChatMessage('user', 'user', source, false),
          ChatMessage('assistant', 'assistant', source, true),
        ];
      try {
        Widget conversation() =>
            _app(ConversationView(model: model.conversation));
        await tester.pumpWidget(conversation());
        await tester.pumpAndSettle();
        final user = find.byKey(const ValueKey('message-user'));
        final assistant = find.byKey(const ValueKey('message-assistant'));
        final userText = find.descendant(
          of: user,
          matching: find.byType(SelectableText),
        );
        expect(
          userText,
          findsOneWidget,
          reason: 'User messages must retain their raw SelectableText',
        );
        expect(tester.widget<SelectableText>(userText).data, source);
        expect(
          find.descendant(of: user, matching: find.byType(MarkdownMessage)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: user,
            matching: find.text('Long message shortened for display.'),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: assistant,
            matching: find.byType(MarkdownMessage),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: assistant, matching: find.byType(SelectionArea)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: assistant, matching: find.byType(EditableText)),
          findsNothing,
        );
        expect(
          _selectableText(tester, assistant),
          'Synthetic code Label (https://example.invalid/page)',
        );
        expect(
          find.descendant(
            of: assistant,
            matching: find.text('Long message shortened for display.'),
          ),
          findsOneWidget,
        );
        final element = tester.element(find.byType(MarkdownMessage));
        model.conversation.messages = const [
          ChatMessage('user', 'user', source, false),
          ChatMessage(
            'assistant',
            'assistant',
            '**Updated**\n\nNew paragraph',
            false,
          ),
        ];
        await tester.pumpWidget(conversation());
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(MarkdownMessage)), same(element));
        expect(_selectableText(tester, assistant), 'Updated\nNew paragraph');
        expect(tester.widget<SelectableText>(userText).data, source);
        expect(find.text('Long message shortened for display.'), findsNothing);
        expect(model.conversation.messages.first.text, source);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      }
    },
  );

  testWidgets('Markdown text parts and passive thoughts render once', (
    tester,
  ) async {
    final model = ChatViewModel(_NoChatIO(), 'synthetic-connector')
      ..conversation.messages = const [
        ChatMessage(
          'parts',
          'assistant',
          '# Before\n\nAfter **done**',
          false,
          parts: [
            ChatMessagePart('first', 'text', '# Before\n\n'),
            ChatMessagePart(
              'thought',
              'reasoning',
              'Synthetic review\n\nHidden **detail**',
              start: 1000,
              end: 2200,
            ),
            ChatMessagePart('last', 'text', 'After **done**'),
            ChatMessagePart('empty', 'text', ''),
          ],
        ),
      ];
    try {
      await tester.pumpWidget(
        _app(ConversationView(model: model.conversation)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownMessage), findsNWidgets(2));
      expect(_selectableText(tester), 'Before\nAfter done');
      expect(
        find.textContaining('Thought: Synthetic review', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('1.2s', findRichText: true), findsOneWidget);
      await tester.tap(
        find.textContaining('Thought: Synthetic review', findRichText: true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownMessage), findsNWidgets(2));
      expect(_selectableText(tester), 'Before\nAfter done');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    }
  });
}

Widget _app(Widget child, {double scale = 1}) => MaterialApp(
  theme: AppTheme.light,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(body: child),
);

Future<void> _show(WidgetTester tester, String text) async {
  await tester.pumpWidget(
    _app(ListView(children: [MarkdownMessage(text: text)])),
  );
  await tester.pumpAndSettle();
}

Finder _markdownText([Finder? within]) => find.descendant(
  of: find.descendant(
    of: within == null
        ? find.byType(MarkdownBody)
        : find.descendant(of: within, matching: find.byType(MarkdownBody)),
    matching: find.byType(Text),
  ),
  matching: find.byType(RichText),
);

String _selectableText(WidgetTester tester, [Finder? within]) {
  final richText = tester.widgetList<RichText>(_markdownText(within)).toList();
  if (richText.isNotEmpty) {
    // Read each Text's rendered leaf once, excluding icon glyphs and UI notices.
    return richText.map((widget) => widget.text.toPlainText()).join('\n');
  }
  return tester
      .widgetList<SelectableText>(
        find.descendant(
          of: within ?? find.byType(MarkdownMessage),
          matching: find.byType(SelectableText),
        ),
      )
      .map((widget) => widget.data ?? widget.textSpan!.toPlainText())
      .join('\n');
}

TextStyle _style(WidgetTester tester, String text) {
  final matches = <TextStyle>[];
  void visit(InlineSpan span, TextStyle inherited) {
    final style = inherited.merge(span.style);
    if (span is TextSpan) {
      if (span.text?.contains(text) ?? false) matches.add(style);
      for (final child in span.children ?? <InlineSpan>[]) {
        visit(child, style);
      }
    }
  }

  for (final widget in tester.widgetList<RichText>(_markdownText())) {
    visit(widget.text, const TextStyle());
  }
  expect(matches, hasLength(1), reason: 'Expected one styled run for $text');
  return matches.single;
}

void _expectPassiveText(WidgetTester tester) {
  // SelectionArea owns gestures outside MarkdownBody; links add none inside it.
  expect(
    find.descendant(
      of: find.byType(MarkdownBody),
      matching: find.byType(GestureDetector),
    ),
    findsNothing,
  );
  expect(
    find.descendant(
      of: find.byType(MarkdownBody),
      matching: find.byType(RawGestureDetector),
    ),
    findsNothing,
  );
  void visit(InlineSpan span) {
    if (span is TextSpan) {
      expect(span.recognizer, isNull);
      for (final child in span.children ?? <InlineSpan>[]) {
        visit(child);
      }
    }
  }

  expect(find.byType(SelectableText), findsNothing);
  expect(find.byType(EditableText), findsNothing);
  final text = tester.widgetList<RichText>(_markdownText()).toList();
  expect(text, isNotEmpty);
  for (final widget in text) {
    visit(widget.text);
  }
}

Offset _wordCenter(WidgetTester tester, Finder text, int start, int end) {
  final paragraph = tester.renderObject<RenderParagraph>(text);
  final box = paragraph
      .getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end))
      .single;
  return paragraph.localToGlobal(box.toRect().center);
}

List<String> _interceptClipboard(WidgetTester tester) {
  final copied = <String>[];
  // Keep synthetic copied text in memory; never touch the host clipboard.
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      if (call.method == 'Clipboard.hasStrings') {
        return {'value': copied.isNotEmpty};
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

List<String> _interceptPlatform(WidgetTester tester) {
  final calls = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  for (final name in [
    'plugins.flutter.io/url_launcher',
    'dev.flutter.pigeon.url_launcher_android.UrlLauncherApi.launchUrl',
    'dev.flutter.pigeon.url_launcher_ios.UrlLauncherApi.launchUrl',
    'flutter/platform_views',
    'flutter/assets',
  ]) {
    messenger.setMockMessageHandler(name, (ByteData? _) async {
      calls.add(name);
      return null;
    });
    addTearDown(() => messenger.setMockMessageHandler(name, null));
  }
  return calls;
}

class _NoChatIO implements ChatRepository {
  @override
  bool chatOnline(String connectorId) => false;

  @override
  Stream<void> get chatConnectionChanges => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected repository call in presentation test');
}
