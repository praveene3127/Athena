import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _key = 'athena_app_theme_mode';

  @override
  ThemeMode build() {
    _loadFromPrefs();
    return ThemeMode.light;
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved == 'dark') {
      state = ThemeMode.dark;
    } else if (saved == 'light') {
      state = ThemeMode.light;
    } else if (saved == 'system') {
      state = ThemeMode.system;
    }
  }

  Future<void> toggleTheme() async {
    final next = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, next == ThemeMode.dark ? 'dark' : 'light');
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    final str = mode == ThemeMode.dark
        ? 'dark'
        : (mode == ThemeMode.light ? 'light' : 'system');
    await prefs.setString(_key, str);
  }
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class AppTheme {
  // Stripe Press / Tufte Editorial Architecture:
  // Light Palette Tokens
  static const Color background = Color(0xFFFBF9F5);
  static const Color surface = Color(0xFFF2EFE9);
  static const Color surfaceWarm = Color(0xFFFAF7F2);
  static const Color surfaceMuted = Color(0xFFEBE7DF);
  static const Color border = Color(0xFFE2DDD5);
  static const Color hairline = Color(0xFFECE7DE);
  static const Color ink = Color(0xFF161615);
  static const Color figmaBlack = Color(0xFF161615);
  static const Color figmaGreen = Color(0xFF2D6A4F);
  static const Color lime = Color(0xFF2D6A4F);
  static const Color textPrimary = Color(0xFF161615);
  static const Color textBody = Color(0xFF282827);
  static const Color textMuted = Color(0xFF6E6E6B);
  static const Color paper = Color(0xFFFBF9F5);
  static const Color paperText = Color(0xFF161615);
  static const Color cyan = Color(0xFF2D6A4F);

  // Dark Palette Tokens
  static const Color darkBackground = Color(0xFF101010);
  static const Color darkSurface = Color(0xFF181818);
  static const Color darkSurfaceWarm = Color(0xFF202020);
  static const Color darkSurfaceMuted = Color(0xFF242424);
  static const Color darkBorder = Color(0xFF282828);
  static const Color darkHairline = Color(0xFF222222);
  static const Color darkInk = Color(0xFFF3F3F3);
  static const Color darkTextPrimary = Color(0xFFF3F3F3);
  static const Color darkTextBody = Color(0xFFDDDDDD);
  static const Color darkTextMuted = Color(0xFF9E9E9E);

  // Dynamic context-aware helpers
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color bgOf(BuildContext context) =>
      isDark(context) ? darkBackground : background;

  static Color surfaceOf(BuildContext context) =>
      isDark(context) ? darkSurface : surface;

  static Color surfaceWarmOf(BuildContext context) =>
      isDark(context) ? darkSurfaceWarm : surfaceWarm;

  static Color surfaceMutedOf(BuildContext context) =>
      isDark(context) ? darkSurfaceMuted : surfaceMuted;

  static Color borderOf(BuildContext context) =>
      isDark(context) ? darkBorder : border;

  static Color hairlineOf(BuildContext context) =>
      isDark(context) ? darkHairline : hairline;

  static Color inkOf(BuildContext context) =>
      isDark(context) ? darkInk : ink;

  static Color textPrimaryOf(BuildContext context) =>
      isDark(context) ? darkTextPrimary : textPrimary;

  static Color textBodyOf(BuildContext context) =>
      isDark(context) ? darkTextBody : textBody;

  static Color textMutedOf(BuildContext context) =>
      isDark(context) ? darkTextMuted : textMuted;

  // Typography tokens per Brand Guide v3
  static const String fontDisplay = 'DM Serif Display';
  static const String fontReading = 'Newsreader';
  static const String fontUI = 'Geist';

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: fontUI,
      scaffoldBackgroundColor: background,
      primaryColor: ink,
      colorScheme: const ColorScheme.light(
        primary: ink,
        secondary: Color(0xFF333333),
        surface: surface,
        error: Colors.redAccent,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          fontFamily: fontDisplay,
          color: textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: border, width: 1),
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: ink,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          minimumSize: const Size(88, 48),
          textStyle: const TextStyle(
            fontFamily: fontUI,
            fontWeight: FontWeight.w600,
            fontSize: 14,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: const BorderSide(color: border, width: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          minimumSize: const Size(88, 48),
          textStyle: const TextStyle(
            fontFamily: fontUI,
            fontWeight: FontWeight.w500,
            fontSize: 14,
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: ink,
        contentTextStyle: TextStyle(
          fontFamily: fontUI,
          color: Colors.white,
          fontSize: 13,
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: fontUI,
      scaffoldBackgroundColor: darkBackground,
      primaryColor: darkInk,
      colorScheme: const ColorScheme.dark(
        primary: darkInk,
        secondary: Color(0xFFCCCCCC),
        surface: darkSurface,
        error: Colors.redAccent,
        onPrimary: Colors.black,
        onSecondary: Colors.black,
        onSurface: darkTextPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: darkBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: darkTextPrimary),
        titleTextStyle: TextStyle(
          fontFamily: fontDisplay,
          color: darkTextPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: darkSurface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: darkBorder, width: 1),
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: darkInk,
          foregroundColor: Colors.black,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          minimumSize: const Size(88, 48),
          textStyle: const TextStyle(
            fontFamily: fontUI,
            fontWeight: FontWeight.w600,
            fontSize: 14,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: darkTextPrimary,
          side: const BorderSide(color: darkBorder, width: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          minimumSize: const Size(88, 48),
          textStyle: const TextStyle(
            fontFamily: fontUI,
            fontWeight: FontWeight.w500,
            fontSize: 14,
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xFF262626),
        contentTextStyle: TextStyle(
          fontFamily: fontUI,
          color: Colors.white,
          fontSize: 13,
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
