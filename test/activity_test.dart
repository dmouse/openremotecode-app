import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/domain/activity.dart';
import 'package:openremotecode/features/chat/domain/activity.generated.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';
import 'package:openremotecode/features/chat/ui/activity_animation.dart';
import 'package:openremotecode/features/chat/ui/activity_presentation.dart';
import 'package:openremotecode/features/chat/ui/activity_row.dart';
import 'package:openremotecode/features/chat/ui/tool_view.dart';
import 'package:openremotecode/features/chat/ui/thought_view.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

void main() {
  test(
    'language-neutral activity fixture parses without host-specific names',
    () {
      final fixture = jsonDecode(
        File('../packages/protocol/test/fixtures/activity-v1.json')
            .readAsStringSync(),
      );
      expect(
        (fixture['activities'] as List).map((a) => AgentActivity.parse(a).kind),
        activityKinds,
      );
      expect(
        ChatMessage.parse(fixture['stream']['snapshot']['messages'][0])
            .parts!
            .single
            .activity!
            .running,
        isTrue,
      );
      for (final value in [
        {'kind': 'bash', 'state': 'running'},
        {'kind': 'read', 'state': 'success'},
        {'kind': 'read', 'state': 'completed', 'output': 'private'},
      ]) {
        expect(() => AgentActivity.parse(value), throwsFormatException);
      }
    },
  );

  testWidgets(
    'shell description and task actions share typography and icon geometry',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ListView(
              children: [
                ToolView(
                  tool: const ChatTool(
                    operation: 'execute',
                    status: 'completed',
                    description: 'Check formatting',
                    shell: ChatShell(
                      command: 'hidden command',
                      output: 'hidden output',
                      truncated: false,
                    ),
                  ),
                  online: true,
                  active: false,
                  onToggle: () {},
                ),
                for (final kind in [
                  'read',
                  'search',
                  'apply_patch',
                  'update_tasks',
                ])
                  ToolView(
                    tool: ChatTool(
                      operation: 'tool',
                      status: 'completed',
                      description: ActivityPresentation.forKind(kind).$1,
                    ),
                    activity: AgentActivity(kind, 'completed'),
                    online: true,
                    active: false,
                  ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('hidden command'), findsNothing);
      expect(find.text('hidden output'), findsNothing);
      expect(find.textContaining('Check formatting'), findsOneWidget);
      for (final label in [
        'Check formatting · Completed',
        'Read',
        'Search',
        'Apply patch',
        'Update task list',
      ]) {
        final text = tester.widget<Text>(find.text(label));
        expect(text.style!.fontSize, 12);
        expect(
          text.style!.fontFamily,
          AppTheme.light.textTheme.bodyMedium!.fontFamily,
        );
      }
      for (final icon in [
        Icons.terminal,
        Icons.arrow_forward,
        Icons.search,
        Icons.edit_note,
        Icons.checklist,
      ]) {
        expect(tester.widget<Icon>(find.byIcon(icon)).size, 12);
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'shell rows match thought spacing and first-line icon alignment at scale $scale',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ThoughtView(
                      key: ValueKey('thought'),
                      part: ChatMessagePart('r', 'reasoning', 'Check'),
                      active: false,
                    ),
                    ToolView(
                      key: const ValueKey('shell'),
                      tool: const ChatTool(
                        operation: 'execute',
                        status: 'completed',
                        description: 'Run',
                        shell: ChatShell(
                          command: 'hidden',
                          output: '',
                          truncated: false,
                        ),
                      ),
                      active: false,
                      online: true,
                      onToggle: () {},
                    ),
                    const ThoughtView(
                      key: ValueKey('after'),
                      part: ChatMessagePart('r2', 'reasoning', 'Check'),
                      active: false,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final thought = find.byKey(const ValueKey('thought'));
        final shell = find.byKey(const ValueKey('shell'));
        final thoughtText = find.descendant(
          of: thought,
          matching: find.byType(Text),
        );
        final shellText = find.text('Run · Completed');
        expect(
          tester.getSize(shell).height,
          closeTo(tester.getSize(thought).height, 0.01),
        );
        expect(
          tester.getTopLeft(shellText).dy - tester.getTopLeft(shell).dy,
          4,
        );
        expect(
          tester.getTopLeft(thoughtText).dy - tester.getTopLeft(thought).dy,
          4,
        );
        expect(
          tester.getTopLeft(shellText).dx,
          tester.getTopLeft(thoughtText).dx,
        );
        expect(tester.getTopLeft(shell).dy, tester.getBottomLeft(thought).dy);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('after'))).dy,
          tester.getBottomLeft(shell).dy,
        );
        for (final (row, text, icon) in [
          (thought, thoughtText, Icons.psychology_outlined),
          (shell, shellText, Icons.terminal),
        ]) {
          final glyph = find.descendant(of: row, matching: find.byIcon(icon));
          expect(tester.getSize(glyph), Size(12 * scale, 12 * scale));
          expect(
            tester.getCenter(glyph).dy,
            closeTo(tester.getTopLeft(text).dy + 12 * scale * 1.35 / 2, 0.01),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'one visible animation clock never rebuilds text and stops offscreen, reduced-motion and background',
    (tester) async {
      final scroll = ScrollController();
      var builds = 0;
      Future<void> show({
        bool running = true,
        bool enabled = true,
        bool reduced = false,
      }) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: ActivityAnimations(
                enabled: enabled,
                child: ListView(
                  controller: scroll,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(10000),
                  children: [
                    for (var i = 0; i < 3; i++)
                      ActivityRow(
                        icon: Icons.search,
                        color: Colors.black,
                        running: running,
                        title: Builder(
                          builder: (_) {
                            builds++;
                            return Text('Activity $i');
                          },
                        ),
                      ),
                    const SizedBox(height: 4000),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await show();
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 1);
      final baseline = builds;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(builds, baseline);
      scroll.jumpTo(3000);
      await tester.pump();
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      scroll.jumpTo(0);
      await tester.pump();
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 1);
      await show(reduced: true);
      await tester.pump();
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      await show();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump();
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      await show(running: false);
      await tester.pump();
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byIcon(Icons.search), findsNWidgets(3));
      await show(enabled: false);
      await tester.pump();
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );
}
