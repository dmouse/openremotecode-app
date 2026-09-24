// Renders the design previews under docs/previews from synthetic sample data.
//
//   flutter test tool/render_previews_test.dart
//
// It lives in tool/ rather than test/ so `flutter test` never rewrites
// documentation. Set PREVIEW_DIR to write somewhere other than docs/previews.
// Everything shown is invented: no real account, connector, or conversation
// content is used.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/app.dart';
import 'package:openremotecode/features/chat/data/chat_repository.dart';
import 'package:openremotecode/features/chat/ui/chat_flow_screen.dart';
import 'package:openremotecode/features/server_settings/domain/server_endpoint.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

import '../test/support/auth_fakes.dart';
import '../test/support/connections_fakes.dart';
import '../test/support/memory_server_settings_repository.dart';

final _shot = GlobalKey();
final _out = Platform.environment['PREVIEW_DIR'] ?? 'docs/previews';
const _server = 'http://127.0.0.1:8080';

/// Flutter's test engine has no Roboto unless it is registered, and would
/// otherwise render every glyph in a fallback face.
Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<void> register(
    String family,
    List<String> files, [
    String? from,
  ]) async {
    final loader = FontLoader(family);
    for (final file in files) {
      final source = File('${from ?? dir}/$file');
      if (source.existsSync()) {
        loader.addFont(
          Future.value(ByteData.sublistView(source.readAsBytesSync())),
        );
      }
    }
    await loader.load();
  }

  await register('Roboto', [
    for (final w in ['Light', 'Regular', 'Medium', 'Bold', 'Black'])
      'Roboto-$w.ttf',
    for (final w in ['Italic', 'MediumItalic', 'BoldItalic']) 'Roboto-$w.ttf',
  ]);
  await register('MaterialIcons', ['MaterialIcons-Regular.otf']);
  // The app asks for the generic 'monospace' family, which the test engine
  // cannot resolve on its own and draws as solid boxes.
  await register('monospace', [
    for (final w in ['Regular', 'Bold', 'Italic', 'BoldItalic'])
      'LiberationMono-$w.ttf',
  ], '/usr/share/fonts/liberation-mono-fonts');
}

/// [logical] is the phone's size in logical pixels; [ratio] the scale written
/// to disk.
Future<void> _size(WidgetTester tester, Size logical, double ratio) async {
  tester.view.physicalSize = logical;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _ratio = ratio;
}

