import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Athena Theme Extension providing the canonical editorial design tokens.
class AthenaTokens extends ThemeExtension<AthenaTokens> {
  final Color canvas;
  final Color surface;
  final Color surfaceSubtle;
  final Color surfaceWarm;
  final Color ink;
  final Color inkMuted;
  final Color hairline;
  final Color accent;
  final Color brandLime;
  final double radius4;
  final double radius8;
  final double radius12;
  final double radius16;
  final double radius20;
  final double radius24;
  final double minTouchTarget;

  const AthenaTokens({
    this.canvas = const Color(0xFFFBF9F5),
    this.surface = const Color(0xFFFFFFFF),
    this.surfaceSubtle = const Color(0xFFF2EFE9),
    this.surfaceWarm = const Color(0xFFFAF7F2),
    this.ink = const Color(0xFF161615),
    this.inkMuted = const Color(0xFF6E6E6B),
    this.hairline = const Color(0xFFE6E1D6),
    this.accent = const Color(0xFF2D6A4F),
    this.brandLime = const Color(0xFFBAF82A),
    this.radius4 = 4.0,
    this.radius8 = 8.0,
    this.radius12 = 12.0,
    this.radius16 = 16.0,
    this.radius20 = 20.0,
    this.radius24 = 24.0,
    this.minTouchTarget = 48.0,
  });

  static const AthenaTokens paper = AthenaTokens(
    canvas: Color(0xFFFBF9F5),
    surface: Color(0xFFFFFFFF),
    surfaceSubtle: Color(0xFFF2EFE9),
    surfaceWarm: Color(0xFFFAF7F2),
    ink: Color(0xFF161615),
    inkMuted: Color(0xFF6E6E6B),
    hairline: Color(0xFFE6E1D6),
    accent: Color(0xFF2D6A4F),
    brandLime: Color(0xFFBAF82A),
  );

  static const AthenaTokens sepia = AthenaTokens(
    canvas: Color(0xFFF4ECD8),
    surface: Color(0xFFFAF4E4),
    surfaceSubtle: Color(0xFFEAE0C8),
    surfaceWarm: Color(0xFFF7F1E0),
    ink: Color(0xFF2C221E),
    inkMuted: Color(0xFF6E5D53),
    hairline: Color(0xFFDCD0B8),
    accent: Color(0xFF8C4A27),
    brandLime: Color(0xFF8C4A27),
  );

  static const AthenaTokens charcoal = AthenaTokens(
    canvas: Color(0xFF121316),
    surface: Color(0xFF1A1C20),
    surfaceSubtle: Color(0xFF22252A),
    surfaceWarm: Color(0xFF1F2227),
    ink: Color(0xFFECEAE4),
    inkMuted: Color(0xFF9CA0A8),
    hairline: Color(0xFF2A2E35),
    accent: Color(0xFF34D399),
    brandLime: Color(0xFF34D399),
  );

  static const AthenaTokens oled = AthenaTokens(
    canvas: Color(0xFF000000),
    surface: Color(0xFF0A0A0C),
    surfaceSubtle: Color(0xFF121215),
    surfaceWarm: Color(0xFF0E0E10),
    ink: Color(0xFFF5F5F0),
    inkMuted: Color(0xFF8E8E93),
    hairline: Color(0xFF1F1F24),
    accent: Color(0xFF34D399),
    brandLime: Color(0xFF34D399),
  );

  static const AthenaTokens light = paper;
  static const AthenaTokens dark = charcoal;

  bool get isDark => canvas.computeLuminance() < 0.2;

