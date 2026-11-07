import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:athena/core/config/config.dart';

/// Secure persistence for mobile credentials using Android Keystore / iOS Keychain.
/// Web builds keep API credentials in the platform's supported preferences store.
/// No tokens are baked into the application bundle.
class SecureStorageService {
  SecureStorageService._();
  static final SecureStorageService instance = SecureStorageService._();

  static const _backendUrlKey = 'athena_backend_url';
  static const _contextTokenKey = 'athena_context_token';
  static const _aiKeyNames = {
    'athena_ai_primary_api_key',
    'athena_ai_fallback_api_key',
  };

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// Retrieves the saved backend URL, falling back to AppConfig default.
  Future<String> getBackendUrl() async {
    try {
      final saved = await _storage.read(key: _backendUrlKey);
      if (saved != null && saved.trim().isNotEmpty) {
        return saved.trim().replaceAll(RegExp(r'/+$'), '');
      }
    } catch (e) {
      // Keystore unavailable or corrupted; fallback to default
    }
    return AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
  }

  /// Saves the backend URL securely and updates runtime AppConfig.
  Future<void> setBackendUrl(String url) async {
    final sanitized = url.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      await _storage.write(key: _backendUrlKey, value: sanitized);
    } catch (e) {
      debugPrint('Athena caught error: $e');
    }
    await AppConfig.setBaseUrl(sanitized);
  }

  /// Retrieves the proxy token for authenticated Gemini routes (X-Athena-Context-Token).
  Future<String?> getContextToken() async {
    try {
      final token = await _storage.read(key: _contextTokenKey);
      if (token != null && token.trim().isNotEmpty) {
        return token.trim();
      }
    } catch (e) {
      // Secure storage read error
    }
    return null;
  }

  /// Saves the proxy token to the OS Keystore/Keychain.
  Future<void> setContextToken(String token) async {
    final sanitized = token.trim();
    if (sanitized.isEmpty) {
      await _storage.delete(key: _contextTokenKey);
    } else {
      await _storage.write(key: _contextTokenKey, value: sanitized);
    }
  }

  /// Reads an AI credential from OS secure storage. Existing plaintext values
  /// are migrated once, then removed from SharedPreferences.
  Future<String?> getAIKey(String key) async {
    if (!_aiKeyNames.contains(key)) {
      throw ArgumentError.value(key, 'key', 'Unknown AI credential name');
    }
    final prefs = await SharedPreferences.getInstance();
    if (kIsWeb) return prefs.getString(key);
    try {
      final stored = await _storage.read(key: key);
      if (stored != null && stored.isNotEmpty) {
        await prefs.remove(key);
        return stored;
      }
    } catch (e) {
      debugPrint('Athena secure AI key read notice: $e');
    }
    final legacy = prefs.getString(key);
    if (legacy != null && legacy.isNotEmpty) {
      await _storage.write(key: key, value: legacy);
      await prefs.remove(key);
    }
    return legacy;
  }

  Future<void> setAIKey(String key, String? value) async {
    if (!_aiKeyNames.contains(key)) {
      throw ArgumentError.value(key, 'key', 'Unknown AI credential name');
    }
    final prefs = await SharedPreferences.getInstance();
    final clean = value?.trim() ?? '';
    if (kIsWeb) {
      if (clean.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, clean);
      }
      return;
    }
    if (clean.isEmpty) {
      await _storage.delete(key: key);
    } else {
      await _storage.write(key: key, value: clean);
    }
    await prefs.remove(key);
  }

  /// Clears stored connection credentials.
  Future<void> clear() async {
    await _storage.delete(key: _backendUrlKey);
    await _storage.delete(key: _contextTokenKey);
  }

  /// Validates that an external URL uses HTTPS to protect excerpts in transit.
  /// Local development addresses (localhost, loopback, LAN) are allowed HTTP.
  static bool isSecureUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !uri.hasScheme) return false;
    final host = uri.host.toLowerCase();
    final isLocal = host == 'localhost' ||
        host.startsWith('127.') ||
        host == '10.0.2.2' ||
        host.startsWith('192.168.') ||
        host.startsWith('10.');
    if (isLocal) return true;
    return uri.scheme == 'https';
  }

  /// Tests connectivity to the specified backend URL.
  Future<({bool success, bool llmConfigured, String message})> testConnection({
    String? testUrl,
    String? testToken,
  }) async {
    final url = testUrl ?? await getBackendUrl();
    final sanitizedUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(sanitizedUrl);

    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return (
        success: false,
        llmConfigured: false,
        message: 'Invalid URL format. Please include http:// or https://'
      );
    }

    if (!isSecureUrl(sanitizedUrl)) {
      return (
        success: false,
        llmConfigured: false,
        message:
            'Remote endpoints must use HTTPS to safeguard text fidelity and excerpts.'
      );
    }

    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ),
    );

    try {
      final res = await dio.get('$sanitizedUrl/api/health');
      if (res.statusCode == 200 && res.data is Map) {
        final data = res.data as Map<String, dynamic>;
        final isConfigured = data['llm_configured'] == true;
        return (
          success: true,
          llmConfigured: isConfigured,
          message: isConfigured
              ? 'Connected successfully. Gemini AI is configured on the backend.'
              : 'Connected. Backend is online, but Gemini API key is not yet set in backend/.env.'
        );
      }
      return (
        success: false,
        llmConfigured: false,
        message: 'Backend responded with status ${res.statusCode}.'
      );
    } on DioException catch (e) {
      return (
        success: false,
        llmConfigured: false,
        message: 'Connection failed: ${e.message ?? 'Server unreachable'}'
      );
    } catch (e) {
      return (
        success: false,
        llmConfigured: false,
        message: 'Connection test error: $e'
      );
    }
  }
}
