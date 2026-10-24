import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:athena/core/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppTheme & ThemeModeNotifier Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('ThemeModeNotifier toggles and persists theme', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Default before stored preferences is light
      expect(container.read(themeModeProvider), ThemeMode.light);

      // Set to dark
      await container.read(themeModeProvider.notifier).setThemeMode(ThemeMode.dark);
      expect(container.read(themeModeProvider), ThemeMode.dark);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('athena_app_theme_mode'), 'dark');

      // Toggle from dark -> light
      await container.read(themeModeProvider.notifier).toggleTheme();
      expect(container.read(themeModeProvider), ThemeMode.light);
      expect(prefs.getString('athena_app_theme_mode'), 'light');

      // Toggle from light -> dark
      await container.read(themeModeProvider.notifier).toggleTheme();
      expect(container.read(themeModeProvider), ThemeMode.dark);
      expect(prefs.getString('athena_app_theme_mode'), 'dark');

      // Set to system
      await container.read(themeModeProvider.notifier).setThemeMode(ThemeMode.system);
      expect(container.read(themeModeProvider), ThemeMode.system);
      expect(prefs.getString('athena_app_theme_mode'), 'system');
    });

    testWidgets('AppTheme context helpers react to Brightness.dark and Brightness.light',
        (tester) async {
      await tester.pumpWidget(
        Theme(
          data: AppTheme.lightTheme,
          child: Builder(
            builder: (context) {
              expect(AppTheme.isDark(context), isFalse);
              expect(AppTheme.bgOf(context), AppTheme.background);
              expect(AppTheme.surfaceOf(context), AppTheme.surface);
              expect(AppTheme.inkOf(context), AppTheme.ink);
              return const SizedBox();
            },
          ),
        ),
      );

      await tester.pumpWidget(
        Theme(
          data: AppTheme.darkTheme,
          child: Builder(
            builder: (context) {
              expect(AppTheme.isDark(context), isTrue);
              expect(AppTheme.bgOf(context), AppTheme.darkBackground);
              expect(AppTheme.surfaceOf(context), AppTheme.darkSurface);
              expect(AppTheme.inkOf(context), AppTheme.darkInk);
              return const SizedBox();
            },
          ),
        ),
      );
    });
  });
}
