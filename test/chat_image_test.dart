import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/chat_view_model.dart';
import 'package:openremotecode/features/chat/data/chat_image_preferences.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/conversation_view.dart';
import 'package:openremotecode/features/chat/ui/image_message.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

final _fixture = jsonDecode(
  File('../packages/protocol/test/fixtures/chat-image-v1.json')
      .readAsStringSync(),
) as Map<String, dynamic>;
Map<String, dynamic> get _shotMessage =>
    (_fixture['response']['messages'] as List).single as Map<String, dynamic>;
Map<String, dynamic> get _userMessage =>
    _fixture['userResponse'] as Map<String, dynamic>;

void main() {
  test('an assistant screenshot and a user photo parse under the relaxed user-parts invariant', () {
    final shot = ChatMessage.parse(_shotMessage);
    expect(shot.role, 'assistant');
    expect(shot.text, '');
    expect(shot.truncated, false);
    expect(shot.parts!.single.image!.mime, 'image/jpeg');
    expect(shot.parts!.single.text, '');

    final photo = ChatMessage.parse(_userMessage);
    expect(photo.role, 'user');
    expect(photo.parts!.map((p) => p.type).toList(), ['text', 'image', 'text']);
    expect(photo.text, "Here's a screenshot\n[File: notes.txt]\n");
    expect(photo.parts![1].image!.width, 1);
    expect(photo.parts![1].image!.height, 1);
  });

  test('image fields are strict, bounded and always image/jpeg', () {
    final image =
        (_shotMessage['parts'] as List).single as Map<String, dynamic>;
    final source = image['image'] as Map<String, dynamic>;
    for (final invalid in <Map<String, dynamic>>[
      {...source, 'mime': 'image/png'},
      {...source, 'data': ''},
      {...source, 'data': 'not base64!!'},
      {...source, 'data': 'A' * 34001},
      {...source, 'width': 0},
      {...source, 'height': -1},
      {...source, 'width': 8193},
      {...source, 'extra': 'unexpected'},
    ]) {
      expect(
        () => ChatImage.parse(invalid),
        throwsFormatException,
        reason: invalid.toString(),
      );
    }
    ChatImage.parse(source);
  });

  test('a user message may carry text/image parts but never a tool/subtask/reasoning part', () {
    final withTool =
        jsonDecode(jsonEncode(_userMessage)) as Map<String, dynamic>;
    (withTool['parts'] as List).add({
      'id': 'sneaky',
      'type': 'tool',
      'text': '',
      'tool': {'operation': 'tool', 'status': 'unknown'},
    });
    expect(() => ChatMessage.parse(withTool), throwsFormatException);
  });

  test('image data counts toward the shared 48,000-unit message budget', () {
    final source = jsonDecode(jsonEncode(_shotMessage)) as Map<String, dynamic>;
    final part = (source['parts'] as List).single as Map<String, dynamic>;
    final imageMap = part['image'] as Map<String, dynamic>;
    final imageLength = (imageMap['data'] as String).length;
    final budget = 48000 - imageLength;
    source['parts'] = [
      (source['parts'] as List).single,
      {'id': 'extra', 'type': 'text', 'text': 't' * (budget + 1)},
    ];
    source['text'] = 't' * (budget + 1);
    expect(() => ChatMessage.parse(source), throwsFormatException);
    (source['parts'] as List)[1] = {
      'id': 'extra',
      'type': 'text',
      'text': 't' * budget,
    };
    source['text'] = 't' * budget;
    ChatMessage.parse(source); // exactly at budget: does not throw
  });

  testWidgets(
    'ImageMessage renders the decoded preview and opens a pinch-to-zoom viewer on tap',
    (tester) async {
      final image = ChatMessage.parse(_shotMessage).parts!.single.image!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ImageMessage(image: image)),
        ),
      );
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
      await tester.tap(find.byType(ImageMessage));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ImageMessage fails closed to nothing rather than throwing on undecodable data',
    (tester) async {
      const image = ChatImage('image/jpeg', 'not-valid-base64!!');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ImageMessage(image: image)),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ConversationView renders image bubbles for both an assistant screenshot and a user photo',
    (tester) async {
      final model = ChatViewModel(_Repository(), 'connector')
        ..conversation.messages = [
          ChatMessage.parse(_userMessage),
          ChatMessage.parse(_shotMessage),
        ];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: ConversationView(model: model.conversation)),
        ),
      );
      expect(find.byType(ImageMessage), findsNWidgets(2));
      expect(find.textContaining("Here's a screenshot"), findsOneWidget);
      expect(find.textContaining('[File: notes.txt]'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  test('includeImages is requested only with both the negotiated capability and the on-device preference', () async {
    final prefs = _Preferences(true);
    final repo = _Repository();
    final model = ChatViewModel(repo, 'connector', imagePreferences: prefs);
    await model.refresh();
    await model.openProject(model.projects.projects.single);
    await model.openChat(model.chatList.chats.single);
    expect(repo.requests.last.containsKey('includeImages'), isFalse);

    repo.images = true;
    await model.refresh();
    expect(repo.requests.last['includeImages'], isTrue);

    // Flip the on-device preference off: the capability alone is not enough.
    await model.conversation.setShowImages(false);
    expect(model.conversation.showImages, isFalse);
    expect(prefs.value, isFalse);
    expect(repo.requests.last.containsKey('includeImages'), isFalse);

    await model.conversation.setShowImages(true);
    expect(repo.requests.last['includeImages'], isTrue);
    model.dispose();
  });

  test(
    'a stored preference is loaded before the first snapshot request',
    () async {
      final prefs = _Preferences(false);
      final repo = _Repository()..images = true;
      final model = ChatViewModel(repo, 'connector', imagePreferences: prefs);
      await Future<void>.delayed(Duration.zero); // let the async load settle
      expect(model.conversation.showImages, isFalse);
      await model.refresh();
      await model.openProject(model.projects.projects.single);
      await model.openChat(model.chatList.chats.single);
      expect(repo.requests.last.containsKey('includeImages'), isFalse);
      model.dispose();
    },
  );
}

class _Preferences implements ChatImagePreferences {
  _Preferences(this.value);
  bool value;
  int writes = 0;
  @override
  Future<bool> readShowImages() async => value;
  @override
  Future<void> writeShowImages(bool next) async {
    value = next;
    writes++;
  }
}

class _Repository implements ChatRepository {
  bool images = false;
  final requests = <Map<String, dynamic>>[];
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
      operation == 'chat.images' && images;
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
    requests.add(body);
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
      'chat.snapshot' => Map<String, dynamic>.from(_fixture['response']),
      _ => throw UnimplementedError(),
    };
  }
}
