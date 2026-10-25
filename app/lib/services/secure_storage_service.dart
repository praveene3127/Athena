import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:athena/core/config/config.dart';

/// Secure persistence for backend connection settings using OS-level secure storage
/// (Android Keystore / iOS Keychain / Encrypted Web storage).
/// No tokens are baked into the application bundle.
class SecureStorageService {
  SecureStorageService._();
  static final SecureStorageService instance = SecureStorageService._();

  static const _backendUrlKey = 'athena_backend_url';
  static const _contextTokenKey = 'athena_context_token';

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
    } catch (_) {
      // Keystore unavailable or corrupted; fallback to default
    }
    return AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
  }

  /// Saves the backend URL securely and updates runtime AppConfig.
  Future<void> setBackendUrl(String url) async {
    final sanitized = url.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      await _storage.write(key: _backendUrlKey, value: sanitized);
    } catch (_) {}
    await AppConfig.setBaseUrl(sanitized);
  }

  /// Retrieves the proxy token for authenticated Gemini routes (X-Athena-Context-Token).
  Future<String?> getContextToken() async {
    try {
      final token = await _storage.read(key: _contextTokenKey);
      if (token != null && token.trim().isNotEmpty) {
        return token.trim();
      }
    } catch (_) {
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
