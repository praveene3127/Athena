import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'package:athena/core/config/config.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/api/local_client_factory.dart';
import 'package:athena/services/ingestion_job_coordinator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AthenaAppearance initialAppearance = AthenaAppearance.paper;
  ThemeMode initialThemeMode = ThemeMode.light;

  try {
    final prefs = await SharedPreferences.getInstance();
    final savedApp = prefs.getString('athena_appearance_theme');
    if (savedApp != null) {
      initialAppearance = AthenaAppearance.fromId(savedApp);
      initialThemeMode = initialAppearance.themeMode;
    } else {
      final savedMode = prefs.getString('athena_app_theme_mode');
      if (savedMode == 'dark') {
        initialThemeMode = ThemeMode.dark;
        initialAppearance = AthenaAppearance.charcoal;
      }
    }
  } catch (e) {
    debugPrint('[Athena main] Pre-runApp theme load notice: $e');
  }

  try {
    await AppConfig.init();
    await initializeMobileProcessing();
    await IngestionJobCoordinator.instance.recoverStartupJobs();
  } catch (e) {
    // The app can still process in the foreground if background scheduling
    // is unavailable on this OS/device.
  }

  runApp(
    ProviderScope(
      overrides: [
        athenaAppearanceProvider.overrideWith(
          () => AthenaAppearanceNotifier(initialAppearance),
        ),
        themeModeProvider.overrideWith(
          () => ThemeModeNotifier(initialThemeMode),
        ),
      ],
      child: const AthenaApp(),
    ),
  );
}
