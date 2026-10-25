import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static String? _runtimeBaseUrl;

  static const String _configured = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );

  static const String nativeFallback = 'http://127.0.0.1:8000';

  /// Load runtime URL from local preferences (native Server URL).
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('athena_backend_url');
      if (saved != null && saved.trim().isNotEmpty) {
        _runtimeBaseUrl = saved.trim().replaceAll(RegExp(r'/+$'), '');
      }
    } catch (_) {}
  }

  /// Save and update runtime URL.
  static Future<void> setBaseUrl(String url) async {
    final sanitized = url.trim().replaceAll(RegExp(r'/+$'), '');
    _runtimeBaseUrl = sanitized.isEmpty ? null : sanitized;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (sanitized.isEmpty) {
        await prefs.remove('athena_backend_url');
      } else {
        await prefs.setString('athena_backend_url', sanitized);
      }
    } catch (_) {}
  }

  /// Pure host resolver used by [apiBaseUrl] and unit tests.
  ///
  /// Web: same-origin whenever the page is not a raw loopback compile default.
  /// LAN IPs and tunnels always use [origin]. Loopback (`localhost` / `127.0.0.1`)
  /// also uses [origin] so `:8000` and the `:8080` forwarder hit `/api/health`.
  /// Native: saved Server URL, then `--dart-define`, then USB loopback.
  static String resolveBaseUrl({
    required bool isWeb,
    required String host,
    required String origin,
    String? runtime,
    String configured = '',
  }) {
    if (runtime != null && runtime.isNotEmpty) return runtime;
    if (configured.isNotEmpty) return configured;
    if (isWeb) {
      final cleanOrigin = origin.trim();
      if (cleanOrigin.isEmpty || cleanOrigin == 'null') {
        return nativeFallback;
      }
      // Phone on LAN / tunnel (host is not loopback): never 127.0.0.1.
      // Laptop web on localhost:8000 or :8080: still this origin (/api/health).
      if (host != 'localhost' && host != '127.0.0.1') {
        return cleanOrigin;
      }
      return cleanOrigin;
    }
    return nativeFallback;
  }

  static String get apiBaseUrl {
    String origin = '';
    String host = '';
    if (kIsWeb) {
      try {
        origin = Uri.base.origin;
        host = Uri.base.host;
      } catch (_) {}
    }
    return resolveBaseUrl(
      isWeb: kIsWeb,
      host: host,
      origin: origin,
      runtime: _runtimeBaseUrl,
      configured: _configured,
    );
  }

  static const int statusPollMs = 1500;
  static const int cardMaxWords = 80;
  static const int askMaxQuestionChars = 2000;
  static const String appVersion = '0.1.1';
  static const int appBuildNumber = 2;
}
