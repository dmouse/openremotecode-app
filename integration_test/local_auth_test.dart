import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openremotecode/features/auth/auth_repository.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/domain/mcp_models.dart';
import 'package:openremotecode/features/chat/ui/chat_details_screen.dart';
import 'package:openremotecode/features/chat/ui/chat_flow_screen.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/features/chat/ui/activity_animation.dart';
import 'package:openremotecode/features/chat/ui/typing_indicator.dart';
import 'package:openremotecode/features/chat/ui/mcp_section.dart';
import 'package:openremotecode/features/connections/data/api_connections_repository.dart';
import 'package:openremotecode/features/connections/data/device_identity.dart';
import 'package:openremotecode/features/connections/domain/remote_connection.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/platform/remote_api.dart';
import 'package:openremotecode/platform/secure_store.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

// Run only against a disposable local development server with registration enabled.
// Launch through tool/test_local_android.sh: a separate Android application ID
// and --no-uninstall protect the interactive app. Key prefixes alone cannot.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native login, secure restoration, rotation and logout', (
    tester,
  ) async {
    final server = ServerEndpoint.parse(
      'http://127.0.0.1:8080',
      allowLoopbackHttp: true,
    );
    const api = HttpRemoteApi();
    final suffix = DateTime.now().microsecondsSinceEpoch.toString();
    final email = 'mobile-test-$suffix@example.test';
    final password = base64UrlEncode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final store = _IsolatedStore(suffix);
    final auth = AuthRepository(api: api, store: store);
    final restored = AuthRepository(api: api, store: store);
    addTearDown(() async {
      await restored.logout();
      await auth.logout();
      await store.delete(AuthRepository.storageKey(server));
      auth.dispose();
      restored.dispose();
    });

    final registered = await api.request(
      server,
      '/v1/auth/register',
      method: 'POST',
      body: {
        'email': email,
        'password': password,
        'clientName': 'Mobile native integration test',
      },
    );
    final registrationCookie = registered.credential('refresh', server);
    await api.request(
      server,
      '/v1/auth/logout',
      method: 'POST',
      cookie: '${registrationCookie.name}=${registrationCookie.value}',
    );

    expect(await auth.login(server, email, 'incorrect-password'), isFalse);
    expect(auth.session, isNull);
    expect(
      await auth.login(server, email, password),
      isTrue,
      reason: auth.error,
    );
    final accountId = auth.session!.accountId;
    final key = AuthRepository.storageKey(server);
    final first = await store.read(key);
    expect(first, isNotNull);
    // Boolean assertions keep credentials out of test failure output.
    expect(first!.contains(password), isFalse);
    expect(first.contains(auth.session!.accessToken), isFalse);

    await restored.restore(server);
    expect(restored.session?.accountId, accountId, reason: restored.error);
    expect(await store.read(key) != first, isTrue);
    final account = await restored.request('/v1/account');
    expect(requiredMap(account.body, 'user')['id'], accountId);
    await verifyPairing(restored, api, server, tester);
    expect(await restored.logout(), isTrue);
    expect(await store.read(key), isNull);
    await restored.restore(server);
    expect(restored.session, isNull);
  });
}

