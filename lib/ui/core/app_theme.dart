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

  static const darkColors = AppColors(
    ink: Color(0xFFE7ECE1),
    muted: Color(0xFFB4BDAE),
    background: Color(0xFF161B15),
    markdownBold: Color(0xFFB5D6B4),
    subtaskTitle: Color(0xFFACC8D5),
    codeSurface: Color(0xFF252D22),
    inputSurface: Color(0xFF222920),
    border: Color(0xFF46503F),
    softBorder: Color(0xFF333D2F),
    selectedBorder: Color(0xFF99D5A5),
    success: Color(0xFF99D5A5),
    successSurface: Color(0xFF223B29),
    warning: Color(0xFFF0C46E),
    warningSurface: Color(0xFF3B301B),
    info: Color(0xFFA7CDED),
    infoSurface: Color(0xFF223444),
    neutralSurface: Color(0xFF2A3227),
  );

  static AppColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? darkColors
      : const AppColors();

  static final dark = _build(Brightness.dark, darkColors);
  static final light = _build(Brightness.light, const AppColors());

  static ThemeData _build(Brightness brightness, AppColors colors) => ThemeData(
    brightness: brightness,
    useMaterial3: true,
    scaffoldBackgroundColor: colors.background,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.background,
      foregroundColor: colors.ink,
      surfaceTintColor: Colors.transparent,
    ),
    colorScheme: ColorScheme.fromSeed(seedColor: lime, brightness: brightness)
        .copyWith(
          primary: lime,
          onPrimary: ink,
          primaryContainer: lime,
          onPrimaryContainer: ink,
          secondary: colors.ink,
          onSecondary: brightness == Brightness.dark
              ? colors.background
              : Colors.white,
          surface: colors.background,
          onSurface: colors.ink,
          onSurfaceVariant: colors.muted,
          outline: colors.muted,
          outlineVariant: colors.border,
        ),
    textTheme: TextTheme(
      headlineLarge: TextStyle(
        fontSize: 40,
        height: 1.12,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.6,
        color: colors.ink,
      ),
      titleLarge: TextStyle(fontWeight: FontWeight.w700, color: colors.ink),
      bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: colors.ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: colors.muted),
      labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.inputSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      labelStyle: TextStyle(color: colors.muted),
      floatingLabelStyle: TextStyle(color: colors.ink),
      // A hairline, and faint: the white fill already separates an input from
      // the page, so its outline only has to hint at the edge. Focus still
      // arrives as a full-weight ink border below.
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.softBorder, width: 0.5),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.softBorder, width: 0.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.ink, width: 2),
      ),
      errorMaxLines: 3,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: colors.ink,
      selectionColor: brightness == Brightness.dark
          ? const Color(0xFF40532E)
          : lime,
      selectionHandleColor: colors.ink,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 56),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        disabledForegroundColor: colors.muted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.ink,
        disabledForegroundColor: colors.muted,
        minimumSize: const Size(48, 56),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: colors.ink,
        minimumSize: const Size(48, 48),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: colors.ink),
  );
}

/// Immutable semantic colors. Fixed lime/ink brand treatments deliberately keep
/// AppTheme.lime/AppTheme.ink; reading surfaces resolve through AppTheme.of.
final class AppColors {
  const AppColors({
    this.ink = AppTheme.ink,
    this.muted = AppTheme.muted,
    this.background = AppTheme.background,
    this.markdownBold = AppTheme.markdownBold,
    this.subtaskTitle = AppTheme.subtaskTitle,
    this.codeSurface = AppTheme.codeSurface,
    this.inputSurface = AppTheme.inputSurface,
    this.border = AppTheme.border,
    this.softBorder = AppTheme.softBorder,
    this.selectedBorder = AppTheme.selectedBorder,
    this.success = AppTheme.success,
    this.successSurface = AppTheme.successSurface,
    this.warning = AppTheme.warning,
    this.warningSurface = AppTheme.warningSurface,
    this.info = AppTheme.info,
    this.infoSurface = AppTheme.infoSurface,
    this.neutralSurface = AppTheme.neutralSurface,
  });
  final Color ink,
      muted,
      background,
      markdownBold,
      subtaskTitle,
      codeSurface,
      inputSurface,
      border,
      softBorder,
      selectedBorder,
      success,
      successSurface,
      warning,
      warningSurface,
      info,
      infoSurface,
      neutralSurface;
  Color get chatBackground => background;
}
