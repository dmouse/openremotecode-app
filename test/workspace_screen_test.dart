import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/workspace/ui/workspace_screen.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

import 'support/auth_fakes.dart';
import 'support/connections_fakes.dart';

void main() {
  Future<void> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: WorkspaceScreen(
          repository: FakeConnectionsRepository(),
          auth: fakeAuth(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'phone opens left sidebar and Connections is its first destination',
    (tester) async {
      await mount(tester, const Size(390, 844));
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, AppTheme.background);
      expect(find.byKey(const ValueKey('workspace-content')), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(NavigationDrawerDestination).first,
          matching: find.text('Connections'),
        ),
        findsOneWidget,
      );
      expect(tester.getTopLeft(find.byType(NavigationDrawer)).dx, 0);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-content')), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(
        tester.state<ScaffoldState>(find.byType(Scaffold)).isDrawerOpen,
        isFalse,
      );
      expect(find.text('Server address'), findsNothing);
    },
  );

  testWidgets('wide screen keeps sidebar visible and highlights Settings', (
    tester,
  ) async {
    await mount(tester, const Size(1000, 800));
    expect(find.byTooltip('Open navigation menu'), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-content')), findsOneWidget);
    expect(
      tester
          .widget<NavigationDrawer>(find.byType(NavigationDrawer))
          .selectedIndex,
      1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar remains usable on small screens with large text', (
    tester,
  ) async {
    await mount(tester, const Size(320, 568));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-content')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
