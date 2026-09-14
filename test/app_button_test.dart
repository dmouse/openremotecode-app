import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/ui/core/app_button.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

void main() {
  testWidgets('outlined sign-out label and icon are readable on white', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          backgroundColor: Colors.white,
          body: Center(
            child: AppButton.secondary(
              label: 'Sign out',
              icon: Icons.logout,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );

    final labelColor = DefaultTextStyle.of(
      tester.element(find.text('Sign out')),
    ).style.color!;
    final iconColor = IconTheme.of(tester.element(find.byIcon(Icons.logout)))
        .color!;
    double contrastOnWhite(Color color) =>
        1.05 / (color.computeLuminance() + 0.05);
    expect(contrastOnWhite(labelColor), greaterThanOrEqualTo(4.5));
    expect(contrastOnWhite(iconColor), greaterThanOrEqualTo(3));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });

  for (final outlined in [false, true]) {
    testWidgets('loading blocks activation and labels progress ($outlined)', (
      tester,
    ) async {
      var activations = 0;
      final semantics = tester.ensureSemantics();
      Future<void> mount({required bool loading, bool enabled = true}) =>
          tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.light,
              home: Scaffold(
                body: Center(
                  child: outlined
                      ? AppButton.secondary(
                          label: 'Continue',
                          loadingLabel: 'Working',
                          isLoading: loading,
                          onPressed: enabled ? () => activations++ : null,
                        )
                      : AppButton.primary(
                          label: 'Continue',
                          loadingLabel: 'Working',
                          isLoading: loading,
                          onPressed: enabled ? () => activations++ : null,
                        ),
                ),
              ),
            ),
          );

      await mount(loading: true);
      expect(find.bySemanticsLabel('Working'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('Working'));
      expect(activations, 0);
      await mount(loading: false, enabled: false);
      await tester.tap(find.text('Continue'));
      expect(activations, 0);
      await mount(loading: false);
      await tester.tap(find.text('Continue'));
      expect(activations, 1);
      semantics.dispose();
    });

    testWidgets('long labels wrap with large text ($outlined)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Center(
                child: SizedBox(
                  width: 240,
                  child: outlined
                      ? AppButton.secondary(
                          label: 'Codes match — confirm',
                          icon: Icons.check,
                          onPressed: () {},
                        )
                      : AppButton.primary(
                          label: 'Codes match — confirm',
                          icon: Icons.check,
                          iconAlignment: IconAlignment.end,
                          onPressed: () {},
                        ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.text('Codes match — confirm')).height,
        greaterThan(56),
      );
    });
  }
}
