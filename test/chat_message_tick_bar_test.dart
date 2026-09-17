import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/features/chat/ui/message_tick_bar.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

void main() {
  testWidgets('the bar is absent below two prompts', (tester) async {
    final semantics = tester.ensureSemantics();
    final model = _conversation(userMessages: 1);
    addTearDown(model.dispose);
    await _show(
      tester,
      model,
      key: GlobalObjectKey<ConversationViewState>('one'),
    );

    expect(find.byType(MessageTickBar), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Jump to your message')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets(
    'one tick per prompt, in order, skipping an empty synthetic message',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final model = _conversation(userMessages: 5, withEmptyUserMessage: true);
      addTearDown(model.dispose);
      await _show(
        tester,
        model,
        key: GlobalObjectKey<ConversationViewState>('five'),
      );

      for (var i = 1; i <= 5; i++) {
        expect(
          find.bySemanticsLabel('Jump to your message $i of 5'),
          findsOneWidget,
        );
      }
      // The empty synthetic message never got its own row, so it never got
      // its own tick either -- exactly 5, not 6.
      expect(
        find.bySemanticsLabel('Jump to your message 6 of 5'),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );

  testWidgets('tapping the oldest tick scrolls its prompt near the top', (
    tester,
  ) async {
    final model = _conversation(userMessages: 6);
    addTearDown(model.dispose);
    final key = GlobalObjectKey<ConversationViewState>('scroll-up');
    await _show(tester, model, key: key);

    await tester.tap(find.bySemanticsLabel('Jump to your message 1 of 6'));
    await tester.pumpAndSettle();

    final row = tester.getRect(find.byKey(const ValueKey('message-user-0')));
    expect(row.top, lessThan(150));
  });

  testWidgets('tapping a tick highlights the message it lands on, briefly', (
    tester,
  ) async {
    final model = _conversation(userMessages: 6);
    addTearDown(model.dispose);
    final key = GlobalObjectKey<ConversationViewState>('highlight');
    await _show(tester, model, key: key);

    expect(key.currentState!.highlightedMessageId.value, isNull);

    await tester.tap(find.bySemanticsLabel('Jump to your message 1 of 6'));
    await tester.pumpAndSettle();
    expect(key.currentState!.highlightedMessageId.value, 'user-0');

    await tester.pump(const Duration(milliseconds: 2000));
    expect(key.currentState!.highlightedMessageId.value, isNull);
  });

  testWidgets(
    'the current tick follows the scroll position, oldest to newest',
    (tester) async {
      final model = _conversation(userMessages: 6);
      addTearDown(model.dispose);
      final key = GlobalObjectKey<ConversationViewState>('drag');
      await _show(tester, model, key: key);

      // A large downward drag on this reversed list scrolls toward the
      // oldest history -- the same direction that triggers loading earlier
      // messages -- so the topmost tick becomes current.
      await tester.drag(find.byType(ListView), const Offset(0, 6000));
      await tester.pumpAndSettle();
      expect(_isSelected(tester, 'Jump to your message 1 of 6'), isTrue);
      expect(_isSelected(tester, 'Jump to your message 6 of 6'), isFalse);

      await tester.drag(find.byType(ListView), const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(_isSelected(tester, 'Jump to your message 6 of 6'), isTrue);
      expect(_isSelected(tester, 'Jump to your message 1 of 6'), isFalse);
    },
  );

  testWidgets('scrolling to a message that no longer exists is a no-op', (
    tester,
  ) async {
    final model = _conversation(userMessages: 3);
    addTearDown(model.dispose);
    final key = GlobalObjectKey<ConversationViewState>('stale');
    await _show(tester, model, key: key);

    expect(() => key.currentState!.scrollToMessage('nope'), returnsNormally);
    await tester.pump();
  });

  testWidgets(
    'jump-to-latest appears once scrolled up, and returns to the newest message',
    (tester) async {
      final model = _conversation(userMessages: 6);
      addTearDown(model.dispose);
      final key = GlobalObjectKey<ConversationViewState>('latest');
      await _show(tester, model, key: key);

      expect(key.currentState!.isScrolledFromLatest.value, isFalse);

      await tester.drag(find.byType(ListView), const Offset(0, 6000));
      await tester.pumpAndSettle();
      expect(key.currentState!.isScrolledFromLatest.value, isTrue);

      await tester.tap(find.bySemanticsLabel('Jump to latest message'));
      await tester.pumpAndSettle();
      expect(key.currentState!.isScrolledFromLatest.value, isFalse);
    },
  );

  testWidgets(
    'still lands on the right prompt when more history loads mid-jump',
    (tester) async {
      final model = _conversation(userMessages: 6);
      addTearDown(model.dispose);
      final key = GlobalObjectKey<ConversationViewState>('grows');
      await _show(tester, model, key: key);

      // Called directly, and the extra history spliced in before any pump
      // runs, so the very first estimate -- computed from the smaller,
      // pre-growth list -- is guaranteed stale by the time the refine loop
      // gets its first look, exactly like real pagination racing a jump that
      // was already in flight.
      key.currentState!.scrollToMessage('user-0');
      model.conversation.messages = [
        for (var i = 0; i < 10; i++) ...[
          ChatMessage('older-user-$i', 'user', 'Even earlier prompt $i', false),
          ChatMessage(
            'older-reply-$i',
            'assistant',
            List.filled(
              12,
              'Another long reply line taking up real space.',
            ).join('\n'),
            false,
          ),
        ],
        ...model.conversation.messages,
      ];
      model.conversation.notifyListeners();

      await tester.pumpAndSettle();

      // Despite the list growing underneath it, the jump still converges on
      // the prompt that was actually tapped -- not wherever the pre-growth
      // estimate happened to land.
      final row = tester.getRect(find.byKey(const ValueKey('message-user-0')));
      expect(row.top, lessThan(150));
    },
  );

  testWidgets(
    'converges even when one reply dwarfs the rest of the conversation',
    (tester) async {
      // A single huge tool dump right after the oldest prompt, everything
      // else short: the proportional first guess (which assumes roughly
      // uniform message heights) is necessarily far off for a prompt that
      // sits right after it, so this only passes if the bisection search in
      // ConversationViewState._refinePendingScroll actually narrows in,
      // rather than trusting that first guess.
      final model = ChatViewModel(_Repository(), 'connector')
        ..conversation.messages = [
          const ChatMessage('user-0', 'user', 'Prompt zero', false),
          ChatMessage(
            'huge-reply',
            'assistant',
            List.filled(400, 'A huge tool dump line.').join('\n'),
            false,
          ),
          for (var i = 1; i < 8; i++) ...[
            ChatMessage('user-$i', 'user', 'Prompt $i', false),
            ChatMessage('reply-$i', 'assistant', 'Short reply $i', false),
          ],
        ];
      addTearDown(model.dispose);
      final key = GlobalObjectKey<ConversationViewState>('uneven');
      await _show(tester, model, key: key);

      await tester.tap(find.bySemanticsLabel('Jump to your message 2 of 8'));
      await tester.pumpAndSettle();

      final row = tester.getRect(find.byKey(const ValueKey('message-user-1')));
      expect(row.top, lessThan(150));
    },
  );
}

/// A conversation with [userMessages] prompts (ids `user-0`..`user-N`), each
/// followed by a long assistant reply so the list overflows the test
/// viewport and actually needs scrolling. With [withEmptyUserMessage], an
/// extra blank user message is inserted -- the kind `visibleMessages` filters
/// out entirely -- so a tick count off by one would be caught.
ChatViewModel _conversation({
  required int userMessages,
  bool withEmptyUserMessage = false,
}) {
  final messages = <ChatMessage>[
    if (withEmptyUserMessage)
      const ChatMessage('user-empty', 'user', '', false),
  ];
  for (var i = 0; i < userMessages; i++) {
    messages.add(ChatMessage('user-$i', 'user', 'Prompt number $i', false));
    messages.add(
      ChatMessage(
        'reply-$i',
        'assistant',
        List.filled(
          12,
          'A long reply line that takes up real space.',
        ).join('\n'),
        false,
      ),
    );
  }
  return ChatViewModel(_Repository(), 'connector')
    ..conversation.messages = messages;
}

/// Whether the tick with this exact semantics label is marked selected --
/// matched directly by widget/property rather than via `find.ancestor`,
/// which would also catch the unrelated `Semantics` nodes Flutter inserts
/// further up the tree (Scaffold, MaterialApp, ...).
bool _isSelected(WidgetTester tester, String label) => tester
    .widget<Semantics>(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == label,
      ),
    )
    .properties
    .selected!;

Future<void> _show(
  WidgetTester tester,
  ChatViewModel model, {
  required GlobalKey<ConversationViewState> key,
}) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(
      body: SizedBox(
        height: 500,
        child: Stack(
          children: [
            ConversationView(key: key, model: model.conversation),
            Positioned(
              top: 0,
              bottom: 0,
              right: 6,
              child: MessageTickBar(
                model: model.conversation,
                conversationKey: key,
              ),
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: JumpToLatestButton(conversationKey: key),
            ),
          ],
        ),
      ),
    ),
  ),
);

class _Repository implements ChatRepository {
  @override
  Stream<void> get chatConnectionChanges => const Stream.empty();
  @override
  Stream<ChatEvent> get chatEvents => const Stream.empty();
  @override
  Object chatConnectionGeneration(String connectorId) => 0;
  @override
  bool chatOnline(String connectorId) => true;
  @override
  bool chatTrusted(String connectorId) => true;
  @override
  bool chatSupports(String connectorId, String operation) => false;
  @override
  Future<Set<String>> pinnedChatIds(
    String connectorId,
    String projectPath,
  ) async => {};
  @override
  Future<Set<String>> setChatPinned(
    String connectorId,
    String projectPath,
    String sessionId,
    bool pinned,
  ) async => {};
  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async => throw StateError('Unexpected $operation');
}