double _ratio = 2;

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  final boundary =
      _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _ratio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(_out).createSync(recursive: true);
    File('$_out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required FakeConnectionsRepository connections,
  bool signedIn = false,
}) async {
  final auth = fakeAuth();
  addTearDown(auth.dispose);
  if (signedIn) {
    await auth.login(
      ServerEndpoint.parse('https://remote.example.test'),
      'person@example.com',
      'password',
    );
  }
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shot,
      child: MainApp(
        authRepository: auth,
        serverSettingsRepository: MemoryServerSettingsRepository(
          value: _server,
        ),
        connectionsRepositoryFactory: (_) => connections,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester, String label, String value) =>
    tester.enterText(find.widgetWithText(TextFormField, label), value);

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

// ---- synthetic chat data ---------------------------------------------------

const _projectId = 'proj_sample';
const _taskLabel = 'Explore Task — Inspect mobile color palette';

int _ago(Duration d) => DateTime.now().subtract(d).millisecondsSinceEpoch;

Map<String, dynamic> _summary(String id, String title, Duration ago) => {
  'id': id,
  'title': title,
  'updatedAt': _ago(ago),
};

final _parent = _summary('ses_parent', 'Review mobile chat', Duration.zero);

Map<String, dynamic> _snapshot({required bool withTask}) => {
  'version': 1,
  'chat': _parent,
  'cursor': null,
  'status': 'idle',
  'messages': [
    {
      'id': 'msg_user',
      'role': 'user',
      'truncated': false,
      'text': 'Check the emulator pairing and update the connection status.',
    },
    {
      'id': 'msg_assistant',
      'role': 'assistant',
      'truncated': false,
      'text': _text(withTask),
      'parts': _parts(withTask),
    },
  ],
};

/// The wire contract requires `text` to be exactly the text and task parts in
/// order, with reasoning left out.
String _text(bool withTask) =>
    _parts(withTask)
        .where((p) => p['type'] == 'text' || p['type'] == 'subtask')
        .map((p) => p['text'] as String)
        .join();

List<Map<String, dynamic>> _parts(bool withTask) => [
  {
    'id': 'p0',
    'type': 'text',
    'text': 'I’ll verify the connection, then check the saved pairing.\n',
  },
  {
    'id': 'p1',
    'type': 'reasoning',
    'text': '**Checking emulator pairing**\n\nConfirm the saved pairing.',
    'time': {'start': 1000, 'end': 9000},
  },
  {
    'id': 'p2',
    'type': 'reasoning',
    'text': '**Updating pairing status**\n\nRefresh the connection row.',
    'time': {'start': 9000, 'end': 9471},
  },
  if (withTask)
    {
      'id': 'p3',
      'type': 'subtask',
      'text': '[Tool: task · completed]\n',
      'task': {
        'title': 'Inspect mobile color palette',
        'agent': 'explore',
        'status': 'completed',
        'background': false,
        'sessionId': 'ses_child',
        'stats': {'toolCalls': 15, 'complete': true, 'durationMs': 82000},
      },
    },
  {
    'id': 'p4',
    'type': 'text',
    'text':
        '**Sign-in is restored.** The device is paired and ready.\n\n'
        '- Connection verified\n- Pairing status updated\n\n'
        'You can continue the conversation from your phone.\n',
  },
];

final class _SampleChats implements ChatRepository {
  _SampleChats({this.withTask = false});
  final bool withTask;
  final changes = StreamController<void>.broadcast();

  @override
  bool chatOnline(String id) => true;
  @override
  bool chatTrusted(String id) => true;
  @override
  bool chatSupports(String id, String operation) =>
      !operation.startsWith('project.mcp.') &&
      !operation.startsWith('chat.stream.') &&
      operation != 'chat.activities' &&
      operation != 'chat.images' &&
      operation != 'chat.permissions' &&
      operation != 'chat.permission.reply' &&
      operation != 'chat.questions' &&
      operation != 'chat.question.reply';
  @override
  Stream<void> get chatConnectionChanges => changes.stream;
  @override
  Stream<ChatEvent> get chatEvents => const Stream.empty();
  @override
  Object chatConnectionGeneration(String connectorId) => 0;
  @override
  Future<Set<String>> pinnedChatIds(String id, String path) async => {
    'ses_pinned',
  };
  @override
  Future<Set<String>> setChatPinned(
    String id,
    String path,
    String session,
    bool pinned,
  ) async => {'ses_pinned'};

  @override
  Future<Map<String, dynamic>> chatRequest(
    String id,
    String operation,
    Map<String, dynamic> body,
  ) async {
    switch (operation) {
      case 'project.list':
        return {
          'version': 1,
          'projects': [
            {
              'id': _projectId,
              'name': 'opencode-remote',
              'path': '/workspace/opencode-remote',
            },
            {
              'id': 'proj_docs',
              'name': 'docs-site',
              'path': '/workspace/docs-site',
            },
          ],
          'pathEntry': false,
        };
      case 'chat.list':
        return {
          'version': 1,
          'chats': [
            _parent,
            _summary(
              'ses_pinned',
              'Remote connection plan',
              const Duration(days: 28),
            ),
            _summary(
              'ses_2',
              'Review project instructions',
              const Duration(minutes: 29),
            ),
            _summary(
              'ses_3',
              'Plugin unavailable in opencode serve',
              const Duration(hours: 1, minutes: 5),
            ),
            _summary(
              'ses_4',
              'Improve the pairing experience',
              const Duration(days: 1, hours: 2),
            ),
            _summary(
              'ses_5',
              'Handle reconnects on mobile',
              const Duration(days: 1, hours: 5),
            ),
            _summary('ses_6', 'Secure remote access', const Duration(days: 4)),
          ],
          'cursor': null,
        };
      case 'chat.snapshot':
        return _snapshot(withTask: withTask);
      case 'chat.subtask.snapshot':
        return {
          'version': 1,
          'chat': {
            'id': 'ses_child',
            'parentId': 'ses_parent',
            'title': 'Inspect mobile color palette',
            'updatedAt': _ago(const Duration(minutes: 2)),
          },
          'cursor': null,
          'status': 'idle',
          'messages': [
            {
              'id': 'child_user',
              'role': 'user',
              'truncated': false,
              'text': 'Inspect the mobile color palette for contrast issues.',
            },
            {
              'id': 'child_message',
              'role': 'assistant',
              'truncated': false,
              'text':
                  '**Palette findings.** Brand green `#DBF4AD` is only used '
                  'behind dark text; no pale-on-white text was found.',
            },
          ],
        };
      default:
        throw StateError('Unexpected request: $operation');
    }
  }
}

Future<void> _pumpChat(WidgetTester tester, _SampleChats repo) async {
  addTearDown(repo.changes.close);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _shot,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: ChatFlowScreen(
          repository: repo,
          connectorId: 'sample',
          connectionName: 'Workstation',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openConversation(WidgetTester tester) async {
  await tester.tap(find.text('opencode-remote'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Review mobile chat'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('signed-out screens', (tester) async {
    await _size(tester, const Size(390, 844), 2);
    await _pumpApp(tester, connections: FakeConnectionsRepository());
    await _capture(tester, 'login');

    // Server selection is hidden behind six taps on the header.
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.text('Remote'));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    await _capture(tester, 'server-settings');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await _tap(tester, find.text("Don't have an account? Create one"));
    await _capture(tester, 'registration');
    await _fill(tester, 'Email address', 'person@example.com');
    await _fill(tester, 'Password', 'a long enough password');
    await _fill(tester, 'Confirm password', 'a long enough password');
    await _tap(tester, find.text('Create account'));
    await _capture(tester, 'verify-email');
  });

  testWidgets('connections, pairing and settings', (tester) async {
    await _size(tester, const Size(390, 844), 2);
    final repo = FakeConnectionsRepository();
    await _pumpApp(tester, connections: repo, signedIn: true);
    await _capture(tester, 'workspace');

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await _capture(tester, 'workspace-sidebar');
    await tester.tapAt(const Offset(370, 400));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Enter pairing code'));
    await tester.pumpAndSettle();
    await _capture(tester, 'pairing-code');
    await tester.enterText(find.byType(TextFormField), 'abcd-efgh');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await _capture(tester, 'pairing-safety');
    await tester.tap(find.text('Codes match — confirm'));
    await tester.pumpAndSettle();
    await _capture(tester, 'connections');

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await _capture(tester, 'settings');
  });

  testWidgets('projects and chat list', (tester) async {
    await _size(tester, const Size(390, 844), 2);
    await _pumpChat(tester, _SampleChats());
    await _capture(tester, 'projects');
    await tester.tap(find.text('opencode-remote'));
    await tester.pumpAndSettle();
    await _capture(tester, 'chats');
  });

  testWidgets('conversation with thoughts', (tester) async {
    await _size(tester, const Size(420, 860), 1);
    await _pumpChat(tester, _SampleChats());
    await _openConversation(tester);
    await _capture(tester, 'chat-thoughts');
  });

  testWidgets('conversation with a sub-agent task', (tester) async {
    await _size(tester, const Size(420, 860), 1);
    await _pumpChat(tester, _SampleChats(withTask: true));
    await _openConversation(tester);
    expect(find.text(_taskLabel), findsOneWidget);
    await _capture(tester, 'chat-subtasks');
    await tester.tap(find.text(_taskLabel));
    await tester.pumpAndSettle();
    await _capture(tester, 'subtask-chat');
  });
}
