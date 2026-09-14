import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/ui/core/app_theme.dart';

void main() {
  test('light chat palette matches the design and preserves status colors', () {
    expect(AppTheme.chatBackground, const Color(0xFFF7F8F2));
    expect(AppTheme.markdownBold, const Color(0xFF36543C));
    expect(AppTheme.subtaskTitle, const Color(0xFF496573));
    expect(AppTheme.codeSurface, const Color(0xFFECEFE5));
    expect(AppTheme.inputSurface, Colors.white);
    expect(AppTheme.success, const Color(0xFF21663A));
    expect(AppTheme.warning, const Color(0xFF805500));
    expect(AppTheme.lime, const Color(0xFFDBF4AD));
  });

  test('normal chat text meets 4.5:1 contrast on its actual surface', () {
    for (final (foreground, background) in [
      for (final color in [
        AppTheme.ink,
        AppTheme.markdownBold,
        AppTheme.muted,
        AppTheme.warning,
        AppTheme.subtaskTitle,
        AppTheme.success,
      ])
        (color, AppTheme.chatBackground),
      (AppTheme.ink, AppTheme.codeSurface),
      // The prompt bubble's Plan mark.
      (AppTheme.muted, AppTheme.codeSurface),
      (AppTheme.ink, AppTheme.inputSurface),
      (AppTheme.muted, AppTheme.inputSurface),
      (AppTheme.ink, AppTheme.lime),
    ]) {
      final contrast =
          (background.computeLuminance() + 0.05) /
          (foreground.computeLuminance() + 0.05);
      expect(
        contrast,
        greaterThanOrEqualTo(4.5),
        reason: '$foreground on $background',
      );
    }
  });
}
