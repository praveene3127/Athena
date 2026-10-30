import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'config.dart';

const String kAthenaAppVersion = String.fromEnvironment('ATHENA_VERSION', defaultValue: '1.1.0');

String detectDevicePlatform([TargetPlatform? overridePlatform]) {
  final platform = overridePlatform ?? defaultTargetPlatform;
  if (platform == TargetPlatform.android) {
    return 'android';
  } else if (platform == TargetPlatform.iOS) {
    return 'ios';
  }
  return 'desktop';
}

class UpdatePlatformArtifact {
  final String filename;
  final String downloadUrl;
  final String githubReleaseUrl;
  final String? altstoreUrl;

  const UpdatePlatformArtifact({
    required this.filename,
    required this.downloadUrl,
    required this.githubReleaseUrl,
    this.altstoreUrl,
  });

  factory UpdatePlatformArtifact.fromJson(Map<String, dynamic> json) {
    return UpdatePlatformArtifact(
      filename: json['filename']?.toString() ?? '',
      downloadUrl: json['download_url']?.toString() ?? '',
      githubReleaseUrl: json['github_release_url']?.toString() ?? '',
      altstoreUrl: json['altstore_url']?.toString(),
    );
  }
}

class UpdateInfo {
  final bool updateAvailable;
  final String currentVersion;
  final String latestVersion;
  final String releaseNotes;
  final String publishedAt;
  final UpdatePlatformArtifact android;
  final UpdatePlatformArtifact ios;

  const UpdateInfo({
    required this.updateAvailable,
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    required this.publishedAt,
    required this.android,
    required this.ios,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      updateAvailable: json['update_available'] == true,
      currentVersion: json['current_version']?.toString() ?? '1.1.0',
      latestVersion: json['latest_version']?.toString() ?? '1.1.0',
      releaseNotes: json['release_notes']?.toString() ?? '',
      publishedAt: json['published_at']?.toString() ?? '',
      android: UpdatePlatformArtifact.fromJson(
        json['android'] is Map ? Map<String, dynamic>.from(json['android'] as Map) : {},
      ),
      ios: UpdatePlatformArtifact.fromJson(
        json['ios'] is Map ? Map<String, dynamic>.from(json['ios'] as Map) : {},
      ),
    );
  }
}

class UpdateService {
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 4),
    ),
  );

  /// Checks server or fallback for latest version and platform binaries.
  static Future<UpdateInfo?> checkForUpdates({
    String? baseUrl,
    String? clientVersion,
    TargetPlatform? platformOverride,
  }) async {
    final base = (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(RegExp(r'/+$'), '');
    final version = clientVersion ?? kAthenaAppVersion;
    final platform = detectDevicePlatform(platformOverride);

    try {
      final response = await _dio.get(
        '$base/api/app-update',
        queryParameters: {
          'current_version': version,
          'platform': platform,
        },
      );
      if (response.statusCode == 200 && response.data is Map) {
        return UpdateInfo.fromJson(Map<String, dynamic>.from(response.data as Map));
      }
    } catch (_) {
      // Offline or network error: return null gracefully without crashing
    }
    return null;
  }

  /// Triggers direct 1-click download of the platform-specific release binary.
  static Future<bool> downloadPlatformUpdate({
    required UpdateInfo updateInfo,
    required String platform,
    bool useAltStore = false,
    String? baseUrl,
  }) async {
    final base = (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(RegExp(r'/+$'), '');
    String targetUrl;

    if (platform == 'android') {
      final raw = updateInfo.android.downloadUrl.isNotEmpty
          ? updateInfo.android.downloadUrl
          : updateInfo.android.githubReleaseUrl;
      targetUrl = raw.startsWith('http') ? raw : '$base$raw';
    } else if (platform == 'ios') {
      if (useAltStore && updateInfo.ios.altstoreUrl != null && updateInfo.ios.altstoreUrl!.isNotEmpty) {
        targetUrl = updateInfo.ios.altstoreUrl!;
      } else {
        final raw = updateInfo.ios.downloadUrl.isNotEmpty
            ? updateInfo.ios.downloadUrl
            : updateInfo.ios.githubReleaseUrl;
        targetUrl = raw.startsWith('http') ? raw : '$base$raw';
      }
    } else {
      // Default to Android APK if not specified
      final raw = updateInfo.android.downloadUrl.isNotEmpty
          ? updateInfo.android.downloadUrl
          : updateInfo.android.githubReleaseUrl;
      targetUrl = raw.startsWith('http') ? raw : '$base$raw';
    }

    final uri = Uri.parse(targetUrl);
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return await launchUrl(uri);
    }
  }
}
