import 'package:flutter/material.dart';

abstract final class AppTheme {
  static const lime = Color(0xFFDBF4AD);
  static const ink = Color(0xFF20251D);
  static const muted = Color(0xFF60665B);
  static const background = Color(0xFFF7F8F2);
  static const chatBackground = background;
  static const markdownBold = Color(0xFF36543C);
  static const subtaskTitle = Color(0xFF496573);
  static const codeSurface = Color(0xFFECEFE5);
  static const inputSurface = Colors.white;
  static const border = Color(0xFFDCE0D4);

  /// [border] taken most of the way to white, for edges a filled surface
  /// already defines: an input's outline, or the effort slider's track. A
  /// hairline of this reads as the surface ending, not as a drawn frame.
  static const softBorder = Color(0xFFECEEE7);
  static const selectedBorder = Color(0xFF21663A);
  static const success = Color(0xFF21663A);
  static const successSurface = Color(0xFFEAF6ED);
  static const warning = Color(0xFF805500);
  static const warningSurface = Color(0xFFFFF3D6);
  static const info = Color(0xFF285F85);
  static const infoSurface = Color(0xFFEAF2FA);
  static const neutralSurface = Color(0xFFF0F1EC);

  static final light = ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: background,
    colorScheme: ColorScheme.fromSeed(seedColor: lime).copyWith(
      primary: lime,
      onPrimary: ink,
      primaryContainer: lime,
      onPrimaryContainer: ink,
      secondary: ink,
      onSecondary: Colors.white,
      surface: background,
      onSurface: ink,
      onSurfaceVariant: muted,
      outline: muted,
      outlineVariant: border,
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 40,
        height: 1.12,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.6,
        color: ink,
      ),
      titleLarge: TextStyle(fontWeight: FontWeight.w700, color: ink),
      bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: muted),
      labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: inputSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      labelStyle: const TextStyle(color: muted),
      floatingLabelStyle: const TextStyle(color: ink),
      // A hairline, and faint: the white fill already separates an input from
      // the page, so its outline only has to hint at the edge. Focus still
      // arrives as a full-weight ink border below.
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: softBorder, width: 0.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: softBorder, width: 0.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: ink, width: 2),
      ),
      errorMaxLines: 3,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: ink,
      selectionColor: lime,
      selectionHandleColor: ink,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 56),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        disabledForegroundColor: muted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        disabledForegroundColor: muted,
        minimumSize: const Size(48, 56),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: ink,
        minimumSize: const Size(48, 48),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: ink),
  );
}