Future<void> verifyPairing(
  AuthRepository auth,
  RemoteApi api,
  ServerEndpoint server,
  WidgetTester tester,
) async {
  final repository = ApiConnectionsRepository(auth);
  String? connectorCredential;
  try {
    final identity = await compute(generateDeviceKey, null);
    final challenge = await api.request(
      server,
      '/v1/connector-pairings/challenge',
      method: 'POST',
      body: {},
    );
    final proof = await compute(signDeviceChallenge, {
      'identity': identity,
      'challenge': challenge.body['challenge'],
    });
    final pairing = await api.request(
      server,
      '/v1/connector-pairings',
      method: 'POST',
      body: {
        'name': 'Mobile integration connector',
        'identity': PublicIdentity.parse(identity).toJson(),
        'proof': proof,
      },
    );
    final review = await repository.reviewPairing(
      requiredString(pairing.body, 'userCode'),
    );
    Future<Map<String, dynamic>> poll() async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          server.uri.replace(
            path: '/v1/connector-pairings/${pairing.body['pairingId']}/poll',
          ),
        );
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Pairing ${pairing.body['pairingSecret']}',
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        return jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
      } finally {
        client.close(force: true);
      }
    }

    final reviewed = await poll();
    expect(
      pairingSafetyCode(requiredMap(reviewed, 'transcript')),
      review.safetyCode,
    );
    final connection = await repository.confirmPairing(review);
    expect(
      await repository.renameConnection(connection.id, '  My workstation  '),
      'My workstation',
    );
    expect((await repository.listConnections()).single.name, 'My workstation');
    final completed = await poll();
    connectorCredential = requiredString(completed, 'connectorCredential');
    expect((await repository.listConnections()).single.id, connection.id);

    final fixtureClient = HttpClient();
    late Map<String, dynamic> fixture;
    try {
      final request = await fixtureClient.postUrl(
        Uri.parse('http://127.0.0.1:8092/initialize'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'identity': {
            ...identity,
            'createdAt': DateTime.now().millisecondsSinceEpoch,
          },
          'authorization': {
            'version': 1,
            'serviceOrigin': server.uri.origin,
            'connectorId': connection.id,
            'connectorKeyId': identity['keyId'],
            'credential': connectorCredential,
            'credentialExpiresAt': completed['connectorCredentialExpiresAt'],
            'trustedClient': requiredMap(
              requiredMap(reviewed, 'transcript'),
              'deviceIdentity',
            ),
          },
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      fixture = jsonDecode(
        await utf8.decoder.bind(response).join(),
      ) as Map<String, dynamic>;
      expect(
        response.statusCode,
        200,
        reason: response.statusCode == 500
            ? 'Fixture stage: ${fixture['stage']}; timeout: ${fixture['timeout']}'
            : null,
      );
    } finally {
      fixtureClient.close(force: true);
    }
    final online = repository.presence
        .firstWhere(
          (statuses) => statuses[connection.id] == ConnectionStatus.online,
        )
        .timeout(const Duration(seconds: 15));
    repository.setActive(true);
    await online;
    // Native HPKE → authenticated production relay → real plugin dispatcher →
    // pinned OpenCode, with authoritative replies encrypted back to Android.
    final projects = await repository.chatRequest(
      connection.id,
      'project.list',
      {},
    );
    final project =
        (projects['projects'] as List).single as Map<String, dynamic>;
    final projectId = project['id'];
    final listed = await repository.chatRequest(connection.id, 'chat.list', {
      'projectId': projectId,
    });
    expect(
      (listed['chats'] as List).any((c) => c['id'] == fixture['sessionId']),
      isTrue,
    );
    expect(
      (listed['chats'] as List).any(
        (c) => c['id'] == fixture['childSessionId'],
      ),
      isFalse,
    );
    final snapshot = await repository.chatRequest(
      connection.id,
      'chat.snapshot',
      {
        'projectId': projectId,
        'sessionId': fixture['sessionId'],
        'includeSubtasks': true,
        'includeTools': true,
      },
    );
    expect(
      (snapshot['messages'] as List).any(
        (m) => m['text'].contains('Native encrypted chat fixture'),
      ),
      isTrue,
    );
    final presentation = ChatViewModel(repository, connection.id)
      ..conversation.messages = parseItems(
        snapshot,
        'messages',
        10,
        ChatMessage.parse,
      );
    try {
      expect(
        presentation.conversation.messages.any(
          (m) => m.text.contains('[File: example.txt]'),
        ),
        isTrue,
      );
      expect(
        presentation.conversation.messages.any(
          (m) =>
              m.text.contains('PRIVATE_ATTACHMENT_CONTENT') ||
              m.text.contains('Called the Read tool'),
        ),
        isFalse,
      );
      final thoughts = presentation.conversation.messages
          .expand((m) => m.parts ?? <ChatMessagePart>[])
          .where((p) => p.isReasoning)
          .toList();
      expect(thoughts.map((p) => p.durationMs), [8000, 471]);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            backgroundColor: AppTheme.chatBackground,
            body: ConversationView(model: presentation.conversation),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final title = find.text(
        'Thought: Checking emulator pairing · 8.0s',
        findRichText: true,
      );
      expect(title, findsOneWidget);
      expect(
        find.text(
          'Thought: Updating pairing status · 471ms',
          findRichText: true,
        ),
        findsOneWidget,
      );
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsNothing);
      expect(
        find.text('Synthetic reasoning detail.', findRichText: true),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      presentation.dispose();
    }
    final taskMessage = parseItems(snapshot, 'messages', 10, ChatMessage.parse)
        .singleWhere(
          (message) => message.parts?.any((part) => part.task != null) == true,
        );
    final task = taskMessage.parts!
        .singleWhere((part) => part.task != null)
        .task!;
    expect(task.sessionId, fixture['childSessionId']);
    expect(task.toolCalls, 15);
    expect(task.statsComplete, isTrue);
    expect(task.durationMs, 82000);
    final taskPresentation = ChatViewModel(repository, connection.id)
      ..conversation.messages = [taskMessage];
    final childView = ChatViewModel(
      repository,
      connection.id,
      parentSessionId: fixture['sessionId'] as String,
    )..project = RemoteProject.parse(project);
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ConversationView(model: taskPresentation.conversation),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Explore Task — Inspect mobile color palette'),
        findsOneWidget,
      );
      expect(find.text('Completed · 15 toolcalls · 1m 22s'), findsOneWidget);
      await childView.openChat(
        RemoteChat(
          task.sessionId!,
          task.title,
          DateTime.fromMillisecondsSinceEpoch(0),
          parentId: fixture['sessionId'] as String,
        ),
      );
      expect(childView.error, isNull);
      expect(
        childView.conversation.messages
            .expand((m) => m.parts ?? <ChatMessagePart>[])
            .where((p) => p.tool != null),
        hasLength(15),
      );
      expect(childView.conversation.canSend, isFalse);
      expect(
        childView.conversation.messages.any(
          (message) => message.text.contains('The palette uses deep green.'),
        ),
        isTrue,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: ConversationView(model: childView.conversation)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The palette uses deep green.', findRichText: true),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      taskPresentation.dispose();
      childView.dispose();
    }
    final shellView = ChatViewModel(repository, connection.id);
    try {
      await shellView.refresh();
      await shellView.openProject(shellView.projects.projects.single);
      await shellView.openChat(
        shellView.chatList.chats.singleWhere(
          (chat) => chat.id == fixture['shellSessionId'],
        ),
      );
      expect(shellView.error, isNull);
      final shellMessage = shellView.conversation.messages.singleWhere(
        (m) => m.role == 'assistant',
      );
      final shell = shellMessage.parts!.single.tool!.shell!;
      expect(shell.command, "printf 'shell fixture\\n'");
      expect(shell.output, 'shell fixture\n');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: ConversationView(model: shellView.conversation)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('You'), findsNothing);
      expect(find.text(shell.command), findsNothing);
      expect(find.text(shell.output), findsNothing);
      final toggle = find.descendant(
        of: find.byKey(ValueKey('message-${shellMessage.id}')),
        matching: find.byType(TextButton),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text(shell.command), findsOneWidget);
      expect(find.text(shell.output), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text(shell.command), findsNothing);
      expect(find.text(shell.output), findsNothing);
      // Keep the user's choice while the live subscription is active.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 4)),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: ConversationView(model: shellView.conversation)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(shell.command), findsNothing);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text(shell.output), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: shellView,
              builder: (_, _) =>
                  ConversationView(model: shellView.conversation),
            ),
          ),
        ),
      );
      final readyDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (!shellView.conversation.activityLive &&
          DateTime.now().isBefore(readyDeadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(shellView.conversation.activityLive, isTrue);
      final fixtureHttp = HttpClient();
      try {
        final request = await fixtureHttp.postUrl(
          Uri.parse('http://127.0.0.1:8092/chat/stream'),
        );
        final done = request.close().then((response) async {
          expect(response.statusCode, 200);
          await response.drain<void>();
        });
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        ChatMessage? running;
        while (running == null && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          running = shellView.conversation.messages
              .where(
                (m) =>
                    m.parts?.any(
                      (p) =>
                          p.activity?.state == 'running' &&
                          p.tool?.shell?.output == 'stream first\n',
                    ) ==
                    true,
              )
              .firstOrNull;
        }
        expect(
          running,
          isNotNull,
          reason: 'Running tool output must arrive before native execution finishes',
        );
        await tester.tap(
          find.descendant(
            of: find.byKey(ValueKey('message-${running!.id}')),
            matching: find.byType(TextButton),
          ),
        );
        await tester.pump();
        expect(find.text('stream first\n'), findsOneWidget);
        var thinking = false;
        while (!thinking && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          thinking = shellView.conversation.messages.any(
            (m) =>
                m.parts?.any(
                  (p) =>
                      p.isReasoning &&
                      p.activity?.running == true &&
                      p.text.startsWith('Inspecting'),
                ) ==
                true,
          );
        }
        expect(
          thinking,
          isTrue,
          reason: 'Native reasoning must be visible before completion',
        );
        expect(shellView.conversation.status, 'busy');
        await tester.pump();
        expect(
          find.textContaining('Thinking: Inspecting', findRichText: true),
          findsOneWidget,
        );
        expect(
          tester
              .widgetList<ActivitySpinner>(find.byType(ActivitySpinner))
              .any((icon) => icon.running),
          isTrue,
        );
        expect(tester.binding.transientCallbackCount, greaterThan(0));
        expect(find.byType(TypingIndicator), findsOneWidget);
        var partial = false;
        while (!partial && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          partial = shellView.conversation.messages.any(
            (m) =>
                m.parts?.any(
                  (p) => p.type == 'text' && p.text == 'Live answer\n',
                ) ==
                true,
          );
        }
        expect(
          partial,
          isTrue,
          reason: 'Assistant text must appear incrementally',
        );
        await done;
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Live answer completed', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('stream first\nstream last\n'), findsOneWidget);
        expect(find.byType(TypingIndicator), findsNothing);
      } finally {
        fixtureHttp.close(force: true);
      }
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      shellView.dispose();
    }
    final emptyDraft = ChatViewModel(repository, connection.id);
    try {
      await emptyDraft.refresh();
      await emptyDraft.openProject(emptyDraft.projects.projects.single);
      emptyDraft.startNewChat();
      expect(emptyDraft.conversation.isDraft, isTrue);
      expect(emptyDraft.conversation.chat, isNull);
      expect(await emptyDraft.conversation.send(' \n '), isFalse);
      await emptyDraft.refresh();
    } finally {
      emptyDraft.dispose();
    }
    final afterDraft = await repository.chatRequest(
      connection.id,
      'chat.list',
      {'projectId': projectId},
    );
    expect(
      (afterDraft['chats'] as List).map((c) => c['id']).toSet(),
      (listed['chats'] as List).map((c) => c['id']).toSet(),
    );
    final firstPrompt = ChatViewModel(repository, connection.id);
    try {
      await firstPrompt.refresh();
      await firstPrompt.openProject(firstPrompt.projects.projects.single);
      firstPrompt.startNewChat();
      expect(
        await firstPrompt.conversation.send('Native first prompt fixture'),
        isTrue,
      );
      expect(firstPrompt.conversation.chat, isNotNull);
      final afterSend = await repository.chatRequest(
        connection.id,
        'chat.list',
        {'projectId': projectId},
      );
      expect(
        (afterSend['chats'] as List).length,
        (listed['chats'] as List).length + 1,
      );
      expect(
        (afterSend['chats'] as List).any(
          (c) => c['id'] == firstPrompt.conversation.chat!.id,
        ),
        isTrue,
      );
    } finally {
      firstPrompt.dispose();
    }

    // Insert mutations after the session-count assertions. Read every history
    // page: a fork must not silently copy only the latest snapshot page.
    Future<List<Map<String, dynamic>>> fullHistory(String sessionId) async {
      final messages = <Map<String, dynamic>>[];
      final cursors = <String>{};
      String? cursor;
      do {
        final page = await repository.chatRequest(
          connection.id,
          'chat.snapshot',
          {'projectId': projectId, 'sessionId': sessionId, 'cursor': ?cursor},
        );
        expect(requiredMap(page, 'chat')['id'], sessionId);
        messages.insertAll(
          0,
          (page['messages'] as List).cast<Map<String, dynamic>>(),
        );
        cursor = page['cursor'] as String?;
        if (cursor != null) {
          expect(
            cursors.add(cursor),
            isTrue,
            reason: 'History must make progress',
          );
          expect(cursors.length, lessThan(100));
        }
      } while (cursor != null);
      return messages;
    }

    final mcpSessionId = fixture['sessionId'] as String;
    final beforeMcpHistory = await fullHistory(mcpSessionId);
    await verifyMcpDetails(
      tester,
      repository,
      connection.id,
      RemoteProject.parse(project),
      mcpSessionId,
    );
    expect(await fullHistory(mcpSessionId), beforeMcpHistory);

    final mutations = ChatViewModel(repository, connection.id);
    Future<void> waitForAction() async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      // Periodic snapshot polling can overlap the independent history reads.
      while (!mutations.canRefresh && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(mutations.canRefresh, isTrue, reason: mutations.error);
    }

    String? forkId;
    try {
      await mutations.refresh();
      await mutations.openProject(mutations.projects.projects.single);
      await mutations.openChat(
        mutations.chatList.chats.singleWhere(
          (chat) => chat.id == fixture['sessionId'],
        ),
      );
      final sourceId = mutations.conversation.chat!.id;
      final sourceHistory = await fullHistory(sourceId);
      // Twelve user messages plus the reasoning and subtask assistant messages.
      expect(sourceHistory.length, 14);
      await waitForAction();
      expect(mutations.conversation.canRename, isTrue);
      await mutations.conversation.renameChat('  Native renamed chat  ');
      expect(mutations.error, isNull);
      expect(mutations.conversation.chat?.id, sourceId);
      expect(mutations.conversation.chat?.title, 'Native renamed chat');
      final renamed = await repository.chatRequest(connection.id, 'chat.get', {
        'projectId': projectId,
        'sessionId': sourceId,
      });
      expect(requiredMap(renamed, 'chat')['title'], 'Native renamed chat');
      expect(await fullHistory(sourceId), sourceHistory);
      await waitForAction();
      expect(mutations.conversation.canFork, isTrue);
      await mutations.conversation.forkChat();
      expect(mutations.error, isNull);
      expect(mutations.conversation.chat?.id, isNot(sourceId));
      forkId = mutations.conversation.chat!.id;
      final forkHistory = await fullHistory(forkId);
      // OpenCode assigns new message IDs to the copied history.
      List<Map<String, dynamic>> content(List<Map<String, dynamic>> history) =>
          [
            for (final message in history)
              {
                'role': message['role'],
                'text': message['text'],
                'truncated': message['truncated'],
              },
          ];
      expect(content(forkHistory), content(sourceHistory));
      expect(forkHistory.length, sourceHistory.length);
      await waitForAction();
      await mutations.conversation.renameChat('Native independent fork');
      expect(mutations.error, isNull);
      expect(mutations.conversation.chat?.id, forkId);
      final original = await repository.chatRequest(connection.id, 'chat.get', {
        'projectId': projectId,
        'sessionId': sourceId,
      });
      expect(requiredMap(original, 'chat'), requiredMap(renamed, 'chat'));
      expect(await fullHistory(sourceId), sourceHistory);
      expect(content(await fullHistory(forkId)), content(sourceHistory));
    } finally {
      mutations.dispose();
      if (forkId != null) {
        final deleted = await repository.chatRequest(
          connection.id,
          'chat.delete',
          {'projectId': projectId, 'sessionId': forkId},
        );
        expect(deleted['deleted'], isTrue);
      }
    }
    final opened = await repository.chatRequest(connection.id, 'project.open', {
      'path': project['path'],
    });
    expect(requiredMap(opened, 'project')['id'], projectId);
    await expectLater(
      repository.chatRequest(connection.id, 'project.open', {
        'path': '/not-authorized',
      }),
      throwsA(isA<Exception>()),
    );

    final chatMenu = ChatViewModel(repository, connection.id);
    try {
      await chatMenu.refresh();
      await chatMenu.openProject(chatMenu.projects.projects.single);
      final target = chatMenu.chatList.chats.singleWhere(
        (c) => c.id == fixture['sessionId'],
      );
      await chatMenu.togglePin(target);
      expect(chatMenu.chatList.isPinned(target), isTrue);
      final restoredPins = ApiConnectionsRepository(auth);
      try {
        await restoredPins.listConnections();
        expect(
          await restoredPins.pinnedChatIds(
            connection.id,
            project['path'] as String,
          ),
          contains(target.id),
        );
      } finally {
        restoredPins.dispose();
      }
      await chatMenu.deleteChat(target);
      expect(chatMenu.error, isNull);
      expect(chatMenu.chatList.chats.any((c) => c.id == target.id), isFalse);
      expect(
        await repository.pinnedChatIds(
          connection.id,
          project['path'] as String,
        ),
        isEmpty,
      );
      for (final id in [fixture['sessionId'], fixture['childSessionId']]) {
        await expectLater(
          repository.chatRequest(connection.id, 'chat.get', {
            'projectId': projectId,
            'sessionId': id,
          }),
          throwsA(ChatFailure.notFound),
        );
      }
    } finally {
      chatMenu.dispose();
    }

    repository.dispose();

    // A new repository reads the same native key and pinned identity.
    final reopened = ApiConnectionsRepository(auth);
    try {
      expect(
        (await reopened.listConnections()).single.status,
        ConnectionStatus.unknown,
      );
      expect((await reopened.listConnections()).single.name, 'My workstation');
      expect(reopened.deviceKeyId, repository.deviceKeyId);
    } finally {
      reopened.dispose();
    }

    // Account revocation works from the mobile repository without possessing
    // the plugin credential, removes inventory, and invalidates relay access.
    final revoking = ApiConnectionsRepository(auth);
    try {
      await revoking.revokeConnection(connection.id);
      await revoking.revokeConnection(connection.id);
      expect(await revoking.listConnections(), isEmpty);
      expect(revoking.trustedKeyIds.containsKey(connection.id), isFalse);
      await expectLater(
        api.request(
          server,
          '/v1/relay/tickets',
          method: 'POST',
          accessToken: connectorCredential,
          body: {},
        ),
        throwsA(
          isA<ApiException>().having((error) => error.status, 'status', 401),
        ),
      );
    } finally {
      revoking.dispose();
    }
  } finally {
    repository.dispose();
    if (connectorCredential != null) {
      await api.request(
        server,
        '/v1/connectors/self/revoke',
        method: 'POST',
        accessToken: connectorCredential,
      );
    }
    await auth.store.delete(repository.identities.key);
  }
}

