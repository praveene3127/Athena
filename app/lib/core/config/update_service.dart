import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'config.dart';

const String kAthenaAppVersion =
    String.fromEnvironment('ATHENA_VERSION', defaultValue: '1.1.0');

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
        json['android'] is Map
            ? Map<String, dynamic>.from(json['android'] as Map)
            : {},
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

  /// Compares semantic versions (e.g. "1.1.1" vs "1.1.0").
  static bool isVersionNewer(String latest, String current) {
    List<int> parse(String v) {
      final nums = RegExp(r'\d+')
          .allMatches(v)
          .map((m) => int.tryParse(m.group(0) ?? '') ?? 0)
          .toList();
      while (nums.length < 3) {
        nums.add(0);
      }
      return nums;
    }

    final l = parse(latest);
    final c = parse(current);
    for (int i = 0; i < 3; i++) {
      if (l[i] > c[i]) return true;
      if (l[i] < c[i]) return false;
    }
    return false;
  }

  /// Checks server or GitHub release metadata for latest version and platform binaries.
  static Future<UpdateInfo?> checkForUpdates({
    String? baseUrl,
    String? clientVersion,
    TargetPlatform? platformOverride,
  }) async {
    final base =
        (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(RegExp(r'/+$'), '');
    final version = clientVersion ?? kAthenaAppVersion;
    final platform = detectDevicePlatform(platformOverride);

    final targetPlat = platformOverride ?? defaultTargetPlatform;
    final isMobile = !kIsWeb &&
        (targetPlat == TargetPlatform.android ||
            targetPlat == TargetPlatform.iOS);
    final isLoopback = base.contains('127.0.0.1') || base.contains('localhost');

    // 1. Try local companion server endpoint if available and not a mobile loopback trap
    if (!isMobile || !isLoopback || AppConfig.isCustomServerConfigured) {
      try {
        final response = await _dio.get(
          '$base/api/app-update',
          queryParameters: {
            'current_version': version,
            'platform': platform,
          },
        );
        if (response.statusCode == 200 && response.data is Map) {
          return UpdateInfo.fromJson(
              Map<String, dynamic>.from(response.data as Map));
        }
      } catch (_) {
        // Local companion server unavailable or offline — proceed to remote fallback
      }
    }

    // 2. Query GitHub version.json directly
    // This allows mobile clients to check for updates reliably anywhere,
    // independent of the laptop server state.
    try {
      final ghResponse = await _dio.get(
        'https://raw.githubusercontent.com/praveene3127/Athena/main/scripts/version.json',
      );
      if (ghResponse.statusCode == 200 && ghResponse.data != null) {
        final Map<String, dynamic> data = ghResponse.data is Map
            ? Map<String, dynamic>.from(ghResponse.data as Map)
            : Map<String, dynamic>.from(
                jsonDecode(ghResponse.data.toString()) as Map);
        final latestVer = data['version']?.toString() ?? '1.1.0';
        final isNewer = isVersionNewer(latestVer, version);
        final rawApk = data['github_apk_url']?.toString() ??
            'https://github.com/praveene3127/Athena/raw/main/releases/athena-release.apk';
        final rawIpa = data['github_ipa_url']?.toString() ??
            'https://github.com/praveene3127/Athena/raw/main/releases/athena-ios-release.ipa';
        return UpdateInfo(
          updateAvailable: isNewer,
          currentVersion: version,
          latestVersion: latestVer,
          releaseNotes: data['release_notes']?.toString() ??
              'Improved Per-Page Document Bouncer, 4-Archetype Marginalia Cards, and Mobile Touch Ergonomics.',
          publishedAt: data['published_at']?.toString() ?? '2026-11-01',
          android: UpdatePlatformArtifact(
            filename: 'athena-release.apk',
            downloadUrl: rawApk,
            githubReleaseUrl: rawApk,
          ),
          ios: UpdatePlatformArtifact(
            filename: 'athena-ios-release.ipa',
            downloadUrl: rawIpa,
            githubReleaseUrl: rawIpa,
            altstoreUrl: 'altstore://install?url=$rawIpa',
          ),
        );
      }
    } catch (_) {}

    return null;
  }

  /// Triggers direct 1-click download of the platform-specific release binary.
  static Future<bool> downloadPlatformUpdate({
    required UpdateInfo updateInfo,
    required String platform,
    bool useAltStore = false,
    String? baseUrl,
  }) async {
    final base =
        (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(RegExp(r'/+$'), '');
    final isMobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final isLoopback = base.contains('127.0.0.1') || base.contains('localhost');

    const defaultApkUrl =
        'https://github.com/praveene3127/Athena/raw/main/releases/athena-release.apk';
    const defaultIpaUrl =
        'https://github.com/praveene3127/Athena/raw/main/releases/athena-ios-release.ipa';

    String targetUrl;

    if (platform == 'android') {
      if (isMobile && (isLoopback || !AppConfig.isCustomServerConfigured)) {
        targetUrl = updateInfo.android.githubReleaseUrl.isNotEmpty
            ? updateInfo.android.githubReleaseUrl
            : defaultApkUrl;
      } else {
        final raw = updateInfo.android.downloadUrl.isNotEmpty
            ? updateInfo.android.downloadUrl
            : updateInfo.android.githubReleaseUrl;
        targetUrl = raw.startsWith('http') ? raw : '$base$raw';
      }
    } else if (platform == 'ios') {
      if (useAltStore &&
          updateInfo.ios.altstoreUrl != null &&
          updateInfo.ios.altstoreUrl!.isNotEmpty) {
        targetUrl = updateInfo.ios.altstoreUrl!;
      } else if (isMobile &&
          (isLoopback || !AppConfig.isCustomServerConfigured)) {
        targetUrl = updateInfo.ios.githubReleaseUrl.isNotEmpty
            ? updateInfo.ios.githubReleaseUrl
            : defaultIpaUrl;
      } else {
        final raw = updateInfo.ios.downloadUrl.isNotEmpty
            ? updateInfo.ios.downloadUrl
            : updateInfo.ios.githubReleaseUrl;
        targetUrl = raw.startsWith('http') ? raw : '$base$raw';
      }
    } else {
      if (isMobile && (isLoopback || !AppConfig.isCustomServerConfigured)) {
        targetUrl = updateInfo.android.githubReleaseUrl.isNotEmpty
            ? updateInfo.android.githubReleaseUrl
            : defaultApkUrl;
      } else {
        final raw = updateInfo.android.downloadUrl.isNotEmpty
            ? updateInfo.android.downloadUrl
            : updateInfo.android.githubReleaseUrl;
        targetUrl = raw.startsWith('http') ? raw : '$base$raw';
      }
    }

    final uri = Uri.parse(targetUrl);
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return await launchUrl(uri);
    }
  }
}