  @override
  AthenaTokens copyWith({
    Color? canvas,
    Color? surface,
    Color? surfaceSubtle,
    Color? surfaceWarm,
    Color? ink,
    Color? inkMuted,
    Color? hairline,
    Color? accent,
    Color? brandLime,
    double? radius4,
    double? radius8,
    double? radius12,
    double? radius16,
    double? radius20,
    double? radius24,
    double? minTouchTarget,
  }) {
    return AthenaTokens(
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      surfaceSubtle: surfaceSubtle ?? this.surfaceSubtle,
      surfaceWarm: surfaceWarm ?? this.surfaceWarm,
      ink: ink ?? this.ink,
      inkMuted: inkMuted ?? this.inkMuted,
      hairline: hairline ?? this.hairline,
      accent: accent ?? this.accent,
      brandLime: brandLime ?? this.brandLime,
      radius4: radius4 ?? this.radius4,
      radius8: radius8 ?? this.radius8,
      radius12: radius12 ?? this.radius12,
      radius16: radius16 ?? this.radius16,
      radius20: radius20 ?? this.radius20,
      radius24: radius24 ?? this.radius24,
      minTouchTarget: minTouchTarget ?? this.minTouchTarget,
    );
  }

  @override
  AthenaTokens lerp(ThemeExtension<AthenaTokens>? other, double t) {
    if (other is! AthenaTokens) return this;
    return AthenaTokens(
      canvas: Color.lerp(canvas, other.canvas, t) ?? canvas,
      surface: Color.lerp(surface, other.surface, t) ?? surface,
      surfaceSubtle: Color.lerp(surfaceSubtle, other.surfaceSubtle, t) ?? surfaceSubtle,
      surfaceWarm: Color.lerp(surfaceWarm, other.surfaceWarm, t) ?? surfaceWarm,
      ink: Color.lerp(ink, other.ink, t) ?? ink,
      inkMuted: Color.lerp(inkMuted, other.inkMuted, t) ?? inkMuted,
      hairline: Color.lerp(hairline, other.hairline, t) ?? hairline,
      accent: Color.lerp(accent, other.accent, t) ?? accent,
      brandLime: Color.lerp(brandLime, other.brandLime, t) ?? brandLime,
      radius4: radius4,
      radius8: radius8,
      radius12: radius12,
      radius16: radius16,
      radius20: radius20,
      radius24: radius24,
      minTouchTarget: minTouchTarget,
    );
  }
}

extension AthenaThemeContext on BuildContext {
  AthenaTokens get tokens => Theme.of(this).extension<AthenaTokens>() ?? AthenaTokens.paper;
}

/// Unified Athena Appearance state across Library, Processing, Saved, and Reader
enum AthenaAppearance {
  paper,
  sepia,
  charcoal,
  oled;

  String get id => switch (this) {
        AthenaAppearance.paper => 'paper',
        AthenaAppearance.sepia => 'sepia',
        AthenaAppearance.charcoal => 'charcoal',
        AthenaAppearance.oled => 'oled',
      };

  bool get isDark => this == AthenaAppearance.charcoal || this == AthenaAppearance.oled;

  ThemeMode get themeMode => isDark ? ThemeMode.dark : ThemeMode.light;

  static AthenaAppearance fromId(String id) {
    switch (id.toLowerCase()) {
      case 'sepia':
        return AthenaAppearance.sepia;
      case 'charcoal':
      case 'night':
        return AthenaAppearance.charcoal;
      case 'oled':
      case 'obsidian':
        return AthenaAppearance.oled;
      case 'paper':
      default:
        return AthenaAppearance.paper;
    }
  }
}

class AthenaAppearanceNotifier extends Notifier<AthenaAppearance> {
  static const _key = 'athena_appearance_theme';
  final AthenaAppearance? initialAppearance;

  AthenaAppearance _lastLight = AthenaAppearance.paper;
  AthenaAppearance _lastDark = AthenaAppearance.charcoal;

  AthenaAppearanceNotifier([this.initialAppearance]);

  AthenaAppearance get lastLight => _lastLight;
  AthenaAppearance get lastDark => _lastDark;

  @override
  AthenaAppearance build() {
    if (initialAppearance != null) {
      if (initialAppearance!.isDark) {
        _lastDark = initialAppearance!;
      } else {
        _lastLight = initialAppearance!;
      }
      return initialAppearance!;
    }
    _load();
    return AthenaAppearance.paper;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved != null) {
      final app = AthenaAppearance.fromId(saved);
      if (app.isDark) {
        _lastDark = app;
      } else {
        _lastLight = app;
      }
      state = app;
    }
  }

  Future<void> setAppearance(AthenaAppearance app) async {
    if (app.isDark) {
      _lastDark = app;
    } else {
      _lastLight = app;
    }
    state = app;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, app.id);
    await prefs.setString('reader_theme', app.id);
    await prefs.setString('athena_app_theme_mode', app.isDark ? 'dark' : 'light');
  }

  Future<void> toggleLightDark() async {
    final next = state.isDark ? _lastLight : _lastDark;
    if (next.isDark) {
      _lastDark = next;
    } else {
      _lastLight = next;
    }
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, next.id);
    await prefs.setString('reader_theme', next.id);
    await prefs.setString('athena_app_theme_mode', next.isDark ? 'dark' : 'light');
  }
}