Future<void> verifyMcpDetails(
  WidgetTester tester,
  ApiConnectionsRepository repository,
  String connectorId,
  RemoteProject project,
  String sessionId,
) async {
  final before = await repository.chatRequest(connectorId, 'chat.list', {
    'projectId': project.id,
  });
  final section = find.byType(McpSection);
  final details = find.byType(ChatDetailsScreen);
  Future<void> pumpUntil(bool Function() ready, String label) async {
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    // A settled animation does not mean native crypto/relay I/O has completed.
    do {
      await tester.pump(const Duration(milliseconds: 100));
    } while (!ready() && DateTime.now().isBefore(deadline));
    expect(ready(), isTrue, reason: label);
  }

  Finder row(String name) => find.ancestor(
    of: find.descendant(of: section, matching: find.text(name)),
    matching: find.byType(Row),
  );
  bool hasStatus(String name, String status) => find
      .descendant(of: row(name), matching: find.text(status))
      .evaluate()
      .isNotEmpty;
  bool hasLiveStatus(String name, McpStatus status) {
    final model = tester.widget<McpSection>(section).model;
    return model.live &&
        model.snapshot?.servers.any(
              (server) => server.name == name && server.status == status,
            ) ==
            true;
  }

  void expectStatus(String name, McpStatus status) {
    final green = status == McpStatus.connected;
    expect(
      hasLiveStatus(name, status),
      isTrue,
      reason: 'Live MCP status: $name',
    );
    expect(row(name), findsOneWidget);
    expect(
      find.descendant(of: section, matching: find.text(name)).hitTestable(),
      findsOneWidget,
    );
    if (!green) {
      expect(
        find.descendant(of: row(name), matching: find.text(status.label)),
        findsOneWidget,
      );
    }
    final icon = tester.widget<Icon>(
      find.descendant(of: row(name), matching: find.byType(Icon)),
    );
    expect(icon.icon, green ? Icons.circle : Icons.circle_outlined);
    expect(icon.color, green ? AppTheme.success : AppTheme.muted);
  }

  Future<void> visualPause(String label) async {
    final seconds = const int.fromEnvironment(
      'MCP_VISUAL_PAUSE_SECONDS',
      defaultValue: 0,
    ).clamp(0, 60);
    if (seconds == 0) return;
    await tester.pump();
    debugPrint('MCP_VISUAL: $label ($seconds seconds)');
    await Future<void>.delayed(Duration(seconds: seconds));
    await tester.pump();
  }

  Future<void> setFixtureConnected(bool connected) async {
    final client = HttpClient();
    try {
      final request = await client
          .postUrl(
            Uri.parse(
              connected
                  ? 'http://127.0.0.1:8092/mcp/connect'
                  : 'http://127.0.0.1:8092/mcp/disconnect',
            ),
          )
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      expect(
        response.statusCode,
        200,
        reason: 'Fixed local MCP fixture control',
      );
      await response.drain<void>().timeout(const Duration(seconds: 15));
    } finally {
      client.close(force: true);
    }
  }

  // Listen to the production repository, never inject events or model state.
  McpSnapshot? initial, disconnected;
  Object? generation;
  final events = repository.chatEvents.listen((event) {
    if (initial == null ||
        event.connectorId != connectorId ||
        event.generation != generation ||
        event.operation != 'project.mcp.updated' ||
        event.requestId != initial.subscriptionId) {
      return;
    }
    final update = McpSnapshot.parse(event.body, subscription: true);
    if (update.projectId == project.id &&
        update.subscriptionId == initial.subscriptionId &&
        update.revision! > initial.revision! &&
        update.servers.any(
          (server) =>
              server.name == 'connected-fixture' &&
              server.status == McpStatus.disabled,
        )) {
      disconnected = update;
    }
  });
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: ChatFlowScreen(
          repository: repository,
          connectorId: connectorId,
          connectionName: 'My workstation',
        ),
      ),
    );
    final projectTile = find.widgetWithText(ListTile, project.path);
    await pumpUntil(
      () =>
          projectTile.evaluate().length == 1 &&
          tester.widget<ListTile>(projectTile).onTap != null,
      'Authorized project is ready',
    );
    await tester.ensureVisible(projectTile);
    await tester.tap(projectTile);
    await pumpUntil(
      () =>
          find.byType(CustomScrollView).evaluate().isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
      'Fixture chat list is ready',
    );
    final chatRow = find.byKey(ValueKey('chat-$sessionId'));
    await tester.scrollUntilVisible(
      chatRow,
      160,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 10,
    );
    final chatTile = find.descendant(
      of: chatRow,
      matching: find.byType(ListTile),
    );
    // Native pagination can still be filling the short list after its header
    // spinner disappears. Wait for the actual row to become actionable.
    await pumpUntil(
      () =>
          chatTile.evaluate().length == 1 &&
          tester.widget<ListTile>(chatTile).onTap != null,
      'Fixture chat row is enabled',
    );
    await tester.tap(chatTile);
    await pumpUntil(
      () =>
          find.byType(ConversationView).evaluate().isNotEmpty &&
          tester
                  .widget<ConversationView>(find.byType(ConversationView))
                  .model
                  .chat
                  ?.id ==
              sessionId &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
      'Fixture conversation is ready',
    );
    await tester.tap(
      find.widgetWithText(TextButton, 'Native navigation fixture'),
    );
    await pumpUntil(() => details.evaluate().isNotEmpty, 'Chat details opens');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.scrollUntilVisible(
      section,
      180,
      scrollable: find
          .descendant(of: details, matching: find.byType(Scrollable))
          .first,
      maxScrolls: 10,
    );
    await pumpUntil(
      () => tester.widget<McpSection>(section).model.live,
      'Real MCP subscription is live',
    );
    // The asynchronous snapshot grows the section after the first scroll.
    await tester.ensureVisible(section);
    await tester.pump();
    expect(
      find.descendant(of: section, matching: find.text('MCP servers')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: section, matching: find.text('Live status')),
      findsNothing,
    );
    expectStatus('connected-fixture', McpStatus.connected);
    expectStatus('disabled-fixture', McpStatus.disabled);
    expectStatus('failed-fixture', McpStatus.failed);
    await visualPause('connected');
    expectStatus('connected-fixture', McpStatus.connected);

    initial = tester.widget<McpSection>(section).model.snapshot!;
    generation = repository.chatConnectionGeneration(connectorId);
    await setFixtureConnected(false);
    await pumpUntil(
      () =>
          disconnected != null &&
          tester.widget<McpSection>(section).model.live &&
          hasStatus('connected-fixture', 'Disabled'),
      'Authenticated project.mcp.updated reaches the named MCP row',
    );
    await tester.ensureVisible(section);
    await tester.pump();
    expect(
      tester.widget<McpSection>(section).model.snapshot!.revision,
      greaterThanOrEqualTo(disconnected!.revision!),
    );
    expectStatus('connected-fixture', McpStatus.disabled);
    expectStatus('disabled-fixture', McpStatus.disabled);
    expectStatus('failed-fixture', McpStatus.failed);
    expect(
      find.descendant(of: section, matching: find.byIcon(Icons.circle)),
      findsNothing,
    );
    await visualPause('disconnected');
    expectStatus('connected-fixture', McpStatus.disabled);

    repository.setActive(false);
    await pumpUntil(
      () => hasStatus('connected-fixture', 'Last known: Disabled'),
      'Backgrounded relay retains only last-known MCP status',
    );
    expect(
      find.descendant(
        of: section,
        matching: find.text('Last-known status. Not live.'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: section, matching: find.byIcon(Icons.circle)),
      findsNothing,
    );
    await setFixtureConnected(true);
    repository.setActive(true);
    await pumpUntil(
      () => hasLiveStatus('connected-fixture', McpStatus.connected),
      'Resumed relay resubscribes to authoritative MCP status',
    );
    expect(repository.chatConnectionGeneration(connectorId), isNot(generation));
    expect(
      tester.widget<McpSection>(section).model.snapshot!.subscriptionId,
      isNot(initial.subscriptionId),
    );
    expectStatus('connected-fixture', McpStatus.connected);
    expectStatus('disabled-fixture', McpStatus.disabled);
    expectStatus('failed-fixture', McpStatus.failed);
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox());
    await events.cancel();
    repository.setActive(true);
  }
  final after = await repository.chatRequest(connectorId, 'chat.list', {
    'projectId': project.id,
  });
  expect(
    (after['chats'] as List).map((chat) => chat['id']).toSet(),
    (before['chats'] as List).map((chat) => chat['id']).toSet(),
  );
  expect(
    (after['chats'] as List).singleWhere((chat) => chat['id'] == sessionId),
    (before['chats'] as List).singleWhere((chat) => chat['id'] == sessionId),
  );
}

final class _IsolatedStore implements SecureStore {
  _IsolatedStore(this.prefix);
  final String prefix;
  final SecureStore native = const NativeSecureStore();
  @override
  Future<String?> read(String key) => native.read('integration_${prefix}_$key');
  @override
  Future<void> write(String key, String value) =>
      native.write('integration_${prefix}_$key', value);
  @override
  Future<void> delete(String key) =>
      native.delete('integration_${prefix}_$key');
}
