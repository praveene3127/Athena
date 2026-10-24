import 'package:flutter/foundation.dart' show kIsWeb;

class AppConfig {
  static const String _configured = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );

  /// Dynamic API Base URL:
  /// - If explicitly set via --dart-define=API_BASE_URL=..., use that.
  /// - On Web, dynamically uses the current browser origin (e.g. HTTPS tunnel or LAN IP).
  /// - On Native, defaults to configured environment or empty string.
  static String get apiBaseUrl {
    if (_configured.isNotEmpty) return _configured;
    if (kIsWeb) {
      try {
        final origin = Uri.base.origin;
        if (origin.isNotEmpty && origin != 'null') {
          return origin;
        }
      } catch (_) {}
    }
    return '';
  }

  static const int statusPollMs = 1500;
  static const int cardMaxWords = 80;
  static const int askMaxQuestionChars = 300;
  static const String appVersion = '0.1.0';
  static const int appBuildNumber = 1;
}
