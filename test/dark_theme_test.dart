import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/app.dart';
import 'package:openremotecode/features/settings/data/settings_repository.dart';
import 'package:openremotecode/features/settings/settings_view_model.dart';
import 'package:openremotecode/features/workspace/ui/workspace_settings_view.dart';
import 'package:openremotecode/ui/core/app_theme.dart';
import 'package:openremotecode/ui/core/status_badge.dart';
import 'package:openremotecode/features/chat/ui/markdown_message.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'support/auth_fakes.dart';
import 'support/memory_server_settings_repository.dart';
import 'support/memory_settings_repository.dart';

class _DelayedAppearance implements SettingsRepository, AppearanceRepository {
  final read = Completer<AppAppearance>();
  final firstWrite = Completer<void>();
  final writes = <AppAppearance>[];
  @override
  Future<AppAppearance> readAppearance() => read.future;
  @override
  Future<void> writeAppearance(AppAppearance value) async {
    writes.add(value);
    if (writes.length == 1) {
      await firstWrite.future;
      throw StateError('Storage unavailable');
    }
  }

  @override
  Future<bool> readShowImages() async => true;
  @override
  Future<bool> readShowThinkingMessages() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

double _contrast(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  return l1 > l2 ? (l1 + .05) / (l2 + .05) : (l2 + .05) / (l1 + .05);
}

void main() {
  testWidgets(
    'cached Markdown updates foreground and code surfaces when theme changes',
    (tester) async {
      Widget view(ThemeData theme) => MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: MarkdownMessage(
            text: '**Important**\n\n`code`\n\n[Link](https://example.com)',
          ),
        ),
      );
      await tester.pumpWidget(view(AppTheme.light));
      final state = tester.state(find.byType(MarkdownMessage));
      expect(
        tester
            .widget<MarkdownBody>(find.byType(MarkdownBody))
            .styleSheet!
            .strong!
            .color,
        AppTheme.markdownBold,
      );
      await tester.pumpWidget(view(AppTheme.dark));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(MarkdownMessage)), same(state));
      final sheet = tester
          .widget<MarkdownBody>(find.byType(MarkdownBody))
          .styleSheet!;
      expect(sheet.strong!.color, AppTheme.darkColors.markdownBold);
      expect(sheet.code!.backgroundColor, AppTheme.darkColors.codeSurface);
      expect(sheet.a!.color, AppTheme.darkColors.info);
    },
  );

  test(
    'appearance persists independently of chat display preferences',
    () async {
      final repository = MemorySettingsRepository(images: false);
      final settings = SettingsViewModel(repository);
      await settings.load();
      expect(settings.appearance, AppAppearance.system);
      await settings.setAppearance(AppAppearance.dark);
      final restored = SettingsViewModel(repository);
      await restored.load();
      expect(restored.appearance, AppAppearance.dark);
      expect(restored.showImages, isFalse);
      expect(restored.showThinkingMessages, isTrue);
      settings.dispose();
      restored.dispose();
    },
  );

  test('late restoration cannot override a choice and failed writes remain serialized', () async {
    final repository = _DelayedAppearance();
    final settings = SettingsViewModel(repository);
    final loading = settings.load();
    final dark = settings.setAppearance(AppAppearance.dark);
    final light = settings.setAppearance(AppAppearance.light);
    repository.read.complete(AppAppearance.system);
    await loading;
    expect(settings.appearance, AppAppearance.light);
    expect(repository.writes, [AppAppearance.dark]);
    repository.firstWrite.complete();
    await Future.wait([dark, light]);
    expect(repository.writes, [AppAppearance.dark, AppAppearance.light]);
    expect(settings.appearance, AppAppearance.light);
    settings.dispose();
  });

  test('dark text and semantic accents meet normal-text contrast', () {
    const colors = AppTheme.darkColors;
    for (final foreground in [
      colors.ink,
      colors.muted,
      colors.markdownBold,
      colors.subtaskTitle,
      colors.warning,
      colors.info,
    ]) {
      for (final surface in [
        colors.background,
        colors.codeSurface,
        colors.inputSurface,
      ]) {
        expect(_contrast(foreground, surface), greaterThanOrEqualTo(4.5));
      }
    }
    for (final pair in [
      (colors.success, colors.successSurface),
      (colors.warning, colors.warningSurface),
      (colors.info, colors.infoSurface),
      (colors.muted, colors.neutralSurface),
      (AppTheme.ink, AppTheme.lime),
    ]) {
      expect(_contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
    }
    expect(AppTheme.dark.colorScheme.primary, AppTheme.lime);
    expect(AppTheme.dark.inputDecorationTheme.fillColor, colors.inputSurface);
  });

  testWidgets(
    'System follows platform brightness without recreating authentication',
    (tester) async {
      final auth = fakeAuth();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(
        MainApp(
          authRepository: auth,
          serverSettingsRepository: MemoryServerSettingsRepository(),
          settingsRepository: MemorySettingsRepository(),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.system,
      );
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.dark,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.light,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets(
    'saved Dark overrides platform Light and theme-aware badges use dark colors',
    (tester) async {
      final repository = MemorySettingsRepository()
        ..appearance = AppAppearance.dark;
      final auth = fakeAuth();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(
        MainApp(
          authRepository: auth,
          serverSettingsRepository: MemoryServerSettingsRepository(),
          settingsRepository: repository,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.dark,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: StatusBadge(
              label: 'Online',
              icon: Icons.check,
              tone: StatusTone.success,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('Online')).style!.color,
        AppTheme.darkColors.success,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets('Appearance offers accessible System, Light and Dark choices', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository = MemorySettingsRepository();
    final settings = SettingsViewModel(repository);
    final auth = fakeAuth();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: WorkspaceSettingsView(
            auth: auth,
            settings: settings,
            onDeleteAccount: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<AppAppearance>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark').last);
    await tester.pumpAndSettle();
    expect(settings.appearance, AppAppearance.dark);
    expect(repository.appearance, AppAppearance.dark);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
    auth.dispose();
  });
}
