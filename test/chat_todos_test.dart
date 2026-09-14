import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/chat_flow_screen.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/features/chat/ui/todo_banner.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

final _fixture = jsonDecode(
  File('../packages/protocol/test/fixtures/chat-todos-v1.json')
      .readAsStringSync(),
) as Map<String, dynamic>;
List<dynamic> get _todos => _fixture['response']['todos'] as List<dynamic>;
Map<String, dynamic> get _todo => _todos.first as Map<String, dynamic>;

void main() {
  test('the shared fixture parses with strict fields', () {
    final todos = parseTodos(_fixture['response'] as Map<String, dynamic>)!;
    expect(todos.length, 5);
    // Ids are positional: OpenCode 1.18.30 sends none of its own.
    expect(todos.first.id, 'todo-0');
    expect(todos.first.content, 'Read the relay contract');
    expect(todos.first.done, isTrue);
    expect(todos[1].running, isTrue);
    expect(todos[1].label, 'In progress');
    expect(todos[2].label, 'To do');
    expect(todos[3].cancelled, isTrue);
    expect(todos[3].label, 'Cancelled');
  });

  test('unknown statuses, oversized text and extra keys are rejected', () {
    for (final invalid in <Map<String, dynamic>>[
      {..._todo, 'status': 'queued'},
      {..._todo, 'status': ''},
      {..._todo, 'content': ''},
      {..._todo, 'content': 'c' * 257},
      {..._todo, 'priority': 'high'},
      {..._todo, 'extra': 'unexpected'},
    ]) {
      expect(() => ChatTodo.parse(invalid), throwsFormatException);
    }
    // A blank or oversized id fails through the shared string check, the way
    // every other identifier in this protocol already does.
    for (final invalid in <Map<String, dynamic>>[
      {..._todo, 'id': ''},
      {..._todo, 'id': 'i' * 129},
    ]) {
      expect(() => ChatTodo.parse(invalid), throwsA(isA<Exception>()));
    }
  });

  test(
    'an absent list is not an empty one, and duplicate ids are rejected',
    () {
      expect(parseTodos({'version': 1}), isNull);
      expect(parseTodos({'todos': <dynamic>[]}), isEmpty);
      expect(
        () => parseTodos({
          'todos': [_todo, _todo],
        }),
        throwsFormatException,
      );
      expect(
        () => parseTodos({
          'todos': [
            for (var index = 0; index < 101; index++)
              {'id': 'tod_$index', 'content': 'Task', 'status': 'pending'},
          ],
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'the snapshot opts in only when the connector offers the list',
    () async {
      final repo = _Repository();
      final model = ChatViewModel(repo, 'connector');
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      await model.openChat(model.chatList.chats.single);
      final snapshot = repo.requests.firstWhere((r) => r.$1 == 'chat.snapshot');
      expect(snapshot.$2['includeTodos'], isTrue);
      expect(model.conversation.todosDone, 1);
      expect(model.conversation.todosTotal, 5);
      model.dispose();

      final without = _Repository()..todosSupported = false;
      final plain = ChatViewModel(without, 'connector');
      await plain.refresh();
      await plain.openProject(plain.projects.projects.single);
      await plain.openChat(plain.chatList.chats.single);
      final read = without.requests.firstWhere((r) => r.$1 == 'chat.snapshot');
      expect(read.$2.containsKey('includeTodos'), isFalse);
      expect(plain.conversation.todos, isEmpty);
      plain.dispose();
    },
  );

  test('leaving the chat drops its task list', () async {
    final repo = _Repository();
    final model = ChatViewModel(repo, 'connector');
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    await model.openChat(model.chatList.chats.single);
    expect(model.conversation.todosTotal, 5);
    model.back();
    expect(model.conversation.todos, isEmpty);
    model.dispose();
  });

  testWidgets('the task tab counts done tasks over the whole list', (
    tester,
  ) async {
    final model = ChatViewModel(_Repository(), 'connector')
      ..conversation.todos = parseTodos(
        _fixture['response'] as Map<String, dynamic>,
      )!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [TodoTab(model: model.conversation, onTap: () {})],
          ),
        ),
      ),
    );
    expect(find.text('Tasks'), findsOneWidget);
    expect(find.text('1/5'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('todo-tab'))).label,
      contains('Tasks, 1 of 5 done'),
    );
    // It hangs from the header downwards, raised so it reads as floating over
    // the messages, and its outline grows out of the header line: the ink
    // flares past the tab's box where the tab starts and ends, and rounds off
    // on the two corners hanging in the conversation.
    final tab = tester.widget<Material>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('todo-tab')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(tab.elevation, greaterThan(0));
    final outline = tab.shape!.getOuterPath(const Rect.fromLTWH(0, 0, 120, 28));
    // Beyond both ends, on the header line itself.
    expect(outline.contains(const Offset(-4, 1)), isTrue);
    expect(outline.contains(const Offset(124, 1)), isTrue);
    // ...but curving back in, so the flare is a fillet and not a ledge.
    expect(outline.contains(const Offset(-9, 9)), isFalse);
    expect(outline.contains(const Offset(129, 9)), isFalse);
    // Hanging corners rounded, the middle of the bottom edge still square on.
    expect(outline.contains(const Offset(1, 27)), isFalse);
    expect(outline.contains(const Offset(60, 27)), isTrue);
    // It hugs its one line: no dead ink above or below the label, and the
    // visible tab is the whole tap target -- nothing invisible hangs below it
    // over the conversation.
    final box = tester.getRect(find.byKey(const ValueKey('todo-tab')));
    final label = tester.getRect(find.text('Tasks'));
    expect(box.height, lessThanOrEqualTo(label.height + 16));
    // Width is the dimension it spends: the side padding is much wider than
    // the space above and below the line.
    expect(box.width, greaterThan(label.width * 2));
    expect(box.height, tester.getRect(find.byType(TodoTab)).height);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });

  testWidgets('the tab is absent while the chat has no task list', (
    tester,
  ) async {
    final model = ChatViewModel(_Repository(), 'connector');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [TodoTab(model: model.conversation, onTap: () {})],
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('todo-tab')), findsNothing);
    // Nothing is drawn and nothing is reserved: no empty or zeroed tab.
    expect(tester.getSize(find.byType(TodoTab)), Size.zero);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });

  testWidgets('the tab floats over the conversation, not in the header', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: ChatFlowScreen(
          repository: _Repository(),
          connectorId: 'connector',
          connectionName: 'Laptop',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Todo presentation'));
    await tester.pumpAndSettle();
    final tab = find.byKey(const ValueKey('todo-tab'));
    expect(tab, findsOneWidget);
    // Out of the bar: the header keeps Back, the title block and Chat options,
    // and the tab is no longer one of its actions.
    expect(
      find.descendant(of: find.byType(AppBar), matching: tab),
      findsNothing,
    );
    // It hangs from the middle of the header's hairline and floats over the
    // conversation: the list still starts where the tab does, so the tab took
    // none of its height.
    final list = tester.getRect(find.byType(ConversationView));
    final box = tester.getRect(tab);
    expect(box.top, list.top);
    expect(box.bottom, lessThan(list.bottom));
    expect(box.center.dx, moreOrLessEquals(list.center.dx, epsilon: 0.5));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping the tab opens the banner listing every task', (
    tester,
  ) async {
    final model = ChatViewModel(_Repository(), 'connector')
      ..conversation.todos = parseTodos(
        _fixture['response'] as Map<String, dynamic>,
      )!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TodoTab(
              model: model.conversation,
              onTap: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => TodoBanner(model: model.conversation),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('todo-tab')));
    await tester.pumpAndSettle();
    // 'Tasks' also labels the tab behind the sheet, so the heading is matched
    // inside the banner rather than anywhere on screen.
    expect(
      find.descendant(
        of: find.byType(TodoBanner),
        matching: find.text('Tasks'),
      ),
      findsOneWidget,
    );
    expect(find.text('1 of 5 done'), findsOneWidget);
    expect(find.text('Read the relay contract'), findsOneWidget);
    expect(find.text('Add the todo tab'), findsOneWidget);
    expect(find.text('Drop the old spike'), findsOneWidget);
    // Every state is also named in words, never only drawn.
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('To do'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });

  testWidgets('an empty list says so rather than showing a bare sheet', (
    tester,
  ) async {
    final model = ChatViewModel(_Repository(), 'connector');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TodoBanner(model: model.conversation)),
      ),
    );
    expect(find.text('This chat has no task list yet.'), findsOneWidget);
    expect(find.text('None'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });

  test('hiding a finished list keeps it, and it can be asked back', () async {
    final model = ChatViewModel(
      _Repository()..todosFinished = true,
      'connector',
    );
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    await model.openChat(model.chatList.chats.single);
    expect(model.conversation.todosDone, 5);
    expect(model.conversation.canShowTodos, isFalse);

    model.conversation.hideTodos();
    // Hiding withholds the tab; it never touches the list behind it.
    expect(model.conversation.todosHidden, isTrue);
    expect(model.conversation.todosTotal, 5);
    expect(model.conversation.canShowTodos, isTrue);

    model.conversation.showTodos();
    expect(model.conversation.todosHidden, isFalse);
    expect(model.conversation.canShowTodos, isFalse);
    // Nothing to show once nothing is held back.
    model.conversation.showTodos();
    expect(model.conversation.todosHidden, isFalse);
    model.dispose();
  });

  test('a list that stops being finished comes back on its own', () async {
    final repository = _Repository()..todosFinished = true;
    final model = ChatViewModel(repository, 'connector');
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    await model.openChat(model.chatList.chats.single);
    model.conversation.hideTodos();
    expect(model.conversation.todosHidden, isTrue);
    // The agent writes a plan that is no longer all done: an old dismissal of
    // a different, finished list must not hide this one.
    repository.todosFinished = false;
    await model.refresh();
    expect(model.conversation.todosHidden, isFalse);
    expect(model.conversation.canShowTodos, isFalse);
    // Once that plan is finished too, it is shown: the old dismissal was of
    // the earlier list and ended when the list stopped being done.
    repository.todosFinished = true;
    await model.refresh();
    expect(model.conversation.todosHidden, isFalse);
    model.dispose();
  });

  test('a dismissal holds across leaving and re-entering the chat', () async {
    final repository = _Repository()..todosFinished = true;
    final model = ChatViewModel(repository, 'connector');
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    await model.openChat(model.chatList.chats.single);
    model.conversation.hideTodos();

    // Back to the chat list, which reloads it, then into the same chat again.
    Future<void> reenter() async {
      model.back();
      expect(model.conversation.todos, isEmpty);
      await pumpEventQueue();
      await model.openChat(model.chatList.chats.single);
      expect(model.conversation.todosTotal, 5);
    }

    await reenter();
    expect(model.conversation.todosHidden, isTrue);
    expect(model.conversation.canShowTodos, isTrue);

    // Bringing it back is remembered the same way.
    model.conversation.showTodos();
    await reenter();
    expect(model.conversation.todosHidden, isFalse);

    // A different finished plan is not covered by a dismissal of this one.
    model.conversation.hideTodos();
    repository.todosContent = 'A new plan';
    await reenter();
    expect(model.conversation.todosDone, 5);
    expect(model.conversation.todosHidden, isFalse);
    model.dispose();
  });

  test('a failed read keeps the dismissal rather than forgetting it', () async {
    final repository = _Repository()..todosFinished = true;
    final model = ChatViewModel(repository, 'connector');
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    await model.openChat(model.chatList.chats.single);
    model.conversation.hideTodos();
    // The plugin reports a failed native read as an empty list.
    repository.todosEmpty = true;
    await model.refresh();
    expect(model.conversation.todosHidden, isFalse);
    repository.todosEmpty = false;
    await model.refresh();
    expect(model.conversation.todosHidden, isTrue);
    model.dispose();
  });

  testWidgets('a dismissed list comes back from Chat options', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: ChatFlowScreen(
          repository: _Repository()..todosFinished = true,
          connectorId: 'connector',
          connectionName: 'Laptop',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Project'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Todo presentation'));
    await tester.pumpAndSettle();
    final tab = find.byKey(const ValueKey('todo-tab'));
    expect(find.text('5/5'), findsOneWidget);

    // Dismissing the finished list from the sheet closes it and takes the tab
    // with it -- the one way back into the list.
    await tester.tap(tab);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('todo-hide')));
    await tester.pumpAndSettle();
    expect(find.byType(TodoBanner), findsNothing);
    expect(tab, findsNothing);

    // So Chat options carries the way back, and only while a list is held.
    await tester.tap(find.byTooltip('Chat options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show task list'));
    await tester.pumpAndSettle();
    expect(tab, findsOneWidget);
    expect(find.text('5/5'), findsOneWidget);
    await tester.tap(find.byTooltip('Chat options'));
    await tester.pumpAndSettle();
    expect(find.text('Show task list'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a subtask is never offered a hide it cannot undo', (
    tester,
  ) async {
    final model = ChatViewModel(_Repository(), 'connector')
      ..conversation.todos = [
        for (final todo in _todos)
          ChatTodo.parse({
            ...todo as Map<String, dynamic>,
            'status': 'completed',
          }),
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TodoBanner(model: model.conversation)),
      ),
    );
    expect(find.byKey(const ValueKey('todo-hide')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    model.dispose();

    // A subtask conversation has no Chat options menu to bring the list back,
    // so it is never offered the dismissal in the first place.
    final subtask = ChatViewModel(
      _Repository(),
      'connector',
      parentSessionId: 'ses_parent',
    )..conversation.todos = model.conversation.todos;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TodoBanner(model: subtask.conversation)),
      ),
    );
    expect(subtask.isSubtask, isTrue);
    expect(find.byKey(const ValueKey('todo-hide')), findsNothing);
    expect(find.text('5 of 5 done'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    subtask.dispose();
  });
}

class _Repository implements ChatRepository {
  bool todosSupported = true;

  /// Serves the shared fixture's list with every task completed -- the only
  /// state in which the list can be dismissed.
  bool todosFinished = false;

  /// Replaces every task's text, standing in for the agent writing a new plan.
  String? todosContent;

  /// Serves an empty list, as the plugin does when its native read fails.
  bool todosEmpty = false;
  final requests = <(String, Map<String, dynamic>)>[];

  List<dynamic> get _served => todosEmpty
      ? const []
      : [
          for (final (index, todo) in _todos.indexed)
            {
              ...todo as Map<String, dynamic>,
              if (todosFinished) 'status': 'completed',
              if (todosContent case final content?)
                'content': '$content $index',
            },
        ];

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
  bool chatSupports(String connectorId, String operation) =>
      operation == 'chat.todos' && todosSupported;
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
        'chats': [_fixture['response']['chat']],
        'cursor': null,
      },
      'chat.snapshot' => {
        'version': 1,
        'chat': _fixture['response']['chat'],
        'status': 'idle',
        'cursor': null,
        'messages': <Map<String, dynamic>>[],
        if (todosSupported) 'todos': _served,
      },
      _ => throw UnimplementedError(),
    };
  }
}
