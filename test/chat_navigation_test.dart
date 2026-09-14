import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/chat_flow_screen.dart';
import 'package:openremotecode/features/chat/ui/chat_details_screen.dart';
import 'package:openremotecode/features/chat/ui/chat_list_view.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/features/connections/domain/remote_connection.dart';
import 'package:openremotecode/features/connections/ui/connection_card.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

void main() {
  testWidgets(
    'polling preserves the oldest cursor and refresh recovers expired history',
    (tester) async {
      final repository = _HistoryChats();
      final model = await _showConversation(tester, repository);
      repository.olderPages.add(
        repository.historyPage(90, 100, cursor: 'oldest'),
      );
      await model.conversation.olderMessages();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(model.conversation.messageCursor, 'oldest');
      expect(model.conversation.messages.length, 20);
      repository.historyFailure = ChatFailure.expired;
      await model.conversation.olderMessages();
      expect(
        model.conversation.earlierMessagesError,
        ChatFailure.expired.message,
      );
      repository.historyFailure = null;
      repository.latestCursor = 'fresh';
      final field = find.byKey(const ValueKey('chat-composer'));
      await tester.enterText(field, 'Keep my unsent message');
      final reads = repository.cursors.length;
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(repository.cursors.skip(reads), [null]);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Keep my unsent message',
      );
      expect(model.conversation.earlierMessagesError, isNull);
      expect(model.conversation.messageCursor, 'fresh');
      expect(model.conversation.messages.length, 10);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'conversation starts at newest and Markdown paging preserves visible rows',
    (tester) async {
      final repository = _HistoryChats()
        ..latest = [
          for (var i = 100; i < 110; i++)
            {
              ..._historyMessage(i),
              if (i.isOdd)
                'text':
                    '### Reply $i\n\n- **Formatted** answer\n- Another item\n\n```dart\nfinal value = $i;\n```',
            },
        ];
      final model = await _showConversation(tester, repository);
      final list = find.descendant(
        of: find.byType(ConversationView),
        matching: find.byType(ListView),
      );
      final scroll = tester.widget<ListView>(list).controller!;
      expect(scroll.offset, 0);
      expect(
        find.byKey(const ValueKey('message-m109')).hitTestable(),
        findsOneWidget,
      );
      expect(repository.cursors, [null]);
      expect(find.text('Load earlier messages'), findsNothing);
      repository.pendingOlder = Completer<Map<String, dynamic>>();
      for (
        var i = 0;
        i < 30 && !model.conversation.loadingEarlierMessages;
        i++
      ) {
        // Short drags enter the prefetch zone without overshooting the oldest row.
        await tester.dragFrom(
          Offset(tester.getTopLeft(list).dx + 8, tester.getCenter(list).dy),
          const Offset(0, 100),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump();
      expect(repository.cursors, [null, 'older']);
      expect(model.conversation.loadingEarlierMessages, isTrue);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Loading earlier messages'), findsOneWidget);
      final anchor = find.byKey(const ValueKey('message-m100'));
      final before = tester.getTopLeft(anchor).dy;
      // Scrolling repeatedly while the request is pending cannot dispatch twice.
      scroll.jumpTo(scroll.offset - 20);
      await tester.pump(const Duration(milliseconds: 100));
      final moved = tester.getTopLeft(anchor).dy;
      expect(moved, isNot(before));
      expect(repository.cursors.length, 2);
      repository.pendingOlder!.complete({
        ...repository.historyPage(90, 100),
        'messages': [
          for (var i = 90; i < 100; i++)
            {
              ..._historyMessage(i),
              if (i.isOdd)
                'text': '> Older reply $i\n\n1. First\n2. Second with `code`',
            },
        ],
      });
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(anchor).dy, closeTo(moved, 0.1));
      expect(model.conversation.messages.length, 20);
      expect(model.conversation.messageCursor, isNull);
      expect(model.conversation.loadingEarlierMessages, isFalse);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('message-m100'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('message-m101'))).dy,
        ),
      );
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'short history pages auto-fill and polling cannot reopen exhausted history',
    (tester) async {
      final repository = _HistoryChats()
        ..latest = [_historyMessage(100, short: true)];
      repository.olderPages.addAll([
        repository.historyPage(0, 0, cursor: 'empty-next'),
        repository.historyPage(99, 100, short: true),
      ]);
      final model = await _showConversation(tester, repository);
      expect(repository.cursors, [null, 'older', 'empty-next']);
      expect(model.conversation.messages.map((m) => m.id), ['m99', 'm100']);
      expect(model.conversation.messageCursor, isNull);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(repository.cursors, [null, 'older', 'empty-next', null]);
      expect(model.conversation.messageCursor, isNull);
      expect(model.conversation.messages.length, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'history failures retain messages and polling never automatically retries them',
    (tester) async {
      final repository = _HistoryChats()
        ..latest = [_historyMessage(100, short: true)]
        ..historyFailure = ChatFailure.unavailable;
      final model = await _showConversation(tester, repository);
      expect(model.conversation.messages.single.id, 'm100');
      expect(model.conversation.earlierMessagesError, isNotNull);
      expect(model.conversation.messageCursor, 'older');
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(repository.cursors.whereType<String>(), ['older']);
      expect(find.text('Retry loading earlier messages'), findsOneWidget);
      repository.historyFailure = null;
      await tester.tap(find.text('Retry loading earlier messages'));
      await tester.pumpAndSettle();
      expect(model.conversation.messages.length, 11);
      expect(model.conversation.earlierMessagesError, isNull);
      expect(model.conversation.messageCursor, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'offline and background transitions stop history and reject late responses',
    (tester) async {
      final repository = _HistoryChats();
      final model = await _showConversation(tester, repository);
      repository.pendingOlder = Completer<Map<String, dynamic>>();
      final loading = model.conversation.olderMessages();
      await model.conversation.olderMessages();
      expect(repository.cursors, [null, 'older']);
      model.setActive(false);
      expect(model.conversation.loadingEarlierMessages, isFalse);
      repository.pendingOlder!.complete(repository.historyPage(90, 100));
      await loading;
      await model.conversation.olderMessages();
      expect(model.conversation.messages.first.id, 'm100');
      expect(repository.cursors.length, 2);
      repository.online = false;
      repository.changes.add(null);
      await tester.pumpAndSettle();
      model.setActive(true);
      await model.conversation.olderMessages();
      expect(model.conversation.canLoadEarlierMessages, isFalse);
      expect(repository.cursors.length, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'leaving a pending history request cannot populate another chat',
    (tester) async {
      final repository = _HistoryChats();
      final model = await _showConversation(tester, repository);
      repository.pendingOlder = Completer<Map<String, dynamic>>();
      final pending = model.conversation.olderMessages();
      model.backToProjects();
      await tester.pumpAndSettle();
      repository.pendingOlder!.complete(repository.historyPage(90, 100));
      await pending;
      await tester.pumpAndSettle();
      expect(model.page, ChatPage.projects);
      expect(model.conversation.messages, isEmpty);
      expect(model.conversation.messageCursor, isNull);
      expect(model.conversation.loadingEarlierMessages, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'history cap stops at 200 and latest-page polling cannot reload it',
    (tester) async {
      final repository = _HistoryChats();
      final model = await _showConversation(tester, repository);
      for (var page = 0; page < 19; page++) {
        repository.olderPages.add(
          repository.historyPage(
            200 + page * 10,
            210 + page * 10,
            cursor: 'page-$page',
          ),
        );
        await model.conversation.olderMessages();
      }
      expect(model.conversation.messages.length, 200);
      expect(model.conversation.messageCursor, isNull);
      expect(model.conversation.messageHistoryNotice, contains('200'));
      await model.conversation.olderMessages();
      expect(repository.cursors.length, 20);
      repository.latest = [for (var i = 101; i < 111; i++) _historyMessage(i)];
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(model.conversation.messages.length, 200);
      expect(model.conversation.messages.last.id, 'm110');
      expect(model.conversation.messageCursor, isNull);
      expect(repository.cursors.last, isNull);
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(model.conversation.messages.length, 10);
      expect(model.conversation.messageHistoryNotice, isNull);
      expect(model.conversation.messageCursor, 'older');
      expect(repository.cursors.last, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cyclic cursors fail closed and refresh restarts history at newest',
    (tester) async {
      final repository = _HistoryChats();
      final model = await _showConversation(tester, repository);
      repository.olderPages.add(
        repository.historyPage(90, 100, cursor: 'next'),
      );
      await model.conversation.olderMessages();
      repository.olderPages.add(
        repository.historyPage(80, 90, cursor: 'older'),
      );
      await model.conversation.olderMessages();
      expect(model.conversation.messages.length, 20);
      expect(model.conversation.messageCursor, 'next');
      expect(model.conversation.earlierMessagesError, isNotNull);
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(model.conversation.messages.length, 10);
      expect(model.conversation.messageCursor, 'older');
      expect(model.conversation.earlierMessagesError, isNull);
      final list = find.descendant(
        of: find.byType(ConversationView),
        matching: find.byType(ListView),
      );
      expect(tester.widget<ListView>(list).controller!.offset, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'non-progressing empty history is bounded even with unique cursors',
    (tester) async {
      final repository = _HistoryChats();
      final model = await _showConversation(tester, repository);
      for (var page = 0; page < 100; page++) {
        repository.olderPages.add(
          repository.historyPage(0, 0, cursor: 'empty-$page'),
        );
        await model.conversation.olderMessages();
      }
      expect(model.conversation.messages.length, 10);
      expect(model.conversation.messageCursor, isNull);
      expect(model.conversation.messageHistoryNotice, contains('page limit'));
      expect(repository.cursors.length, 101);
      await model.conversation.olderMessages();
      expect(repository.cursors.length, 101);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'empty conversation and history retry fit large text with a keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = _HistoryChats()
        ..latest = []
        ..latestCursor = null;
      final model = await _showConversation(
        tester,
        repository,
        largeText: true,
      );
      expect(
        find.text('Start this conversation with a message.'),
        findsOneWidget,
      );
      repository.latestCursor = 'older';
      repository.historyFailure = ChatFailure.unavailable;
      await model.refresh();
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final semantics = tester.ensureSemantics();
      await tester.ensureVisible(find.text('Retry loading earlier messages'));
      await tester.pumpAndSettle();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'chat sections keep pins first and group each local calendar day',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final repository = _ListChats([
        _chatSummary(
          'saved',
          'Pinned plan',
          today.subtract(const Duration(days: 20)),
        ),
        _chatSummary('recent', 'Current work', now),
        _chatSummary(
          'yesterday',
          'Yesterday work',
          today.subtract(const Duration(hours: 12)),
        ),
        _chatSummary('week', 'Weekly work', DateTime(2025, 9, 4, 23)),
        _chatSummary('same-day', 'Same day work', DateTime(2025, 9, 4, 1)),
        _chatSummary('older', 'Older work', DateTime(2024, 12, 31)),
      ]);
      repository.pins.add('saved');
      addTearDown(repository.changes.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: ChatFlowScreen(
            repository: repository,
            connectorId: 'connector',
            connectionName: 'Laptop',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sample project'));
      await tester.pumpAndSettle();
      final sections = [
        'Pinned',
        'Today',
        'Yesterday',
        'Sep 4 2025',
        'Dec 31 2024',
      ];
      for (var index = 1; index < sections.length; index++) {
        expect(
          tester.getTopLeft(find.text(sections[index - 1])).dy,
          lessThan(tester.getTopLeft(find.text(sections[index])).dy),
        );
      }
      expect(find.text('Pinned plan'), findsOneWidget);
      expect(find.text('Sep 4 2025'), findsOneWidget);
      expect(find.text('Same day work'), findsOneWidget);
      expect(find.text('Search chats'), findsOneWidget);
      await tester.enterText(find.byType(TextField), ' LATER ');
      await tester.pumpAndSettle();
      expect(find.text('No chats match your search.'), findsOneWidget);
      expect(find.text('Pinned'), findsNothing);
      expect(find.text('Load more chats'), findsNothing);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Pinned plan'), findsOneWidget);
      expect(find.text('Current work'), findsOneWidget);
      await tester.tap(find.text('Current work'));
      await tester.pumpAndSettle();
      expect(find.text('A real snapshot'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('scrolling near the bottom loads once with a footer spinner', (
    tester,
  ) async {
    final repository = _ListChats([
      for (var i = 0; i < 30; i++)
        _chatSummary('row-$i', 'Chat $i', DateTime(2025, 9, 4)),
    ])..hasMore = true;
    final model = await _showList(tester, repository);
    expect(repository.cursors, [null]);
    final page = Completer<Map<String, dynamic>>();
    repository.nextPage = page;
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(repository.cursors, [null, 'next-page']);
    expect(model.loadingMoreChats, isTrue);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Load more chats'), findsNothing);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Loading older chats'), findsOneWidget);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 100));
    expect(repository.cursors.length, 2);
    final offset = scroll.offset;
    page.complete(repository.response('chat.list', {'cursor': 'next-page'}));
    await tester.pumpAndSettle();
    expect(model.chatList.chats.length, 31);
    expect(scroll.offset, offset);
    expect(model.chatList.chatCursor, isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(repository.cursors.length, 2);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });

  testWidgets(
    'short child-only pages auto-fill until the terminal empty page',
    (tester) async {
      final repository = _ListChats([])..hasMore = true;
      repository.pages.addAll([
        {
          'version': 1,
          'chats': [
            {
              ..._chatSummary('child', 'Hidden', DateTime.now()),
              'parentId': 'parent',
            },
          ],
          'cursor': 'third',
        },
        {
          'version': 1,
          'chats': [_chatSummary('main', 'Visible chat', DateTime.now())],
          'cursor': 'last',
        },
        {'version': 1, 'chats': [], 'cursor': null},
      ]);
      final model = await _showList(tester, repository);
      expect(repository.cursors, [null, 'next-page', 'third', 'last']);
      expect(model.chatList.chats.single.id, 'main');
      expect(find.text('Visible chat'), findsOneWidget);
      expect(model.chatList.chatCursor, isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'search debounces and automatically reaches older matching chats',
    (tester) async {
      final repository = _ListChats([
        for (var i = 0; i < 30; i++)
          _chatSummary('row-$i', 'Chat $i', DateTime.now()),
      ])..hasMore = true;
      final model = await _showList(tester, repository);
      await tester.enterText(find.byType(TextField), 'LATE');
      await tester.pump(const Duration(milliseconds: 200));
      expect(repository.cursors, [null]);
      await tester.enterText(find.byType(TextField), ' LATER ');
      await tester.pump(const Duration(milliseconds: 200));
      expect(repository.cursors, [null]);
      repository.nextPage = Completer<Map<String, dynamic>>();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(repository.cursors, [null, 'next-page']);
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Searching older chats'), findsOneWidget);
      repository.nextPage!.complete(
        repository.response('chat.list', {'cursor': 'next-page'}),
      );
      await tester.pumpAndSettle();
      expect(find.text('Later work'), findsOneWidget);
      expect(find.text('Search chats'), findsOneWidget);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets('pagination failures retain rows and require explicit retry', (
    tester,
  ) async {
    final repository =
        _ListChats([_chatSummary('main', 'Keep this chat', DateTime.now())])
          ..hasMore = true
          ..listFailure = ChatFailure.unavailable;
    final model = await _showList(tester, repository);
    expect(model.chatList.chats.single.id, 'main');
    expect(model.chatList.moreChatsError, isNotNull);
    expect(model.chatList.chatCursor, 'next-page');
    expect(repository.cursors.length, 2);
    await tester.pump(const Duration(seconds: 2));
    expect(repository.cursors.length, 2);
    repository.online = false;
    repository.changes.add(null);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Retry loading chats'),
          )
          .onPressed,
      isNull,
    );
    repository.online = true;
    repository.listFailure = null;
    repository.changes.add(null);
    await tester.pumpAndSettle();
    expect(model.chatList.moreChatsError, isNull);
    expect(model.chatList.chatCursor, isNull);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });

  testWidgets(
    'retry loads a failed continuation without losing existing chats',
    (tester) async {
      final repository =
          _ListChats([_chatSummary('main', 'Keep this chat', DateTime.now())])
            ..hasMore = true
            ..listFailure = ChatFailure.unavailable;
      final model = await _showList(tester, repository);
      repository.listFailure = null;
      await tester.tap(find.text('Retry loading chats'));
      await tester.pumpAndSettle();
      expect(model.chatList.chats.map((chat) => chat.id), ['main', 'later']);
      expect(model.chatList.moreChatsError, isNull);
      expect(repository.cursors, [null, 'next-page', 'next-page']);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'leaving a pending page ignores its response and disposes callbacks',
    (tester) async {
      final repository = _ListChats([])..hasMore = true;
      final page = Completer<Map<String, dynamic>>();
      repository.nextPage = page;
      final model = await _showList(tester, repository, settle: false);
      await tester.pump();
      expect(model.loadingMoreChats, isTrue);
      model.backToProjects();
      page.complete(repository.response('chat.list', {'cursor': 'next-page'}));
      await tester.pumpAndSettle();
      expect(model.chatList.chats, isEmpty);
      expect(model.chatList.chatCursor, isNull);
      expect(model.loadingMoreChats, isFalse);
      await tester.enterText(find.byType(TextField), 'pending debounce');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      model.dispose();
    },
  );

  testWidgets(
    'chat list fits large text and a keyboard with accessible controls',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repository = _ListChats([
        _chatSummary(
          'long',
          'A long conversation title that still needs room to wrap on a small phone',
          DateTime.now(),
        ),
      ]);
      addTearDown(repository.changes.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ChatFlowScreen(
            repository: repository,
            connectorId: 'connector',
            connectionName: 'Laptop',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Sample project'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sample project'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final semantics = tester.ensureSemantics();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
      await tester.enterText(find.byType(TextField), 'missing');
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byTooltip('Clear search'));
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      repository.online = false;
      repository.changes.add(null);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Offline'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithIcon(FilledButton, Icons.add))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final draft in [false, true]) {
    testWidgets(
      'title opens details once and back reconciles ${draft ? 'new draft' : 'chat history and draft'} without mutations',
      (tester) async {
        final repository = _HistoryChats();
        final model = await _showConversation(tester, repository, draft: draft);
        final field = find.byKey(const ValueKey('chat-composer'));
        await tester.enterText(field, 'Unsent private draft');
        final input = tester.widget<TextField>(field).controller;
        final conversation = tester.state(find.byType(ConversationView));
        final messages = model.conversation.messages;
        final key = model.conversation.composerKey;
        final revision = model.conversation.messageHistoryRevision;
        final reads = repository.cursors.toList();
        final list = find.descendant(
          of: find.byType(ConversationView),
          matching: find.byType(ListView),
        );
        final scroll = tester.widget<ListView>(list).controller!;
        if (!draft) scroll.jumpTo(80);
        await tester.pump();
        final offset = scroll.offset;
        repository.operations.clear();
        final title = draft ? 'New chat' : 'Existing chat';
        final semantics = tester.ensureSemantics();
        expect(
          find.bySemanticsLabel('$title, open chat details'),
          findsOneWidget,
        );
        expect(find.byTooltip('Laptop · Projects'), findsNothing);
        expect(find.byTooltip('Sample project · Chats'), findsNothing);
        expect(find.byTooltip('Refresh'), findsNothing);
        expect(find.byIcon(Icons.more_vert), findsOneWidget);
        final dot = tester.widget<Icon>(find.byIcon(Icons.circle));
        expect(dot.size, 10);
        expect(dot.color, AppTheme.success);
        final scaffold = tester.widget<Scaffold>(
          find.ancestor(of: field, matching: find.byType(Scaffold)).first,
        );
        expect(scaffold.backgroundColor, AppTheme.chatBackground);
        final header = tester.widget<AppBar>(find.byType(AppBar));
        expect(header.backgroundColor, AppTheme.chatBackground);
        expect(header.surfaceTintColor, Colors.transparent);
        expect(header.scrolledUnderElevation, 0);
        final inputDecoration = tester.widget<InputDecorator>(
          find.descendant(of: field, matching: find.byType(InputDecorator)),
        );
        expect(inputDecoration.decoration.fillColor, AppTheme.inputSurface);
        expect(
          inputDecoration.decoration.enabledBorder!.borderSide.color,
          AppTheme.softBorder,
        );
        expect(inputDecoration.decoration.enabledBorder!.borderSide.width, 0.5);
        expect(
          tester
              .widget<EditableText>(
                find.descendant(of: field, matching: find.byType(EditableText)),
              )
              .style
              .color,
          AppTheme.ink,
        );
        expect(find.byTooltip('Online'), findsOneWidget);

        final openDetails = tester
            .widget<TextButton>(
              find.descendant(
                of: find.byTooltip(title),
                matching: find.byType(TextButton),
              ),
            )
            .onPressed!;
        await tester.tap(find.byTooltip(title));
        // Exercise a queued second activation even though the route blocks hits.
        openDetails();
        await tester.pumpAndSettle();
        expect(
          find.byType(ChatDetailsScreen, skipOffstage: false),
          findsOneWidget,
        );
        expect(
          tester
              .widget<ChatDetailsScreen>(find.byType(ChatDetailsScreen))
              .model,
          same(model.conversation),
        );
        expect(find.text(title), findsOneWidget);
        expect(find.text('Online'), findsNothing);
        expect(
          find.text('Chat status: ${draft ? 'Draft' : 'Idle'}'),
          findsNothing,
        );
        expect(find.text('Location'), findsNothing);
        expect(find.byTooltip('Laptop · Projects'), findsNothing);
        expect(find.byTooltip('Sample project · Chats'), findsNothing);
        expect(find.text('/work/sample'), findsNothing);
        if (draft) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.pageBack();
        }
        await tester.pumpAndSettle();
        expect(
          find.byType(ChatDetailsScreen, skipOffstage: false),
          findsNothing,
        );
        expect(model.page, ChatPage.conversation);
        expect(model.conversation.isDraft, draft);
        expect(model.conversation.composerKey, key);
        expect(
          model.conversation.messages.map((m) => (m.id, m.text)),
          messages.map((m) => (m.id, m.text)),
        );
        expect(model.conversation.messageHistoryRevision, revision);
        expect(tester.state(find.byType(ConversationView)), same(conversation));
        expect(tester.widget<TextField>(field).controller, same(input));
        expect(input!.text, 'Unsent private draft');
        expect(scroll.offset, offset);
        expect(repository.operations, isEmpty);
        expect(repository.cursors, draft ? reads : [...reads, null]);
        expect(repository.creates, 0);
        expect(repository.prompts, 0);
        // The duplicate guard must also release after returning.
        await tester.tap(find.byTooltip(title));
        await tester.pumpAndSettle();
        expect(find.byType(ChatDetailsScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        semantics.dispose();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final invalidation in ['trust', 'source']) {
    testWidgets(
      'details clear during exit and dismiss after $invalidation loss',
      (tester) async {
        final repository = _Chats();
        final model = await _showConversation(tester, repository);
        final field = find.byKey(const ValueKey('chat-composer'));
        await tester.enterText(field, 'Sensitive draft');
        final input = tester.widget<TextField>(field).controller!;
        await tester.tap(find.byTooltip('Existing chat'));
        await tester.pumpAndSettle();
        expect(find.byType(ChatDetailsScreen), findsOneWidget);
        repository.operations.clear();
        if (invalidation == 'trust') {
          repository.trusted = false;
          repository.online = false;
          repository.changes.add(null);
        } else {
          model.backToProjects();
        }
        await tester.pump();
        if (invalidation == 'trust') expect(model.trustLost, isTrue);
        await tester.pump();
        final details = find.byType(ChatDetailsScreen, skipOffstage: false);
        expect(details, findsOneWidget);
        expect(
          find.descendant(
            of: details,
            matching: find.text('Existing chat', skipOffstage: false),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: details,
            matching: find.byType(TextButton, skipOffstage: false),
          ),
          findsNothing,
        );
        await tester.pumpAndSettle();
        expect(details, findsNothing);
        expect(model.page, ChatPage.projects);
        expect(model.conversation.chat, isNull);
        expect(model.project, isNull);
        expect(model.conversation.messages, isEmpty);
        if (invalidation == 'trust') {
          expect(input.text, isEmpty);
          expect(model.projects.projects, isEmpty);
          expect(
            find.text('Sensitive draft', skipOffstage: false),
            findsNothing,
          );
          expect(find.text('Existing chat', skipOffstage: false), findsNothing);
          expect(repository.operations, isEmpty);
        }
        expect(repository.creates, 0);
        expect(repository.prompts, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'details wrap a long title at 320px and 2x text with accessible actions',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const project = 'a-very-long-project-folder-name-that-must-wrap';
      const title =
          'A full conversation title that must remain readable on a narrow phone';
      final repository = _ListChats([
        _chatSummary('session', title, DateTime(2025, 9, 4)),
      ])..projectName = project;
      final model = ChatViewModel(repository, 'connector');
      addTearDown(repository.changes.close);
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      await model.openChat(model.chatList.chats.single);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ChatDetailsScreen(model: model.conversation),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final semantics = tester.ensureSemantics();
      await tester.scrollUntilVisible(find.text(title), 150);
      await tester.pumpAndSettle();
      final heading = tester.widget<Text>(find.text(title));
      expect(heading.maxLines, isNull);
      expect(heading.overflow, isNot(TextOverflow.ellipsis));
      expect(tester.getSize(find.text(title)).height, greaterThan(60));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      expect(tester.takeException(), isNull);
      // The breadcrumb and project path no longer appear here.
      expect(find.text(project, skipOffstage: false), findsNothing);
      expect(find.text('Project path', skipOffstage: false), findsNothing);
      expect(find.text('/work/sample', skipOffstage: false), findsNothing);
      for (final label in ['Fork chat', 'Delete chat']) {
        final action = find.widgetWithText(TextButton, label);
        await tester.scrollUntilVisible(action, 150);
        await tester.pumpAndSettle();
        expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      }
      await tester.tap(find.widgetWithText(TextButton, 'Delete chat'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repository.deletes, 0);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  test('refresh removes a saved pin only when OpenCode confirms the chat is missing', () async {
    final repository = _Chats()..getFailure = ChatFailure.unavailable;
    repository.pins.add('gone');
    final model = ChatViewModel(repository, 'connector');
    addTearDown(() {
      model.dispose();
      repository.changes.close();
    });
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    expect(repository.pins, {'gone'});
    repository.getFailure = ChatFailure.notFound;
    await model.refresh();
    expect(repository.pins, isEmpty);
    expect(model.chatList.chats.map((c) => c.id), ['session']);
  });
  test(
    'pin/unpin reorders chats and restores an older pin beyond the first page',
    () async {
      final repository = _Chats();
      final model = ChatViewModel(repository, 'connector');
      addTearDown(() {
        model.dispose();
        repository.changes.close();
      });
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      model.chatList.chatCursor = 'next';
      await model.moreChats();
      final older = model.chatList.chats.last;
      await model.togglePin(older);
      expect(model.chatList.chats.first.id, 'later');
      await model.refresh();
      expect(model.chatList.chats.map((c) => c.id), ['later', 'session']);
      expect(repository.operations, contains('chat.get'));
      await model.togglePin(model.chatList.chats.first);
      expect(model.chatList.chats.map((c) => c.id), ['session', 'later']);
      expect(repository.pins, isEmpty);
    },
  );

  test('failed pin or delete keeps the row and its saved pin', () async {
    final repository = _Chats()..pinFailure = ChatFailure.pinStorage;
    final model = ChatViewModel(repository, 'connector');
    addTearDown(() {
      model.dispose();
      repository.changes.close();
    });
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    final chat = model.chatList.chats.single;
    await model.togglePin(chat);
    expect(model.chatList.isPinned(chat), isFalse);
    repository.pinFailure = null;
    await model.togglePin(chat);
    for (final failure in [
      ChatFailure.uncertain,
      ChatFailure.chatBusy,
      ChatFailure.denied,
    ]) {
      repository.deleteFailure = failure;
      await model.deleteChat(chat);
      expect(model.chatList.chats.single.id, chat.id);
      expect(model.chatList.isPinned(chat), isTrue);
      expect(model.error, isNotNull);
    }
    repository.deleteFailure = null;
    await model.deleteChat(chat);
    expect(model.chatList.chats, isEmpty);
    expect(repository.pins, isEmpty);
    expect(model.chatList.lastDeletedChatId, chat.id);
  });

  test('offline, unsupported and duplicate deletion cannot dispatch extra commands', () async {
    final repository = _Chats()..deletionSupported = false;
    final model = ChatViewModel(repository, 'connector');
    addTearDown(() {
      model.dispose();
      repository.changes.close();
    });
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    final chat = model.chatList.chats.single;
    await model.deleteChat(chat);
    expect(repository.deletes, 0);
    repository.deletionSupported = true;
    repository.online = false;
    repository.changes.add(null);
    await Future<void>.delayed(Duration.zero);
    await model.deleteChat(chat);
    expect(repository.deletes, 0);
    repository.online = true;
    repository.changes.add(null);
    await Future<void>.delayed(Duration.zero);
    repository.deletion = Completer<Map<String, dynamic>>();
    final deleting = model.deleteChat(chat);
    await model.deleteChat(chat);
    expect(repository.deletes, 1);
    repository.deletion!.complete({'version': 1, 'deleted': true});
    await deleting;
    expect(model.chatList.chats, isEmpty);
  });

  testWidgets(
    'minimal folder header and chat menu support pin, unpin, cancel and delete',
    (tester) async {
      final repository = _Chats();
      addTearDown(repository.changes.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: ChatFlowScreen(
            repository: repository,
            connectorId: 'connector',
            connectionName: 'Laptop',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sample project'));
      await tester.pumpAndSettle();
      expect(find.text('Sample project'), findsOneWidget);
      expect(find.text('Laptop'), findsNothing);
      expect(find.text('Online'), findsNothing);
      expect(find.byTooltip('Online'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin chat'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unpin chat'));
      await tester.pumpAndSettle();
      expect(repository.pins, isEmpty);
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repository.deletes, 0);
      expect(find.text('Existing chat'), findsOneWidget);
      await tester.tap(find.byTooltip('Chat options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(repository.deletes, 1);
      expect(find.text('Existing chat'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final pinFailure in [false, true]) {
    testWidgets(
      'details delete returns to Chats and clears its draft, pin failure: $pinFailure',
      (tester) async {
        final repository = _Chats()..pins.add('session');
        final model = await _showConversation(tester, repository);
        await tester.enterText(
          find.byKey(const ValueKey('chat-composer')),
          'Deleted draft',
        );
        await tester.tap(find.byTooltip('Existing chat'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.widgetWithText(TextButton, 'Delete chat'),
          160,
        );
        final delete = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Delete chat'),
        );
        final context = tester.element(
          find.widgetWithText(TextButton, 'Delete chat'),
        );
        expect(
          delete.style!.foregroundColor!.resolve({}),
          Theme.of(context).colorScheme.error,
        );
        await tester.tap(find.widgetWithText(TextButton, 'Delete chat'));
        await tester.pumpAndSettle();
        expect(find.text('Delete chat?'), findsOneWidget);
        expect(repository.deletes, 0);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(repository.deletes, 0);
        expect(find.byType(ChatDetailsScreen), findsOneWidget);
        repository.pinFailure = pinFailure ? ChatFailure.pinStorage : null;
        await tester.tap(find.widgetWithText(TextButton, 'Delete chat'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Delete'));
        await tester.pumpAndSettle();
        expect(repository.deletes, 1);
        expect(model.page, ChatPage.chats);
        expect(model.conversation.chat, isNull);
        expect(model.conversation.messages, isEmpty);
        expect(model.chatList.lastDeletedChatId, 'session');
        expect(find.byType(ChatDetailsScreen), findsNothing);
        if (pinFailure) {
          expect(
            find.text('Chat deleted. Its saved pin could not be cleared.'),
            findsOneWidget,
          );
        } else {
          expect(repository.pins, isEmpty);
        }
        // Even if a test connector reuses the ID, a deleted draft must not return.
        repository.pinFailure = null;
        repository.deleted.clear();
        await model.refresh();
        await model.openChat(model.chatList.chats.single);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('chat-composer')))
              .controller!
              .text,
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final transition in ['source', 'trust', 'offline', 'background']) {
    testWidgets(
      'details delete confirmation cannot act after $transition changes',
      (tester) async {
        final repository = _Chats();
        final model = await _showConversation(tester, repository);
        await tester.tap(find.byTooltip('Existing chat'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.widgetWithText(TextButton, 'Delete chat'),
          160,
        );
        final open = tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Delete chat'))
            .onPressed!;
        open();
        open();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        final confirm = tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Delete'))
            .onPressed!;
        switch (transition) {
          case 'source':
            await model.openChat(
              RemoteChat('other', 'Other chat', DateTime(2025)),
            );
          case 'trust':
            repository.trusted = false;
            repository.changes.add(null);
          case 'offline':
            repository.online = false;
            repository.changes.add(null);
          case 'background':
            for (final state in [
              AppLifecycleState.inactive,
              AppLifecycleState.hidden,
              AppLifecycleState.paused,
            ]) {
              tester.binding.handleAppLifecycleStateChanged(state);
            }
        }
        await tester.pumpAndSettle();
        confirm();
        await tester.pumpAndSettle();
        expect(repository.deletes, 0);
        if (transition == 'background') {
          // Pausing stops animation frames; finish the cancelled route's exit
          // after resuming, without reviving its captured confirmation action.
          for (final state in [
            AppLifecycleState.hidden,
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
          await tester.pumpAndSettle();
          confirm();
          expect(repository.deletes, 0);
        }
        if (transition == 'offline') {
          expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, 'Delete'))
                .onPressed,
            isNull,
          );
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
        } else {
          expect(find.byType(AlertDialog), findsNothing);
        }
        if (transition == 'source' || transition == 'trust') {
          expect(find.byType(ChatDetailsScreen), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'details deletion is single-flight and failed deletion preserves the source',
    (tester) async {
      final repository = _Chats()..deletion = Completer<Map<String, dynamic>>();
      final model = await _showConversation(tester, repository);
      await tester.tap(find.byTooltip('Existing chat'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.widgetWithText(TextButton, 'Delete chat'),
        160,
      );
      final open = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Delete chat'))
          .onPressed!;
      await tester.tap(find.widgetWithText(TextButton, 'Delete chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      open();
      await tester.pump();
      expect(repository.deletes, 1);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Delete chat'))
            .onPressed,
        isNull,
      );
      repository.deletion!.completeError(ChatFailure.uncertain);
      await tester.pumpAndSettle();
      expect(find.byType(ChatDetailsScreen), findsOneWidget);
      expect(model.conversation.chat!.id, 'session');
      expect(model.chatList.lastDeletedChatId, isNull);
      expect(find.text(ChatFailure.uncertain.message), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(repository.deletes, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('confirmed deletion handles newly created current chats absent from the list', () async {
    final repository = _Chats();
    final model = ChatViewModel(repository, 'connector');
    addTearDown(() {
      model.dispose();
      repository.changes.close();
    });
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    model.startNewChat();
    await model.conversation.send('Create a chat');
    expect(model.conversation.chat!.id, 'new');
    expect(model.chatList.chats.any((chat) => chat.id == 'new'), isFalse);
    expect(model.conversation.canDeleteCurrentChat, isTrue);
    await model.conversation.deleteCurrentChat();
    expect(repository.deletes, 1);
    expect(model.conversation.chat, isNull);
    expect(model.page, ChatPage.chats);
  });

  test(
    'late delete acknowledgement cannot clear a different conversation',
    () async {
      final repository = _Chats()..deletion = Completer<Map<String, dynamic>>();
      final model = ChatViewModel(repository, 'connector');
      addTearDown(() {
        model.dispose();
        repository.changes.close();
      });
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      await model.openChat(model.chatList.chats.single);
      final deleting = model.conversation.deleteCurrentChat();
      model.back();
      await model.openChat(RemoteChat('other', 'Other chat', DateTime(2025)));
      repository.deletion!.complete({'version': 1, 'deleted': true});
      await deleting;
      expect(model.conversation.chat!.id, 'other');
      expect(model.page, ChatPage.conversation);
      expect(model.chatList.lastDeletedChatId, isNull);
      expect(repository.deletes, 1);
    },
  );

  test(
    'opening, refreshing and abandoning drafts never creates sessions',
    () async {
      final repository = _Chats();
      final model = ChatViewModel(repository, 'connector');
      addTearDown(() {
        model.dispose();
        repository.changes.close();
      });
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      repository.operations.clear();
      model.startNewChat();
      expect(model.conversation.isDraft, isTrue);
      expect(model.conversation.chat, isNull);
      expect(repository.operations, isEmpty);
      expect(await model.conversation.send(' \n '), isFalse);
      expect(await model.conversation.send('x' * 32001), isFalse);
      await model.refresh();
      model.setActive(false);
      model.setActive(true);
      await Future<void>.delayed(Duration.zero);
      expect(repository.operations.every((o) => o == 'project.list'), isTrue);
      model.back();
      await Future<void>.delayed(Duration.zero);
      model.startNewChat();
      model.back();
      await Future<void>.delayed(Duration.zero);
      expect(repository.creates, 0);
      expect(repository.prompts, 0);
      expect(model.chatList.chats.map((c) => c.id), ['session']);
    },
  );

  test(
    'failed first prompt and follow-up prompts reuse the confirmed session',
    () async {
      final repository = _Chats()..promptFailure = ChatFailure.unavailable;
      final model = ChatViewModel(repository, 'connector');
      addTearDown(() {
        model.dispose();
        repository.changes.close();
      });
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      model.startNewChat();
      expect(await model.conversation.send('First prompt'), isFalse);
      expect(model.conversation.chat?.id, 'new');
      expect(model.error, isNotNull);
      repository.promptFailure = null;
      expect(await model.conversation.send('First prompt'), isTrue);
      expect(await model.conversation.send('Follow-up'), isTrue);
      expect(repository.creates, 1);
      expect(repository.promptSessionIds, ['new', 'new', 'new']);
    },
  );

  for (final mode in PromptMode.values) {
    test(
      '${mode.name} is locked during creation and sent after acknowledgement',
      () async {
        final repository = _Chats()
          ..creation = Completer<Map<String, dynamic>>();
        final model = ChatViewModel(repository, 'connector');
        addTearDown(() {
          model.dispose();
          repository.changes.close();
        });
        await model.refresh();
        await model.openProject(model.projects.projects.single);
        model.startNewChat();
        expect(model.conversation.supportsPromptMode, isTrue);
        expect(model.conversation.canChangePromptMode, isTrue);
        model.conversation.selectPromptMode(mode);
        expect(model.conversation.promptMode, mode);

        final sending = model.conversation.send('First prompt');
        expect(repository.creates, 1);
        expect(model.conversation.chat, isNull);
        expect(repository.prompts, 0);
        expect(model.conversation.canChangePromptMode, isFalse);
        model.conversation.selectPromptMode(
          mode == PromptMode.build ? PromptMode.plan : PromptMode.build,
        );
        expect(model.conversation.promptMode, mode);
        repository.creation!.complete({
          'version': 1,
          'chat': repository.summary('new'),
        });

        expect(await sending, isTrue);
        expect(repository.creates, 1);
        expect(repository.promptSessionIds, ['new']);
        expect(repository.promptModes, [mode.name]);
        expect(model.conversation.canChangePromptMode, isTrue);
      },
    );

    test(
      '${mode.name} capability loss during creation blocks prompt without downgrade',
      () async {
        final repository = _Chats()
          ..creation = Completer<Map<String, dynamic>>();
        final model = ChatViewModel(repository, 'connector');
        addTearDown(() {
          model.dispose();
          repository.changes.close();
        });
        await model.refresh();
        await model.openProject(model.projects.projects.single);
        model.startNewChat();
        model.conversation.selectPromptMode(mode);
        final sending = model.conversation.send('First prompt');
        expect(repository.creates, 1);
        expect(repository.prompts, 0);

        repository.promptModeSupported = false;
        expect(model.conversation.supportsPromptMode, isFalse);
        repository.creation!.complete({
          'version': 1,
          'chat': repository.summary('new'),
        });

        expect(await sending, isFalse);
        expect(model.conversation.chat?.id, 'new');
        expect(model.error, ChatFailure.unsupported.message);
        expect(model.conversation.promptMode, mode);
        expect(repository.prompts, 0);
        expect(repository.promptModes, isEmpty);
        expect(repository.operations, isNot(contains('chat.prompt')));
        expect(
          await model.conversation.send('Retry without mode support'),
          isFalse,
        );
        expect(repository.creates, 1);
        expect(repository.prompts, 0);
      },
    );
  }

  test(
    'uncertain creation blocks duplicate creation even after refresh',
    () async {
      final repository = _Chats()..createFailure = ChatFailure.uncertain;
      final model = ChatViewModel(repository, 'connector');
      addTearDown(() {
        model.dispose();
        repository.changes.close();
      });
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      model.startNewChat();
      expect(await model.conversation.send('First prompt'), isFalse);
      repository.createFailure = null;
      await model.refresh();
      expect(model.error, contains('Return to Chats'));
      expect(await model.conversation.send('First prompt'), isFalse);
      expect(repository.creates, 1);
      expect(repository.prompts, 0);
    },
  );

  test('denied creation preserves the draft and sends no prompt', () async {
    final repository = _Chats()..createFailure = ChatFailure.denied;
    final model = ChatViewModel(repository, 'connector');
    addTearDown(() {
      model.dispose();
      repository.changes.close();
    });
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    model.startNewChat();
    expect(await model.conversation.send('First prompt'), isFalse);
    expect(model.conversation.isDraft, isTrue);
    expect(repository.prompts, 0);
    repository.createFailure = null;
    expect(await model.conversation.send('First prompt'), isTrue);
    expect(repository.prompts, 1);
  });

  test('leaving while creation is pending never sends into a different conversation', () async {
    final repository = _Chats()..creation = Completer<Map<String, dynamic>>();
    final model = ChatViewModel(repository, 'connector');
    addTearDown(() {
      model.dispose();
      repository.changes.close();
    });
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    model.startNewChat();
    final sending = model.conversation.send('First prompt');
    model.back();
    await Future<void>.delayed(Duration.zero);
    await model.openChat(model.chatList.chats.single);
    repository.creation!.complete({
      'version': 1,
      'chat': repository.summary('new'),
    });
    expect(await sending, isFalse);
    expect(model.conversation.chat?.id, 'session');
    expect(repository.prompts, 0);
    expect(await model.conversation.send('Existing conversation'), isTrue);
    expect(repository.creates, 1);
    expect(repository.promptSessionIds, ['session']);
  });

  testWidgets(
    'failed first send keeps composer text when a draft becomes a session',
    (tester) async {
      final repository = _Chats()..promptFailure = ChatFailure.unavailable;
      addTearDown(repository.changes.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: ChatFlowScreen(
            repository: repository,
            connectorId: 'connector',
            connectionName: 'Laptop',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sample project'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New chat'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('chat-composer'));
      await tester.enterText(field, 'Keep this draft');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('chat-send')));
      await tester.pumpAndSettle();
      expect(repository.creates, 1);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Keep this draft',
      );
      repository.promptFailure = null;
      await tester.tap(find.byKey(const ValueKey('chat-send')));
      await tester.pumpAndSettle();
      expect(repository.creates, 1);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('pagination excludes sub-agents from every page', () async {
    final repository = _Chats();
    final model = ChatViewModel(repository, 'connector');
    addTearDown(() {
      model.dispose();
      repository.changes.close();
    });
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    expect(model.chatList.chats.map((c) => c.id), ['session']);
    model.chatList.chatCursor = 'next';
    await model.moreChats();
    expect(model.chatList.chats.map((c) => c.id), ['session', 'later']);
    expect(model.chatList.chatCursor, isNull);
  });

  test(
    'pagination stops at 1,000 unique chats even when a page crosses the cap',
    () async {
      final repository = _ListChats([
        for (var i = 0; i < 50; i++)
          _chatSummary('initial-$i', 'Initial', DateTime.now()),
      ])..hasMore = true;
      final model = ChatViewModel(repository, 'connector');
      addTearDown(() {
        model.dispose();
        repository.changes.close();
      });
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      for (var page = 0; page < 21; page++) {
        repository.pages.add({
          'version': 1,
          'chats': [
            // Each page overlaps one initial row, so the final page crosses 1,000.
            _chatSummary('initial-0', 'Initial', DateTime.now()),
            for (var i = 0; i < 49; i++)
              _chatSummary('page-$page-$i', 'Older', DateTime(2025, 1, 1)),
          ],
          'cursor': 'page-${page + 1}',
        });
      }
      while (model.chatList.chatCursor != null) {
        await model.moreChats();
      }
      expect(model.chatList.chats.length, 1000);
      expect(model.error, contains('incomplete'));
      final requests = repository.cursors.length;
      await model.moreChats();
      expect(repository.cursors.length, requests);
    },
  );

  test(
    'empty continuation chains are bounded and refresh resets the budget',
    () async {
      final repository = _ListChats([])..hasMore = true;
      final model = ChatViewModel(repository, 'connector');
      addTearDown(() {
        model.dispose();
        repository.changes.close();
      });
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      for (var page = 0; page < 99; page++) {
        repository.pages.add({
          'version': 1,
          'chats': [],
          'cursor': 'page-$page',
        });
        await model.moreChats();
      }
      expect(repository.cursors.length, 100);
      expect(model.chatList.chatCursor, isNull);
      expect(model.error, contains('page limit'));
      await model.moreChats();
      expect(repository.cursors.length, 100);
      await model.refresh();
      expect(model.error, isNull);
      expect(model.chatList.chatCursor, 'next-page');
    },
  );

  test('repeated cursors fail without changing rows and inactive reads are ignored', () async {
    final repository = _ListChats([
      _chatSummary('main', 'Main', DateTime.now()),
    ])..hasMore = true;
    final model = ChatViewModel(repository, 'connector');
    addTearDown(() {
      model.dispose();
      repository.changes.close();
    });
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    repository.pages.add({'version': 1, 'chats': [], 'cursor': 'next-page'});
    await model.moreChats();
    expect(model.chatList.moreChatsError, isNotNull);
    expect(model.chatList.chats.single.id, 'main');
    model.setActive(false);
    await model.moreChats();
    expect(repository.cursors, [null, 'next-page']);
    model.backToProjects();
    expect(model.chatList.chatCursor, isNull);
    expect(model.chatList.moreChatsError, isNull);
  });

  test('backgrounding an uncertain create permits refresh on resume without resubmitting', () async {
    final repository = _Chats();
    final model = ChatViewModel(repository, 'connector');
    addTearDown(() {
      model.dispose();
      repository.changes.close();
    });
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    repository.creation = Completer<Map<String, dynamic>>();
    model.startNewChat();
    final pending = model.conversation.send('First prompt');
    model.setActive(false);
    repository.creation!.complete({
      'version': 1,
      'chat': repository.summary('new'),
    });
    await pending;
    model.setActive(true);
    await Future<void>.delayed(Duration.zero);
    expect(model.mutating, isFalse);
    expect(model.loading, isFalse);
    expect(model.page, ChatPage.conversation);
    expect(model.conversation.chat?.id, 'new');
    expect(repository.prompts, 0);
    expect(repository.creates, 1);
  });

  test('trust loss clears decrypted project and conversation state', () async {
    final repository = _Chats();
    final model = ChatViewModel(repository, 'connector');
    addTearDown(() {
      model.dispose();
      repository.changes.close();
    });
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    await model.openChat(model.chatList.chats.single);
    expect(model.conversation.messages, isNotEmpty);
    repository.trusted = false;
    repository.online = false;
    repository.changes.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(model.trustLost, isTrue);
    expect(model.projects.projects, isEmpty);
    expect(model.chatList.chats, isEmpty);
    expect(model.conversation.messages, isEmpty);
    expect(model.conversation.chat, isNull);
    expect(model.project, isNull);
  });
  testWidgets(
    'double tap follows Connection → Project → Chats → Conversation and back',
    (tester) async {
      final repository = _Chats();
      addTearDown(repository.changes.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: ConnectionCard(
                connection: const RemoteConnection(
                  id: 'connector',
                  name: 'Laptop',
                  status: ConnectionStatus.online,
                ),
                onSelect: () {},
                onOpen: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatFlowScreen(
                      repository: repository,
                      connectorId: 'connector',
                      connectionName: 'Laptop',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Laptop'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Laptop'), findsOneWidget);
      await tester.tap(find.text('Sample project'));
      await tester.pumpAndSettle();
      expect(find.text('Search chats'), findsOneWidget);
      expect(find.text('Hidden sub-agent'), findsNothing);
      await tester.tap(find.text('Existing chat'));
      await tester.pumpAndSettle();
      expect(find.text('A real snapshot'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
      expect(find.text('/work/sample'), findsNothing);
      expect(find.text('Idle'), findsNothing);
      expect(find.byTooltip('Online'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        'Keep this unsent message',
      );
      await tester.tap(find.byTooltip('Existing chat'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatDetailsScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Laptop'), findsOneWidget);
      expect(repository.prompts, 0);
      await tester.tap(find.text('Sample project'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Existing chat'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('chat-composer')))
            .controller!
            .text,
        'Keep this unsent message',
      );
      await tester.tap(find.byTooltip('Existing chat'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Search chats'), findsOneWidget);
      await tester.tap(find.byTooltip('New chat'));
      await tester.pumpAndSettle();
      expect(repository.creates, 0);
      expect(find.text('New chat'), findsOneWidget);
      expect(find.byTooltip('Online'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(repository.creates, 0);
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        'First prompt',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('chat-send')));
      await tester.pumpAndSettle();
      expect(repository.creates, 1);
      expect(repository.prompts, 1);
      expect(find.text('Untitled chat'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('chat-composer')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('accessible Open projects button works without a double tap', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ConnectionCard(
            connection: const RemoteConnection(
              id: 'connector',
              name: 'Laptop',
              status: ConnectionStatus.online,
            ),
            onOpen: () => opened++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open projects'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  test(
    'late snapshots cannot reopen a conversation after the Projects breadcrumb',
    () async {
      final repository = _Chats();
      final model = ChatViewModel(repository, 'connector');
      addTearDown(() {
        model.dispose();
        repository.changes.close();
      });
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      repository.snapshot = Completer<Map<String, dynamic>>();
      final opening = model.openChat(model.chatList.chats.single);
      model.backToProjects();
      repository.snapshot!.complete(
        repository.response('chat.snapshot', {'sessionId': 'session'}),
      );
      await opening;
      expect(model.page, ChatPage.projects);
      expect(model.conversation.chat, isNull);
      expect(model.conversation.messages, isEmpty);
    },
  );

  test(
    'duplicate first sends execute once and disconnect prevents the prompt',
    () async {
      final repository = _Chats();
      final model = ChatViewModel(repository, 'connector');
      addTearDown(() {
        model.dispose();
        repository.changes.close();
      });
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      repository.creation = Completer<Map<String, dynamic>>();
      model.startNewChat();
      final creating = model.conversation.send('First prompt');
      expect(await model.conversation.send('First prompt'), isFalse);
      expect(repository.creates, 1);
      repository.online = false;
      repository.changes.add(null);
      await Future<void>.delayed(Duration.zero);
      repository.creation!.complete({
        'version': 1,
        'chat': repository.summary('new'),
      });
      await creating;
      expect(model.online, isFalse);
      expect(model.page, ChatPage.conversation);
      expect(model.conversation.chat?.id, 'new');
      expect(repository.prompts, 0);
    },
  );
}

Future<ChatViewModel> _showList(
  WidgetTester tester,
  _ListChats repository, {
  bool settle = true,
}) async {
  final model = ChatViewModel(repository, 'connector');
  final search = TextEditingController();
  addTearDown(() {
    search.dispose();
    repository.changes.close();
  });
  await model.refresh();
  await model.openProject(model.projects.projects.single);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: ListenableBuilder(
          listenable: model,
          builder: (_, _) => ChatListView(model: model, search: search),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return model;
}

Future<ChatViewModel> _showConversation(
  WidgetTester tester,
  _Chats repository, {
  bool largeText = false,
  bool draft = false,
}) async {
  addTearDown(repository.changes.close);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(largeText ? 2 : 1)),
        child: child!,
      ),
      home: ChatFlowScreen(
        repository: repository,
        connectorId: 'connector',
        connectionName: 'Laptop',
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Sample project'));
  await tester.pumpAndSettle();
  final model = tester.widget<ChatListView>(find.byType(ChatListView)).model;
  await tester.tap(
    draft ? find.byTooltip('New chat') : find.text('Existing chat'),
  );
  await tester.pumpAndSettle();
  return model;
}

Map<String, dynamic> _historyMessage(int number, {bool short = false}) => {
  'id': 'm$number',
  'role': number.isEven ? 'user' : 'assistant',
  'text': short
      ? 'Message $number'
      : 'Message $number\n${List.filled(number % 3 + 1, 'A variable-height message with enough text to wrap across the screen.').join('\n')}',
  'truncated': false,
};

class _HistoryChats extends _Chats {
  List<Map<String, dynamic>> latest = [
    for (var i = 100; i < 110; i++) _historyMessage(i),
  ];
  String? latestCursor = 'older';
  final cursors = <String?>[];
  final olderPages = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? pendingOlder;
  ChatFailure? historyFailure;

  Map<String, dynamic> historyPage(
    int start,
    int end, {
    String? cursor,
    bool short = false,
  }) => {
    'version': 1,
    'chat': summary('session'),
    'status': 'idle',
    'messages': [
      for (var i = start; i < end; i++) _historyMessage(i, short: short),
    ],
    'cursor': cursor,
  };

  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async {
    if (operation != 'chat.snapshot') {
      return super.chatRequest(connectorId, operation, body);
    }
    cursors.add(body['cursor'] as String?);
    if (body.containsKey('cursor')) {
      if (historyFailure != null) throw historyFailure!;
      if (pendingOlder != null) return pendingOlder!.future;
      return olderPages.isNotEmpty
          ? olderPages.removeAt(0)
          : historyPage(90, 100);
    }
    return {...historyPage(0, 0), 'messages': latest, 'cursor': latestCursor};
  }
}

class _Chats implements ChatRepository {
  final changes = StreamController<void>.broadcast();
  bool online = true;
  bool trusted = true;
  String projectName = 'Sample project';
  int creates = 0, prompts = 0;
  int deletes = 0;
  final pins = <String>{};
  final deleted = <String>{};
  bool deletionSupported = true;
  bool promptModeSupported = true;
  ChatFailure? deleteFailure, pinFailure, getFailure;
  Completer<Map<String, dynamic>>? deletion;
  final operations = <String>[];
  final promptSessionIds = <String>[];
  final promptModes = <String?>[];
  ChatFailure? createFailure, promptFailure;
  Completer<Map<String, dynamic>>? snapshot, creation;
  @override
  Stream<void> get chatConnectionChanges => changes.stream;
  @override
  Stream<ChatEvent> get chatEvents => const Stream.empty();
  @override
  Object chatConnectionGeneration(String connectorId) => 0;
  @override
  bool chatOnline(String connectorId) => online;
  @override
  bool chatTrusted(String connectorId) => trusted;
  @override
  bool chatSupports(String connectorId, String operation) =>
      !operation.startsWith('project.mcp.') &&
      !operation.startsWith('chat.stream.') &&
      operation != 'chat.activities' &&
      operation != 'chat.images' &&
      operation != 'chat.permissions' &&
      operation != 'chat.permission.reply' &&
      (operation != 'chat.delete' || deletionSupported) &&
      (operation != 'chat.prompt.mode' || promptModeSupported);
  @override
  Future<Set<String>> pinnedChatIds(
    String connectorId,
    String projectPath,
  ) async => {...pins};
  @override
  Future<Set<String>> setChatPinned(
    String connectorId,
    String projectPath,
    String sessionId,
    bool pinned,
  ) async {
    if (pinFailure != null) throw pinFailure!;
    if (pinned) {
      pins.add(sessionId);
    } else {
      pins.remove(sessionId);
    }
    return {...pins};
  }

  Map<String, dynamic> summary(String id) => {
    'id': id,
    'title': id == 'new' ? '' : 'Existing chat',
    'updatedAt': id == 'later' ? 1699999999000 : 1700000000000,
  };
  Map<String, dynamic> response(
    String operation,
    Map<String, dynamic> body,
  ) => switch (operation) {
    'project.list' => {
      'version': 1,
      'projects': [
        {'id': 'project', 'name': projectName, 'path': '/work/sample'},
      ],
      'pathEntry': true,
    },
    'chat.list' => {
      'version': 1,
      'chats': [
        if (!deleted.contains(body.containsKey('cursor') ? 'later' : 'session'))
          summary(body.containsKey('cursor') ? 'later' : 'session'),
        {
          ...summary('subagent'),
          'title': 'Hidden sub-agent',
          'parentId': 'session',
        },
      ],
      'cursor': null,
    },
    'chat.snapshot' => {
      'version': 1,
      'chat': summary(body['sessionId'] as String),
      'status': 'idle',
      'cursor': null,
      'messages': body['sessionId'] == 'new'
          ? []
          : [
              {
                'id': 'message',
                'role': 'assistant',
                'text': 'A real snapshot',
                'truncated': false,
              },
            ],
    },
    'chat.create' => {'version': 1, 'chat': summary('new')},
    'chat.get' => {'version': 1, 'chat': summary(body['sessionId'] as String)},
    _ => {'version': 1, 'accepted': true},
  };
  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async {
    operations.add(operation);
    if (operation == 'chat.get' && getFailure != null) throw getFailure!;
    if (operation == 'chat.delete') {
      deletes++;
      if (deleteFailure != null) throw deleteFailure!;
      if (deletion != null) return deletion!.future;
      deleted.add(body['sessionId'] as String);
      return {'version': 1, 'deleted': true};
    }
    if (operation == 'chat.prompt') {
      prompts++;
      promptSessionIds.add(body['sessionId'] as String);
      promptModes.add(body['mode'] as String?);
      if (promptFailure != null) throw promptFailure!;
    }
    if (operation == 'chat.create') {
      creates++;
      if (createFailure != null) throw createFailure!;
      if (creation != null) return creation!.future;
    }
    if (operation == 'chat.snapshot' && snapshot != null) {
      return snapshot!.future;
    }
    return response(operation, body);
  }
}

Map<String, dynamic> _chatSummary(String id, String title, DateTime updated) =>
    {'id': id, 'title': title, 'updatedAt': updated.millisecondsSinceEpoch};

class _ListChats extends _Chats {
  _ListChats(this.rows);
  final List<Map<String, dynamic>> rows;
  bool hasMore = false;
  final cursors = <String?>[];
  final pages = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? nextPage;
  ChatFailure? listFailure;

  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async {
    if (operation == 'chat.list') {
      cursors.add(body['cursor'] as String?);
      if (body.containsKey('cursor')) {
        if (listFailure != null) throw listFailure!;
        if (nextPage != null) return nextPage!.future;
        if (pages.isNotEmpty) return pages.removeAt(0);
      }
    }
    return super.chatRequest(connectorId, operation, body);
  }

  @override
  Map<String, dynamic> summary(String id) => rows.firstWhere(
    (row) => row['id'] == id,
    orElse: () => super.summary(id),
  );

  @override
  Map<String, dynamic> response(String operation, Map<String, dynamic> body) =>
      operation == 'chat.list'
      ? {
          'version': 1,
          'chats': body.containsKey('cursor')
              ? [
                  _chatSummary(
                    'later',
                    'Later work',
                    DateTime.now().subtract(const Duration(days: 40)),
                  ),
                ]
              : rows,
          'cursor': hasMore && !body.containsKey('cursor') ? 'next-page' : null,
        }
      : super.response(operation, body);
}
