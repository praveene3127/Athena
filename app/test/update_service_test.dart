import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:athena/core/config/update_service.dart';

void main() {
  group('UpdateService Platform Detection', () {
    test('resolves android on TargetPlatform.android', () {
      expect(detectDevicePlatform(TargetPlatform.android), 'android');
    });

    test('resolves ios on TargetPlatform.iOS', () {
      expect(detectDevicePlatform(TargetPlatform.iOS), 'ios');
    });

    test('resolves desktop on Windows, macOS, and Linux', () {
      expect(detectDevicePlatform(TargetPlatform.windows), 'desktop');
      expect(detectDevicePlatform(TargetPlatform.macOS), 'desktop');
      expect(detectDevicePlatform(TargetPlatform.linux), 'desktop');
      expect(detectDevicePlatform(TargetPlatform.fuchsia), 'desktop');
    });
  });

  group('UpdateInfo JSON Deserialization & Binary Mapping', () {
    final payload = {
      'update_available': true,
      'current_version': '1.0.0',
      'latest_version': '1.1.0',
      'release_notes':
          'Improved Per-Page Document Bouncer, 4-Archetype Marginalia Cards, and Mobile Touch Ergonomics.',
      'published_at': '2026-10-28',
      'android': {
        'filename': 'Athena-Android.apk',
        'download_url': '/api/download/android',
        'github_release_url':
            'https://github.com/praveene3127/Athena/releases/latest/download/Athena-Android.apk',
      },
      'ios': {
        'filename': 'Athena-iOS.ipa',
        'download_url': '/api/download/ios',
        'github_release_url':
            'https://github.com/praveene3127/Athena/releases/latest/download/Athena-iOS.ipa',
        'altstore_url':
            'altstore://install?url=https://github.com/praveene3127/Athena/releases/latest/download/Athena-iOS.ipa',
      },
    };

    test('parses platform artifacts correctly', () {
      final info = UpdateInfo.fromJson(payload);

      expect(info.updateAvailable, isTrue);
      expect(info.currentVersion, '1.0.0');
      expect(info.latestVersion, '1.1.0');

      // Android verification
      expect(info.android.filename, 'Athena-Android.apk');
      expect(info.android.downloadUrl, '/api/download/android');
      expect(info.android.githubReleaseUrl, contains('Athena-Android.apk'));

      // iOS verification
      expect(info.ios.filename, 'Athena-iOS.ipa');
      expect(info.ios.downloadUrl, '/api/download/ios');
      expect(info.ios.githubReleaseUrl, contains('Athena-iOS.ipa'));
      expect(info.ios.altstoreUrl, startsWith('altstore://install?url='));
    });

    test('serves Athena-Android.apk to android and Athena-iOS.ipa to ios', () {
      final info = UpdateInfo.fromJson(payload);

      final androidPlatform = detectDevicePlatform(TargetPlatform.android);
      expect(androidPlatform, 'android');
      final androidArtifact = androidPlatform == 'android' ? info.android : info.ios;
      expect(androidArtifact.filename, 'Athena-Android.apk');

      final iosPlatform = detectDevicePlatform(TargetPlatform.iOS);
      expect(iosPlatform, 'ios');
      final iosArtifact = iosPlatform == 'ios' ? info.ios : info.android;
      expect(iosArtifact.filename, 'Athena-iOS.ipa');
    });
  });
}
