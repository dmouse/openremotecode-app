import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/ui/chat_details_screen.dart';
import 'package:openremotecode/features/chat/ui/chat_flow_screen.dart';
import 'package:openremotecode/features/chat/ui/chat_list_view.dart';
import 'package:openremotecode/features/chat/ui/mcp_section.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

import 'support/mcp_fakes.dart';

void main() {
  testWidgets(
    'tap existing title opens dot-only MCP status and preserved draft',
    (tester) async {
      final repo = McpRepositoryFake();
      await _show(tester, repo);
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        'Keep draft',
      );
      expect(repo.subscriptions, isEmpty);
      await tester.tap(find.byTooltip('Fixture chat'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatDetailsScreen), findsOneWidget);
      expect(find.text('Location'), findsNothing);
      // The breadcrumb and project path are gone; details open on MCP status.
      expect(find.byTooltip('Laptop · Projects'), findsNothing);
      expect(find.byTooltip('Fixture project · Chats'), findsNothing);
      expect(find.text('/work/fixture'), findsNothing);
      expect(find.text('Project path'), findsNothing);
      expect(find.text('MCP servers'), findsOneWidget);
      final dividers = find.descendant(
        of: find.byType(ChatDetailsScreen),
        matching: find.byType(Divider, skipOffstage: false),
        skipOffstage: false,
      );
      expect(dividers, findsNWidgets(3));
      final positions = [
        tester.getTopLeft(find.text('Fixture chat')).dy,
        tester.getTopLeft(dividers.at(0)).dy,
        tester.getTopLeft(find.text('MCP servers')).dy,
        tester.getTopLeft(dividers.at(1)).dy,
        tester.getTopLeft(find.text('Show image previews')).dy,
        tester.getTopLeft(dividers.at(2)).dy,
      ];
      expect(positions, orderedEquals([...positions]..sort()));
      expect(
        tester.widget<Text>(find.text('Fixture chat')).textAlign,
        TextAlign.center,
      );
      // The toggle label reads at the MCP server list's text size, not a
      // tile's larger default, with a bolder weight and a smaller description.
      final body = Theme.of(tester.element(find.byType(ChatDetailsScreen)))
          .textTheme
          .bodyMedium!
          .fontSize!;
      final label = tester
          .widget<Text>(find.text('Show image previews'))
          .style!;
      expect(label.fontSize, body);
      expect(label.fontWeight, FontWeight.w600);
      final description = tester
          .widget<Text>(
            find.text('Preview photos and screenshots inline in this chat.'),
          )
          .style!;
      expect(description.fontSize, lessThan(body));
      expect(description.fontWeight, isNot(FontWeight.w600));
      for (final divider in tester.widgetList<Divider>(dividers)) {
        expect(divider.thickness, 1);
        expect(divider.color, AppTheme.border);
      }
      expect(repo.subscriptions.length, 1);
      await tester.scrollUntilVisible(find.text('context7'), 180);
      expect(find.text('Connected'), findsNothing);
      expect(find.text('Live status'), findsNothing);
      final section = find.byType(McpSection);
      expect(
        find.descendant(of: section, matching: find.byType(ButtonStyleButton)),
        findsNothing,
      );
      expect(
        find.descendant(of: section, matching: find.byType(ListTile)),
        findsNothing,
      );
      expect(
        find.descendant(of: section, matching: find.byType(TextField)),
        findsNothing,
      );
      await tester.tap(find.text('context7'));
      await tester.pump();
      expect(
        repo.calls.where((c) => c.$1.startsWith('project.mcp.')).length,
        1,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        repo.calls.lastWhere((call) => call.$1.startsWith('project.mcp.')).$1,
        'project.mcp.unsubscribe',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('chat-composer')))
            .controller!
            .text,
        'Keep draft',
      );
      expect(find.text('Conversation stays available.'), findsOneWidget);
      expect(repo.calls.any((c) => c.$2.containsKey('includeMcp')), isFalse);
      await tester.pump(const Duration(seconds: 60));
      expect(repo.subscriptions.length, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'draft details subscribe without creating a chat and release on close',
    (tester) async {
      final repo = McpRepositoryFake();
      final model = await _show(tester, repo);
      model.back();
      await tester.pumpAndSettle();
      model.startNewChat();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New chat'));
      await tester.pumpAndSettle();
      expect(find.text('Chat status: Draft'), findsNothing);
      expect(find.text('Online'), findsNothing);
      expect(find.text('MCP servers'), findsOneWidget);
      expect(repo.subscriptions.length, 1);
      expect(repo.calls.any((c) => c.$1 == 'chat.create'), isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(model.page, ChatPage.conversation);
      expect(
        repo.calls.where((c) => c.$1 == 'project.mcp.unsubscribe').length,
        1,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final state in [
    'empty',
    'unavailable',
    'failure',
    'unsupported',
    'offline',
    'loading',
  ]) {
    testWidgets('details explicitly label $state without green MCP status', (
      tester,
    ) async {
      final repo = McpRepositoryFake();
      final model = await _show(tester, repo);
      switch (state) {
        case 'empty':
          repo.data['servers'] = [];
        case 'unavailable':
          repo.data = {...repo.data, 'state': 'unavailable', 'servers': []};
        case 'failure':
          repo.failure = ChatFailure.unavailable;
        case 'unsupported':
          repo.capabilities.clear();
        case 'offline':
          repo.online = false;
          repo.changes.add(null);
        case 'loading':
          repo.pending = Completer<Map<String, dynamic>>();
      }
      await tester.pump();
      await tester.tap(find.byTooltip('Fixture chat'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byType(McpSection), 180);
      expect(
        find.text(switch (state) {
          'empty' => 'No MCP servers configured.',
          'unsupported' => 'MCP status is not supported by this connector. Restart OpenCode with the updated Remote plugin.',
          'offline' => 'Offline. MCP status is not live.',
          'loading' => 'Loading MCP server status...',
          _ => 'MCP status unavailable.',
        }),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(McpSection),
          matching: find.byIcon(Icons.circle),
        ),
        findsNothing,
      );
      if (state == 'unsupported' || state == 'offline') {
        expect(repo.subscriptions, isEmpty);
      }
      expect(model.error, isNull);
      if (repo.pending != null) {
        repo.pending!.complete(repo.update());
        await tester.pump();
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'narrow large text has passive status semantics and no live dot offline',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      final repo = McpRepositoryFake();
      await _show(tester, repo);
      tester.platformDispatcher.textScaleFactorTestValue = 2.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
      await tester.tap(find.byTooltip('Fixture chat'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('context7'), 220);
      await tester.pumpAndSettle();
      final row = find.bySemanticsLabel('context7: Connected');
      final node = tester.getSemantics(row).getSemanticsData();
      expect(node.hasAction(SemanticsAction.tap), isFalse);
      expect(node.hasAction(SemanticsAction.longPress), isFalse);
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byType(McpSection),
                matching: find.byIcon(Icons.circle),
              ),
            )
            .color,
        AppTheme.success,
      );
      await tester.scrollUntilVisible(
        find.text('Needs client registration'),
        220,
      );
      expect(tester.takeException(), isNull);
      repo.online = false;
      repo.changes.add(null);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(McpSection),
          matching: find.byIcon(Icons.circle),
        ),
        findsNothing,
      );
      await tester.scrollUntilVisible(find.text('context7'), -220);
      await tester.pumpAndSettle();
      expect(find.textContaining('Connected'), findsNothing);
      expect(
        find.bySemanticsLabel('context7: Last known: Connected. Not live.'),
        findsOneWidget,
      );
      expect(find.text('Last-known status. Not live.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      repo.online = true;
      repo.data['servers'] = [
        {'name': 'x' * 128, 'status': 'connected'},
      ];
      repo.changes.add(null);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('x' * 128), 220);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('x' * 128)).maxLines, isNull);
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'background and covering route stop subscription; resume renews a fresh source',
    (tester) async {
      final repo = McpRepositoryFake();
      await _show(tester, repo);
      await tester.tap(find.byTooltip('Fixture chat'));
      await tester.pumpAndSettle();
      final first = repo.subscriptionId;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(
        repo.calls.where((c) => c.$1 == 'project.mcp.unsubscribe').length,
        1,
      );
      await tester.pump(const Duration(seconds: 60));
      expect(repo.subscriptions.length, 1);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(repo.subscriptionId, isNot(first));
      final second = repo.subscriptionId;
      final context = tester.element(find.byType(ChatDetailsScreen));
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Cover')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.calls.last.$1, 'project.mcp.unsubscribe');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(repo.subscriptionId, isNot(second));
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final transition in ['trust', 'source']) {
    testWidgets('$transition clears details before late MCP completion', (
      tester,
    ) async {
      final repo = McpRepositoryFake()
        ..pending = Completer<Map<String, dynamic>>();
      final model = await _show(tester, repo);
      await tester.tap(find.byTooltip('Fixture chat'));
      await tester.pumpAndSettle();
      final late = repo.update(revision: 100);
      if (transition == 'trust') {
        repo.trusted = false;
        repo.changes.add(null);
      } else {
        model.backToProjects();
      }
      await tester.pump();
      expect(find.text('MCP servers'), findsNothing);
      repo.pending!.complete(late);
      await tester.pumpAndSettle();
      expect(find.byType(ChatDetailsScreen), findsNothing);
      expect(find.text('context7'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

Future<ChatViewModel> _show(WidgetTester tester, McpRepositoryFake repo) async {
  addTearDown(repo.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: ChatFlowScreen(
        repository: repo,
        connectorId: 'connector',
        connectionName: 'Laptop',
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Fixture project'));
  await tester.tap(find.text('Fixture project'));
  await tester.pumpAndSettle();
  final model = tester.widget<ChatListView>(find.byType(ChatListView)).model;
  await tester.scrollUntilVisible(
    find.text('Fixture chat'),
    150,
    scrollable: find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.tap(find.text('Fixture chat'));
  await tester.pumpAndSettle();
  return model;
}