final athenaAppearanceProvider =
    NotifierProvider<AthenaAppearanceNotifier, AthenaAppearance>(
        AthenaAppearanceNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _key = 'athena_app_theme_mode';
  final ThemeMode? initialMode;

  ThemeModeNotifier([this.initialMode]);

  @override
  ThemeMode build() {
    final appearance = ref.watch(athenaAppearanceProvider);
    if (initialMode != null) {
      return initialMode!;
    }
    return appearance.themeMode;
  }

  Future<void> toggleTheme() async {
    await ref.read(athenaAppearanceProvider.notifier).toggleLightDark();
    state = ref.read(athenaAppearanceProvider).themeMode;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final appNotifier = ref.read(athenaAppearanceProvider.notifier);
    if (mode == ThemeMode.dark) {
      await appNotifier.setAppearance(appNotifier.lastDark);
    } else if (mode == ThemeMode.light) {
      await appNotifier.setAppearance(appNotifier.lastLight);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, 'system');
      state = ThemeMode.system;
      return;
    }
    state = mode;
  }
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class AppTheme {
  // Stripe Press / Tufte Editorial Architecture:
  // Light Palette Tokens
  static const Color background = Color(0xFFFBF9F5);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceWarm = Color(0xFFFAF7F2);
  static const Color surfaceMuted = Color(0xFFF2EFE9);
  static const Color border = Color(0xFFE6E1D6);
  static const Color hairline = Color(0xFFE6E1D6);
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
  static const Color darkBackground = Color(0xFF121316);
  static const Color darkSurface = Color(0xFF1A1C20);
  static const Color darkSurfaceWarm = Color(0xFF1F2227);
  static const Color darkSurfaceMuted = Color(0xFF22252A);
  static const Color darkBorder = Color(0xFF2A2E35);
  static const Color darkHairline = Color(0xFF2A2E35);
  static const Color darkInk = Color(0xFFECEAE4);
  static const Color darkTextPrimary = Color(0xFFECEAE4);
  static const Color darkTextBody = Color(0xFFDDDDDD);
  static const Color darkTextMuted = Color(0xFF9CA0A8);

  // Dynamic context-aware helpers reading directly from context.tokens
  static bool isDark(BuildContext context) =>
      context.tokens.isDark;

  static Color bgOf(BuildContext context) => context.tokens.canvas;

  static Color surfaceOf(BuildContext context) => context.tokens.surface;

  static Color surfaceWarmOf(BuildContext context) => context.tokens.surfaceWarm;

  static Color surfaceMutedOf(BuildContext context) => context.tokens.surfaceSubtle;

  static Color borderOf(BuildContext context) => context.tokens.hairline;

  static Color hairlineOf(BuildContext context) => context.tokens.hairline;

  static Color inkOf(BuildContext context) => context.tokens.ink;

  static Color textPrimaryOf(BuildContext context) => context.tokens.ink;

  static Color textBodyOf(BuildContext context) => context.tokens.ink;

  static Color textMutedOf(BuildContext context) => context.tokens.inkMuted;

  static Color accentOf(BuildContext context) => context.tokens.accent;

  // Typography tokens per Brand Guide v3
  static const String fontDisplay = 'DM Serif Display';
  static const String fontReading = 'Newsreader';
  static const String fontUI = 'Geist';
  static const String fontMono = 'Geist';
  static const List<String> fontMonoFallbacks = [
    'monospace',
    'RobotoMono',
    'Courier',
  ];
  static const String fontSerif = 'Newsreader';
  static const List<String> fontFallbacks = [
    'Noto Serif',
    'Noto Sans',
    'Roboto',
    'Noto Sans Devanagari',
    'Noto Sans Arabic',
    'Noto Sans Tamil',
    'Noto Sans CJK SC',
    'Noto Sans CJK JP',
    'sans-serif',
  ];

  /// Detects whether text is predominantly right-to-left (Arabic/Hebrew script share > 30%, LNG-04).
  static bool isRtlText(String text) {
    if (text.isEmpty) return false;
    final nonWs = text.replaceAll(RegExp(r'\s+'), '');
    if (nonWs.isEmpty) return false;
    final rtlMatches = RegExp(r'[\u0590-\u05FF\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]')
        .allMatches(nonWs)
        .length;
    return (rtlMatches / nonWs.length) > 0.30;
  }

  static AthenaTokens tokensForAppearance(AthenaAppearance appearance) {
    switch (appearance) {
      case AthenaAppearance.paper:
        return AthenaTokens.paper;
      case AthenaAppearance.sepia:
        return AthenaTokens.sepia;
      case AthenaAppearance.charcoal:
        return AthenaTokens.charcoal;
      case AthenaAppearance.oled:
        return AthenaTokens.oled;
    }
  }

  static ThemeData themeForAppearance(AthenaAppearance appearance) {
    final tokens = tokensForAppearance(appearance);
    final isDark = appearance.isDark;
    final brightness = isDark ? Brightness.dark : Brightness.light;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: fontUI,
      scaffoldBackgroundColor: tokens.canvas,
      primaryColor: tokens.ink,
      colorScheme: isDark
          ? ColorScheme.dark(
              primary: tokens.ink,
              secondary: tokens.accent,
              surface: tokens.surface,
              error: const Color(0xFFEF4444),
              onPrimary: tokens.canvas,
              onSecondary: Colors.white,
              onSurface: tokens.ink,
            )
          : ColorScheme.light(
              primary: tokens.ink,
              secondary: tokens.accent,
              surface: tokens.surface,
              error: const Color(0xFFDC2626),
              onPrimary: tokens.surface,
              onSecondary: Colors.white,
              onSurface: tokens.ink,
            ),
      extensions: [
        tokens,
      ],
      appBarTheme: AppBarTheme(
        backgroundColor: tokens.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        iconTheme: IconThemeData(color: tokens.ink),
        titleTextStyle: TextStyle(
          fontFamily: fontDisplay,
          color: tokens.ink,
          fontSize: 22,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.2,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: tokens.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: tokens.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: tokens.hairline),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: tokens.hairline,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(
        color: tokens.ink,
      ),
      cardTheme: CardThemeData(
        color: tokens.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: tokens.hairline, width: 1),
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: tokens.ink,
          foregroundColor: tokens.canvas,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
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
          foregroundColor: tokens.ink,
          side: BorderSide(color: tokens.hairline, width: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          minimumSize: const Size(88, 48),
          textStyle: const TextStyle(
            fontFamily: fontUI,
            fontWeight: FontWeight.w500,
            fontSize: 14,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: tokens.surface,
        contentTextStyle: TextStyle(
          fontFamily: fontUI,
          color: tokens.ink,
          fontSize: 13,
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static ThemeData get lightTheme => themeForAppearance(AthenaAppearance.paper);

  static ThemeData get darkTheme => themeForAppearance(AthenaAppearance.charcoal);
}

/// Unified token-driven error notification helper across Athena screens
void showAthenaError(BuildContext context, Object error) {
  final dyn = error as dynamic;
  String message = error.toString();
  try {
    if (dyn.message != null) {
      message = dyn.message.toString();
    }
  } catch (e) {
    debugPrint('[Athena] showAthenaError formatting notice: $e');
  }
  final tokens = context.tokens;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: TextStyle(
          color: tokens.isDark ? const Color(0xFFFCA5A5) : const Color(0xFF991B1B),
          fontFamily: AppTheme.fontUI,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
      backgroundColor: tokens.isDark ? const Color(0xFF2A1515) : const Color(0xFFFEE2E2),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radius8),
        side: BorderSide(color: tokens.hairline),
      ),
    ),
  );
}
