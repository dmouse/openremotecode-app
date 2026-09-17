import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/question_banner.dart';

final _fixture = jsonDecode(
  File('../packages/protocol/test/fixtures/chat-questions-v1.json')
      .readAsStringSync(),
) as Map<String, dynamic>;
Map<String, dynamic> get _question =>
    _fixture['question'] as Map<String, dynamic>;
Map<String, dynamic> get _noCustomQuestion =>
    _fixture['multipleChoice'] as Map<String, dynamic>;
Map<String, dynamic> get _batch => _fixture['batch'] as Map<String, dynamic>;
Map<String, dynamic> _prompt(Map<String, dynamic> batch, int index) =>
    (batch['questions'] as List)[index] as Map<String, dynamic>;

Future<ChatViewModel> _openConversation(_Repository repo) async {
  final model = ChatViewModel(repo, 'connector');
  await model.refresh();
  await model.openProject(model.projects.projects.single);
  await model.openChat(model.chatList.chats.single);
  return model;
}

void main() {
  testWidgets(
    'shows the pending question with actionable options while merely polled, not stream-subscribed',
    (tester) async {
      // No stream capabilities are advertised, so `activityLive`'s low-latency-stream
      // component is never true -- only ordinary online/offline polling applies. A
      // question must still be answerable in that state, unlike before this fix.
      final model = ChatViewModel(_Repository(), 'connector')
        ..conversation.question = ChatQuestion.parse(_question);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuestionBanner(model: model.conversation)),
        ),
      );
      expect(
        find.text(_prompt(_question, 0)['question'] as String),
        findsOneWidget,
      );
      expect(find.text('Online backfill'), findsOneWidget);
      expect(find.text('Maintenance window'), findsOneWidget);
      expect(find.text('Type your own answer'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Answer'), findsOneWidget);
      // A single-question batch shows no page indicator or Next/Skip-all wording.
      expect(find.textContaining('Question 1 of'), findsNothing);
      expect(find.text('Skip all'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'a question that opts out of custom answers never offers to type one',
    (tester) async {
      final model = ChatViewModel(_Repository(), 'connector')
        ..conversation.question = ChatQuestion.parse(_noCustomQuestion);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuestionBanner(model: model.conversation)),
        ),
      );
      expect(find.text('iOS'), findsOneWidget);
      expect(find.text('Type your own answer'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'tapping Type your own answer swaps in the composer hint and notifies the caller, '
    'and Back to options returns',
    (tester) async {
      final model = ChatViewModel(_Repository(), 'connector')
        ..conversation.question = ChatQuestion.parse(_question);
      var focusRequested = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: model,
              builder: (context, _) => QuestionBanner(
                model: model.conversation,
                onTypeOwnAnswer: () => focusRequested++,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Type your own answer'));
      await tester.pump();
      expect(focusRequested, 1);
      expect(model.conversation.answeringCustomQuestion, isTrue);
      expect(model.conversation.answeringQuestionIndex, 0);
      expect(
        find.text('Type your answer in the message box below.'),
        findsOneWidget,
      );
      expect(find.text('Online backfill'), findsNothing);
      expect(find.text('Answer'), findsNothing);

      await tester.tap(find.text('Back to options'));
      await tester.pump();
      expect(model.conversation.answeringCustomQuestion, isFalse);
      expect(find.text('Online backfill'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets('renders nothing when no question is pending', (tester) async {
    final model = ChatViewModel(_Repository(), 'connector');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuestionBanner(model: model.conversation)),
      ),
    );
    expect(find.byType(QuestionBanner), findsOneWidget);
    expect(find.text('Answer'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });

  testWidgets(
    'replaces options with an explanatory message when the connector is offline',
    (tester) async {
      final model = ChatViewModel(
        _Repository()..onlineValue = false,
        'connector',
      )..conversation.question = ChatQuestion.parse(_question);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QuestionBanner(model: model.conversation)),
        ),
      );
      expect(find.text('Answer'), findsNothing);
      expect(find.text('Skip'), findsNothing);
      expect(find.textContaining('Connector offline'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'selecting an option and tapping Answer sends the selected index and clears the banner',
    (tester) async {
      final repo = _Repository()..question = _question;
      final model = await _openConversation(repo);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: model,
              builder: (context, _) =>
                  QuestionBanner(model: model.conversation),
            ),
          ),
        ),
      );
      expect(find.text('Online backfill'), findsOneWidget);
      await tester.tap(find.text('Online backfill'));
      await tester.pump();
      await tester.tap(find.text('Answer'));
      await tester.pumpAndSettle();
      final reply = repo.requests.firstWhere(
        (r) => r.$1 == 'chat.question.reply',
      );
      expect(reply.$2['questionId'], _question['id']);
      expect(reply.$2['response'], 'answer');
      expect(reply.$2['answers'], [
        {'selected': [0]},
      ]);
      expect(find.text('Online backfill'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'a free-text answer sends exactly the typed text and clears the banner',
    (tester) async {
      final repo = _Repository()..question = _question;
      final model = await _openConversation(repo);
      model.conversation.startQuestionCustomAnswer(0);
      final accepted = await model.conversation.answerQuestionAtWithText(
        0,
        '  Fix Item Gamma first.  ',
      );
      expect(accepted, isTrue);
      final reply = repo.requests.firstWhere(
        (r) => r.$1 == 'chat.question.reply',
      );
      expect(reply.$2['questionId'], _question['id']);
      expect(reply.$2['answers'], [
        {'text': 'Fix Item Gamma first.'},
      ]);
      expect(model.conversation.question, isNull);
      expect(model.conversation.answeringCustomQuestion, isFalse);
      model.dispose();
    },
  );

  testWidgets('an empty draft does not submit a free-text answer', (
    tester,
  ) async {
    final repo = _Repository()..question = _question;
    final model = await _openConversation(repo);
    model.conversation.startQuestionCustomAnswer(0);
    final accepted = await model.conversation.answerQuestionAtWithText(
      0,
      '   ',
    );
    expect(accepted, isFalse);
    expect(repo.requests.any((r) => r.$1 == 'chat.question.reply'), isFalse);
    expect(model.conversation.question, isNotNull);
    model.dispose();
  });

  testWidgets(
    'a multi-question batch pages through each question and submits one batched reply',
    (tester) async {
      final repo = _Repository()..question = _batch;
      final model = await _openConversation(repo);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: model,
              builder: (context, _) =>
                  QuestionBanner(model: model.conversation),
            ),
          ),
        ),
      );
      expect(find.text('Question 1 of 2'), findsOneWidget);
      expect(find.text('Online backfill'), findsOneWidget);
      await tester.tap(find.text('Online backfill'));
      await tester.pump();
      await tester.tap(find.text('Next'));
      await tester.pump();

      expect(find.text('Question 2 of 2'), findsOneWidget);
      expect(find.text('iOS'), findsOneWidget);
      // Nothing is sent until the whole batch has an answer for every question.
      expect(
        repo.requests.any((r) => r.$1 == 'chat.question.reply'),
        isFalse,
      );

      await tester.tap(find.text('iOS'));
      await tester.pump();
      await tester.tap(find.text('Android'));
      await tester.pump();
      await tester.tap(find.text('Answer'));
      await tester.pumpAndSettle();

      final replies = repo.requests
          .where((r) => r.$1 == 'chat.question.reply')
          .toList();
      expect(replies, hasLength(1));
      final reply = replies.single;
      expect(reply.$2['questionId'], _batch['id']);
      expect(reply.$2['response'], 'answer');
      expect(reply.$2['answers'], [
        {'selected': [0]},
        {'selected': [0, 1]},
      ]);
      expect(find.text('iOS'), findsNothing);
      model.dispose();
    },
  );

  testWidgets(
    'revisiting a page after Back still shows its previously staged answer',
    (tester) async {
      final repo = _Repository()..question = _batch;
      final model = await _openConversation(repo);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: model,
              builder: (context, _) =>
                  QuestionBanner(model: model.conversation),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Online backfill'));
      await tester.pump();
      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(find.text('Question 2 of 2'), findsOneWidget);

      await tester.tap(find.text('Back'));
      await tester.pump();
      expect(find.text('Question 1 of 2'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(
        button.onPressed,
        isNotNull,
        reason: 'the earlier selection for this page should still be staged',
      );
      model.dispose();
    },
  );

  testWidgets('rejecting from a non-first page declines the whole batch', (
    tester,
  ) async {
    final repo = _Repository()..question = _batch;
    final model = await _openConversation(repo);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: model,
            builder: (context, _) => QuestionBanner(model: model.conversation),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Online backfill'));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(find.text('Question 2 of 2'), findsOneWidget);

    await tester.tap(find.text('Skip all'));
    await tester.pumpAndSettle();

    final reply = repo.requests.firstWhere(
      (r) => r.$1 == 'chat.question.reply',
    );
    expect(reply.$2['questionId'], _batch['id']);
    expect(reply.$2['response'], 'reject');
    expect(reply.$2.containsKey('answers'), isFalse);
    expect(find.text('iOS'), findsNothing);
    model.dispose();
  });

  testWidgets(
    'a free-text answer on one page of a batch stages it and still requires the rest',
    (tester) async {
      final repo = _Repository()..question = _batch;
      final model = await _openConversation(repo);
      // "Targets" (index 1) has custom: false, so drive the custom flow through page 0
      // ("Migration safety"), which allows it.
      model.conversation.startQuestionCustomAnswer(0);
      final accepted = await model.conversation.answerQuestionAtWithText(
        0,
        '  Run it during the maintenance window.  ',
      );
      expect(accepted, isTrue);
      expect(model.conversation.answeringCustomQuestion, isFalse);
      // The batch isn't complete yet -- the second question still needs an answer.
      expect(model.conversation.question, isNotNull);
      expect(
        repo.requests.any((r) => r.$1 == 'chat.question.reply'),
        isFalse,
      );

      await model.conversation.answerQuestionAt(1, [0, 1]);
      final reply = repo.requests.firstWhere(
        (r) => r.$1 == 'chat.question.reply',
      );
      expect(reply.$2['answers'], [
        {'text': 'Run it during the maintenance window.'},
        {'selected': [0, 1]},
      ]);
      model.dispose();
    },
  );
}

class _Repository implements ChatRepository {
  Map<String, dynamic>? question;
  bool onlineValue = true;
  final requests = <(String, Map<String, dynamic>)>[];

  @override
  Stream<void> get chatConnectionChanges => const Stream.empty();
  @override
  Stream<ChatEvent> get chatEvents => const Stream.empty();
  @override
  Object chatConnectionGeneration(String connectorId) => 0;
  @override
  bool chatOnline(String connectorId) => onlineValue;
  @override
  bool chatTrusted(String connectorId) => true;
  @override
  bool chatSupports(String connectorId, String operation) =>
      operation == 'chat.questions' || operation == 'chat.question.reply';
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
  ) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> chatRequest(
    String connectorId,
    String operation,
    Map<String, dynamic> body,
  ) async {
    requests.add((operation, body));
    return switch (operation) {
      'project.list' => {
        'projects': [
          {'id': 'project', 'name': 'Project', 'path': '/workspace'},
        ],
        'pathEntry': false,
      },
      'chat.list' => {
        'chats': [_chat],
        'cursor': null,
      },
      'chat.snapshot' => {
        'version': 1,
        'chat': _chat,
        'status': 'idle',
        'cursor': null,
        'messages': <Map<String, dynamic>>[],
        if (question != null) 'question': question,
      },
      'chat.question.reply' => () {
        question = null;
        return {'version': 1, 'accepted': true};
      }(),
      _ => throw UnimplementedError(),
    };
  }

  Map<String, dynamic> get _chat => {
    'id': _fixture['reply']['sessionId'],
    'title': 'Question presentation',
    'updatedAt': 1000,
  };
}
