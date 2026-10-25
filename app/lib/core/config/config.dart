import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static String? _runtimeBaseUrl;

  static const String _configured = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://settled-penny-decades-reminder.trycloudflare.com',
  );

  /// Load runtime URL from local preferences
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('athena_backend_url');
      if (saved != null && saved.trim().isNotEmpty) {
        _runtimeBaseUrl = saved.trim().replaceAll(RegExp(r'/+$'), '');
      }
    } catch (_) {}
  }

  /// Save and update runtime URL
  static Future<void> setBaseUrl(String url) async {
    final sanitized = url.trim().replaceAll(RegExp(r'/+$'), '');
    _runtimeBaseUrl = sanitized;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (sanitized.isEmpty) {
        await prefs.remove('athena_backend_url');
      } else {
        await prefs.setString('athena_backend_url', sanitized);
      }
    } catch (_) {}
  }

  /// Dynamic API Base URL:
  /// - Returns runtime configured URL (from settings/preferences) if available.
  /// - If explicitly set via --dart-define=API_BASE_URL=..., uses that.
  /// - On Web, dynamically uses the current browser origin.
  /// - Fallback to public Cloudflare tunnel.
  static String get apiBaseUrl {
    if (_runtimeBaseUrl != null && _runtimeBaseUrl!.isNotEmpty) {
      return _runtimeBaseUrl!;
    }
    if (_configured.isNotEmpty) return _configured;
    if (kIsWeb) {
      try {
        final origin = Uri.base.origin;
        if (origin.isNotEmpty && origin != 'null') {
          return origin;
        }
      } catch (_) {}
    }
    return 'https://settled-penny-decades-reminder.trycloudflare.com';
  }

  static const int statusPollMs = 1500;
  static const int cardMaxWords = 80;
  static const int askMaxQuestionChars = 2000;
  static const String appVersion = '0.1.1';
  static const int appBuildNumber = 2;
}
