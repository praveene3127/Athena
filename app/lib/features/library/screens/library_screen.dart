import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:athena/core/widgets/app_bottom_nav.dart';
import 'package:athena/core/config/config.dart';
import 'package:athena/core/config/update_service.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/errors.dart';
import 'package:athena/models/document.dart';
import 'package:athena/core/api/api_client.dart';
import 'package:athena/core/api/local_client_factory.dart';
import 'package:athena/core/widgets/athena_avatar.dart';
import 'package:athena/core/widgets/athena_logo.dart';
import 'package:athena/features/settings/widgets/byok_settings_sheet.dart';
import 'package:athena/features/settings/screens/connection_setup_screen.dart';

final apiClientProvider = Provider<ApiClient>((ref) => createAppApiClient());

final documentsProvider = FutureProvider.autoDispose<List<Document>>((
  ref,
) async {
  final client = ref.watch(apiClientProvider);
  final list = await client.listDocuments();
  return list.map((e) => Document.fromJson(e)).toList();
});

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with WidgetsBindingObserver {
  bool _uploading = false;
  bool _aiConfigured = true;
  Timer? _pollTimer;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  Map<String, dynamic>? _updateInfo;
  UpdateInfo? _updateModel;
  bool _hasUpdate = false;
  bool _updateDismissed = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAIConfiguration();
    _checkForUpdates();
    try {
      _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
        if (results.any((r) => r != ConnectivityResult.none)) {
          _checkForUpdates();
        }
      });
    } catch (_) {}
  }

  Future<void> _checkAIConfiguration() async {
    try {
      final client = ref.read(apiClientProvider);
      var cfg = await client.getAIConfig();
      final prefs = await SharedPreferences.getInstance();
      final localKey = prefs.getString('athena_ai_primary_api_key');

      // Auto-sync stored key to backend if backend was reset or not configured
      if (!cfg.isConfigured && localKey != null && localKey.isNotEmpty) {
        final localProvider = prefs.getString('athena_ai_primary_provider') ?? 'gemini';
        final localModel = prefs.getString('athena_ai_primary_model');
        final localBaseUrl = prefs.getString('athena_ai_primary_base_url');
        final localFallbackProv = prefs.getString('athena_ai_fallback_provider');
        final localFallbackKey = prefs.getString('athena_ai_fallback_api_key');
        final localFallbackModel = prefs.getString('athena_ai_fallback_model');
        final localFallbackBaseUrl = prefs.getString('athena_ai_fallback_base_url');

        try {
          await client.saveAIConfig(
            primaryProvider: localProvider,
            primaryApiKey: localKey,
            primaryModel: localModel,
            primaryBaseUrl: localBaseUrl,
            fallbackProvider: localFallbackProv,
            fallbackApiKey: localFallbackKey,
            fallbackModel: localFallbackModel,
            fallbackBaseUrl: localFallbackBaseUrl,
          );
          cfg = await client.getAIConfig();
        } catch (_) {}
      }

      if (!mounted) return;
      final configured = cfg.isConfigured ||
          (cfg.primaryApiKeyMasked != null && cfg.primaryApiKeyMasked!.isNotEmpty) ||
          (localKey != null && localKey.isNotEmpty);

      setState(() {
        _aiConfigured = configured;
      });
      if (!configured) {
        final hasPrompted =
            prefs.getBool('has_prompted_byok_onboarding') ?? false;
        if (!hasPrompted) {
          await prefs.setBool('has_prompted_byok_onboarding', true);
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              BYOKSettingsSheet.show(
                context,
                apiClient: client,
                onConfigSaved: _checkAIConfiguration,
              );
            });
          }
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _pollTimer?.cancel();
    _searchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(documentsProvider);
      _checkForUpdates();
    }
  }

  Future<void> _checkForUpdates() async {
    try {
      final info = await UpdateService.checkForUpdates();
      if (info != null && info.updateAvailable && mounted) {
        setState(() {
          _updateModel = info;
          _hasUpdate = true;
        });
        return;
      }
      final client = ref.read(apiClientProvider);
      final update = await client.checkAppUpdate();
      if (update != null && mounted) {
        final serverBuild = update['build_number'] as int? ?? 1;
        final serverVersion = update['version'] as String? ?? '0.1.0';
        final isNewer = serverBuild > AppConfig.appBuildNumber ||
            serverVersion != AppConfig.appVersion;
        setState(() {
          _updateInfo = update;
          _hasUpdate = isNewer;
        });
      }
    } catch (_) {}
  }

  void _showUpdateDialog() {
    if (_updateInfo == null) return;
    final title = _updateInfo!['title'] as String? ?? 'Athena Update';
    final notes = _updateInfo!['release_notes'] as String? ??
        'New improvements and reading updates are ready.';
    final version = _updateInfo!['version'] as String? ?? 'latest';
    final buildNumber = _updateInfo!['build_number'] as int? ?? 1;
    final apkSize = _updateInfo!['apk_size_mb'] != null
        ? '${_updateInfo!['apk_size_mb']} MB'
        : null;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SafeArea(
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85,
            ),
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          // Outer Shell (Double-Bezel Architecture)
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color:
                  isDark ? const Color(0xFF282828) : const Color(0xFFE5E7DC),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black54 : const Color(0x18141714),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            // Inner Core
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF202020) : Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 18),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF333333)
                            : const Color(0xFFE0E0E0),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const AthenaLogoTile(
                        size: 44,
                        style: AthenaTileStyle.blackPrimary,
                        borderRadius: 12,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? const Color(0xFF2DD4BF)
                                        .withValues(alpha: 0.15)
                                    : const Color(0xFF005E54)
                                        .withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isDark
                                      ? const Color(0xFF2DD4BF)
                                          .withValues(alpha: 0.3)
                                      : const Color(0xFF005E54)
                                          .withValues(alpha: 0.2),
                                ),
                              ),
                              child: Text(
                                'RELEASE BUILD $buildNumber · V$version',
                                style: TextStyle(
                                  fontFamily: AppTheme.fontUI,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.8,
                                  color: isDark
                                      ? const Color(0xFF2DD4BF)
                                      : const Color(0xFF005E54),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              title,
                              style: TextStyle(
                                fontFamily: AppTheme.fontDisplay,
                                fontSize: 19,
                                fontWeight: FontWeight.w400,
                                letterSpacing: -0.2,
                                color: isDark ? Colors.white : AppTheme.ink,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF181818)
                          : const Color(0xFFFBFBF9),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF2E2E2E)
                            : const Color(0xFFECEEE4),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'RELEASE HIGHLIGHTS',
                          style: TextStyle(
                            fontFamily: AppTheme.fontUI,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            color: isDark
                                ? const Color(0xFF9E9E9E)
                                : AppTheme.textMuted,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          notes,
                          style: TextStyle(
                            fontFamily: AppTheme.fontUI,
                            fontSize: 12.5,
                            height: 1.5,
                            color: isDark
                                ? const Color(0xFFE0E0E0)
                                : AppTheme.textBody,
                          ),
                        ),
                        if (apkSize != null) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Icon(
                                Icons.attachment_rounded,
                                size: 13,
                                color: isDark
                                    ? const Color(0xFF9E9E9E)
                                    : AppTheme.textMuted,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Package size: $apkSize',
                                style: TextStyle(
                                  fontFamily: AppTheme.fontUI,
                                  fontSize: 11,
                                  color: isDark
                                      ? const Color(0xFF9E9E9E)
                                      : AppTheme.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => Navigator.pop(ctx),
                          borderRadius: BorderRadius.circular(24),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF181818)
                                  : const Color(0xFFF2F0E8),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF2E2E2E)
                                    : const Color(0xFFE5E7DC),
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              'Later',
                              style: TextStyle(
                                fontFamily: AppTheme.fontUI,
                                color: isDark ? Colors.white70 : AppTheme.ink,
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: InkWell(
                          onTap: () {
                            Navigator.pop(ctx);
                            _applyUpdate();
                          },
                          borderRadius: BorderRadius.circular(24),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: BoxDecoration(
                              color: isDark ? Colors.white : AppTheme.ink,
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                  color: isDark
                                      ? Colors.white12
                                      : const Color(0x20141714),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.download_rounded,
                                  size: 16,
                                  color: isDark
                                      ? const Color(0xFF141714)
                                      : Colors.white,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Install Update',
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontUI,
                                    color: isDark
                                        ? const Color(0xFF141714)
                                        : Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  }

  void _applyUpdate() {
    if (kIsWeb) {
      final webUrl = _updateInfo?['download_url_web'] as String? ?? '/';
      final target = webUrl.startsWith('http')
          ? webUrl
          : (AppConfig.apiBaseUrl.isEmpty ? '/' : AppConfig.apiBaseUrl);
      launchUrl(Uri.parse(target), webOnlyWindowName: '_self');
      return;
    }
    final apkUrl = _updateInfo?['download_url_apk'] as String? ??
        '/releases/athena-release.apk';
    final fullUrl = apkUrl.startsWith('http')
        ? apkUrl
        : '${AppConfig.apiBaseUrl}$apkUrl';
    launchUrl(Uri.parse(fullUrl), mode: LaunchMode.externalApplication);
  }

  UpdateInfo get _effectiveUpdateInfo {
    if (_updateModel != null) return _updateModel!;
    return UpdateInfo(
      updateAvailable: _hasUpdate,
      currentVersion: kAthenaAppVersion,
      latestVersion: _updateInfo?['version']?.toString() ?? '1.1.0',
      releaseNotes: _updateInfo?['release_notes']?.toString() ??
          'Improved Per-Page Document Bouncer, 4-Archetype Marginalia Cards, and Mobile Touch Ergonomics.',
      publishedAt: '2026-10-28',
      android: const UpdatePlatformArtifact(
        filename: 'Athena-Android.apk',
        downloadUrl: '/api/download/android',
        githubReleaseUrl: 'https://github.com/athena-reader/athena/releases/latest/download/Athena-Android.apk',
      ),
      ios: const UpdatePlatformArtifact(
        filename: 'Athena-iOS.ipa',
        downloadUrl: '/api/download/ios',
        githubReleaseUrl: 'https://github.com/athena-reader/athena/releases/latest/download/Athena-iOS.ipa',
        altstoreUrl: 'altstore://install?url=https://github.com/athena-reader/athena/releases/latest/download/Athena-iOS.ipa',
      ),
    );
  }

  Widget _buildEditorialUpdateBanner(bool isDark) {
    final platform = detectDevicePlatform();
    final info = _effectiveUpdateInfo;
    final latestVersion = info.latestVersion;
    final releaseNotes = info.releaseNotes.isNotEmpty
        ? info.releaseNotes
        : 'Improved Per-Page Document Bouncer, 4-Archetype Marginalia Cards, and Mobile Touch Ergonomics.';

    final String kicker;
    if (platform == 'android') {
      kicker = 'UPDATE AVAILABLE · v$latestVersion FOR ANDROID';
    } else if (platform == 'ios') {
      kicker = 'UPDATE AVAILABLE · v$latestVersion FOR iOS';
    } else {
      kicker = 'UPDATE v$latestVersion AVAILABLE';
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1C) : const Color(0xFFF2EFE9),
        borderRadius: BorderRadius.circular(4),
        border: Border(
          left: const BorderSide(
            color: Color(0xFFC84B31), // Terracotta accent spine
            width: 4.0,
          ),
          top: BorderSide(
            color: isDark ? const Color(0xFF2C2B29) : const Color(0xFFE2DDD5),
            width: 1.0,
          ),
          right: BorderSide(
            color: isDark ? const Color(0xFF2C2B29) : const Color(0xFFE2DDD5),
            width: 1.0,
          ),
          bottom: BorderSide(
            color: isDark ? const Color(0xFF2C2B29) : const Color(0xFFE2DDD5),
            width: 1.0,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black26 : const Color(0x0C161615),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: InkWell(
                  onTap: _showUpdateDialog,
                  child: Text(
                    kicker,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: Color(0xFFC84B31),
                    ),
                  ),
                ),
              ),
              InkWell(
                onTap: () {
                  setState(() {
                    _updateDismissed = true;
                  });
                },
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: isDark ? const Color(0xFF888888) : const Color(0xFF666666),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          InkWell(
            onTap: _showUpdateDialog,
            child: Text(
              releaseNotes,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppTheme.fontUI,
                fontSize: 12.5,
                height: 1.4,
                color: isDark ? const Color(0xFFE0DDD5) : const Color(0xFF161615),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (platform == 'android') ...[
            SizedBox(
              height: 36,
              child: ElevatedButton.icon(
                onPressed: () {
                  UpdateService.downloadPlatformUpdate(
                    updateInfo: info,
                    platform: 'android',
                  );
                },
                icon: const Icon(Icons.download_rounded, size: 15),
                label: const Text(
                  'Download Android .APK ↓',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF161615),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
              ),
            ),
          ] else if (platform == 'ios') ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  height: 36,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      UpdateService.downloadPlatformUpdate(
                        updateInfo: info,
                        platform: 'ios',
                      );
                    },
                    icon: const Icon(Icons.download_rounded, size: 15),
                    label: const Text(
                      'Download iOS .IPA ↓',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF161615),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                  ),
                ),
                SizedBox(
                  height: 36,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      UpdateService.downloadPlatformUpdate(
                        updateInfo: info,
                        platform: 'ios',
                        useAltStore: true,
                      );
                    },
                    icon: const Icon(Icons.install_mobile_rounded, size: 15),
                    label: const Text(
                      'Install via AltStore / SideStore',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: isDark ? Colors.white : const Color(0xFF161615),
                      side: BorderSide(
                        color: isDark ? const Color(0xFF444444) : const Color(0xFFCCCCCC),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                SizedBox(
                  height: 36,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      UpdateService.downloadPlatformUpdate(
                        updateInfo: info,
                        platform: 'android',
                      );
                    },
                    icon: const Icon(Icons.android_rounded, size: 15),
                    label: const Text(
                      'Android .APK ↓',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF161615),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                  ),
                ),
                SizedBox(
                  height: 36,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      UpdateService.downloadPlatformUpdate(
                        updateInfo: info,
                        platform: 'ios',
                      );
                    },
                    icon: const Icon(Icons.apple_rounded, size: 15),
                    label: const Text(
                      'iOS .IPA ↓',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDark ? const Color(0xFF333333) : const Color(0xFFE5DDD0),
                      foregroundColor: isDark ? Colors.white : const Color(0xFF161615),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'epub'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    Stream<List<int>>? fileStream;
    int fileSize = file.size;

    if (file.bytes != null) {
      fileStream = Stream.value(file.bytes!);
      fileSize = file.bytes!.length;
    } else if (file.readStream != null) {
      fileStream = file.readStream;
      fileSize = file.size;
    }

    if (fileStream == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not read the selected file. Please try again.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    setState(() => _uploading = true);

    try {
      final client = ref.read(apiClientProvider);
      final docId = await client.uploadDocument(
        fileStream,
        fileSize,
        file.name,
      );
      ref.invalidate(documentsProvider);
      if (mounted) context.push('/processing/$docId');
    } on AppError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppError.getDisplayMessage(e.code, e.message)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _deleteDocument(Document doc) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: isDark ? const Color(0xFF282828) : const Color(0xFFE5E7DC),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black54 : const Color(0x18141714),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF202020) : Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark ? const Color(0xFF2E2E2E) : const Color(0xFFECEEE4),
                width: 1.0,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: isDark ? 0.2 : 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.redAccent.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: const Icon(
                        Icons.delete_outline_rounded,
                        color: Colors.redAccent,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Delete Document',
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          color: isDark ? Colors.white : AppTheme.ink,
                          fontSize: 20,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'This will permanently remove "${_humanizeTitle(doc.title)}" and its context cards from this device. The original document and local cache will be removed.',
                  style: TextStyle(
                    fontFamily: AppTheme.fontUI,
                    color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
                    fontSize: 13.5,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: isDark ? Colors.white : AppTheme.ink,
                          side: BorderSide(
                            color: isDark ? const Color(0xFF333333) : const Color(0xFFE0E0E0),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(
                            fontFamily: AppTheme.fontUI,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        child: const Text(
                          'Delete',
                          style: TextStyle(
                            fontFamily: AppTheme.fontUI,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (confirmed != true) return;

    try {
      final client = ref.read(apiClientProvider);
      await client.deleteDocument(doc.id);
      ref.invalidate(documentsProvider);
    } on AppError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _openDocument(Document doc) async {
    if (!doc.isReady) return;

    try {
      final client = ref.read(apiClientProvider);
      final prefs = await SharedPreferences.getInstance();
      final localKey = prefs.getString('athena_ai_primary_api_key');

      final config = await client.getAIConfig();
      if (!config.isConfigured && localKey != null && localKey.isNotEmpty) {
        // Silently restore to backend
        final localProvider = prefs.getString('athena_ai_primary_provider') ?? 'gemini';
        client.saveAIConfig(
          primaryProvider: localProvider,
          primaryApiKey: localKey,
          primaryModel: prefs.getString('athena_ai_primary_model'),
          primaryBaseUrl: prefs.getString('athena_ai_primary_base_url'),
        ).catchError((_) => <String, dynamic>{});
      }
    } catch (_) {}

    if (mounted) {
      context.push('/reader/${doc.id}');
    }
  }

  Future<void> _retryDocument(Document doc) async {
    try {
      final client = ref.read(apiClientProvider);
      await client.retryDocument(doc.id);
      ref.invalidate(documentsProvider);
      if (mounted) context.push('/processing/${doc.id}');
    } on AppError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final docsState = ref.watch(documentsProvider);

    docsState.whenData((docs) {
      final hasProcessing = docs.any((d) => !d.isReady && !d.isFailed);
      if (hasProcessing && _pollTimer == null) {
        _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
          ref.invalidate(documentsProvider);
        });
      } else if (!hasProcessing && _pollTimer != null) {
        _pollTimer?.cancel();
        _pollTimer = null;
      }
    });

    final documentCount = docsState.maybeWhen(
      data: (docs) => docs.length,
      orElse: () => null,
    );

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final hPad = isMobile ? 16.0 : 24.0;

    return Scaffold(
      backgroundColor: AppTheme.bgOf(context),
      bottomNavigationBar: AthenaBottomNav(
        selectedIndex: 0,
        onDestinationSelected: (index) {
          if (index == 1) context.push('/saved');
        },
        onAddPressed: _uploading ? null : _pickAndUpload,
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: RefreshIndicator(
              color: AppTheme.inkOf(context),
              backgroundColor: AppTheme.surfaceOf(context),
              onRefresh: () async {
                ref.invalidate(documentsProvider);
              },
              child: ListView(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                padding: EdgeInsets.fromLTRB(hPad, 20, hPad, 32),
                children: [
                  // --- 1. Top Bar Lockup per ATHENA-BRAND-GUIDE.md ---
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const AthenaHeaderBrand(
                        tileSize: 38,
                        tileStyle: AthenaTileStyle.blackPrimary,
                        subtitle: 'Never read alone',
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_uploading) ...[
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppTheme.inkOf(context),
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          // Whole-app Theme Switcher Button
                          Consumer(
                            builder: (context, ref, _) {
                              ref.watch(themeModeProvider);
                              final darkActive = isDark;
                              return InkWell(
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  ref.read(themeModeProvider.notifier).toggleTheme();
                                },
                                borderRadius: BorderRadius.circular(10),
                                child: Container(
                                  padding: const EdgeInsets.all(7),
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    color: darkActive ? const Color(0xFF202020) : AppTheme.surfaceWarm,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: darkActive ? const Color(0xFF2E2E2E) : AppTheme.border,
                                    ),
                                  ),
                                  child: Icon(
                                    darkActive ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                                    size: 16,
                                    color: darkActive ? Colors.amberAccent : AppTheme.ink,
                                  ),
                                ),
                              );
                            },
                          ),
                          // Server connection setup button
                          InkWell(
                            onTap: () async {
                              HapticFeedback.selectionClick();
                              final changed = await context.push<bool>('/settings');
                              if (changed == true) {
                                ref.invalidate(documentsProvider);
                                _checkAIConfiguration();
                                _checkForUpdates();
                              }
                            },
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.all(7),
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: isDark ? const Color(0xFF202020) : AppTheme.surfaceWarm,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isDark ? const Color(0xFF2E2E2E) : AppTheme.border,
                                ),
                              ),
                              child: Icon(
                                Icons.dns_outlined,
                                size: 16,
                                color: AppTheme.inkOf(context),
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () => BYOKSettingsSheet.show(
                              context,
                              apiClient: ref.read(apiClientProvider),
                              onConfigSaved: _checkAIConfiguration,
                            ),
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: _aiConfigured
                                    ? (isDark ? const Color(0xFF202020) : AppTheme.surfaceWarm)
                                    : (isDark ? const Color(0xFF332510) : const Color(0xFFFFF8E7)),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: _aiConfigured
                                      ? (isDark ? const Color(0xFF2E2E2E) : AppTheme.border)
                                      : const Color(0xFFD4A373),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.hub_outlined,
                                    size: 15,
                                    color: _aiConfigured
                                        ? AppTheme.inkOf(context)
                                        : const Color(0xFFD4A373),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _aiConfigured
                                        ? 'AI ENGINES'
                                        : 'SETUP API KEY',
                                    style: TextStyle(
                                      fontFamily: AppTheme.fontUI,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                      color: _aiConfigured
                                          ? AppTheme.inkOf(context)
                                          : const Color(0xFFD4A373),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_hasUpdate && !_updateDismissed) ...[
                    _buildEditorialUpdateBanner(isDark),
                  ],

                  if (!_aiConfigured) ...[
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFFFDF8),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isDark ? const Color(0xFF333333) : const Color(0xFFE5DDD0),
                          width: 1.0,
                        ),
                      ),
                      child: Row(
                        children: [
                          const AthenaAvatar(
                            expression: AthenaExpression.sleepy,
                            size: 32,
                            showBezel: true,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Offline Mode Active',
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontDisplay,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? Colors.white : AppTheme.ink,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Reading unblocked · Add API key for AI context cards',
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontUI,
                                    fontSize: 11.5,
                                    color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton.icon(
                            icon: const Icon(Icons.key_rounded, size: 14),
                            label: const Text('Configure API Key',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            onPressed: () => BYOKSettingsSheet.show(
                              context,
                              apiClient: ref.read(apiClientProvider),
                              onConfigSaved: _checkAIConfiguration,
                            ),
                            style: TextButton.styleFrom(
                              foregroundColor: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF005E54),
                              backgroundColor: (isDark ? const Color(0xFF2DD4BF) : const Color(0xFF005E54))
                                  .withValues(alpha: 0.1),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_aiConfigured) const SizedBox(height: 8),

                  // --- 2. Editorial Hero Masthead (Double-Bezel Architecture) ---
                  Container(
                    width: double.infinity,
                    // Outer Shell (Doppelrand)
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(
                        color: isDark ? const Color(0xFF282828) : const Color(0xFFE8EAE0),
                        width: 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isDark ? Colors.black26 : const Color(0x06141714),
                          blurRadius: 18,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Container(
                      // Inner Core
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF202020) : Colors.white,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              runSpacing: 8,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF005E54)
                                        .withValues(alpha: isDark ? 0.28 : 0.08),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: const Color(0xFF005E54)
                                          .withValues(alpha: isDark ? 0.45 : 0.18),
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      AthenaSymbol(
                                        size: 13,
                                        color: isDark
                                            ? const Color(0xFF2DD4BF)
                                            : const Color(0xFF005E54),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'EDITORIAL COMPANION',
                                        style: TextStyle(
                                          fontFamily: AppTheme.fontUI,
                                          color: isDark
                                              ? const Color(0xFF2DD4BF)
                                              : const Color(0xFF005E54),
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.8,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Read the whole book.\nNever read alone.',
                            style: TextStyle(
                              fontFamily: AppTheme.fontDisplay,
                              color: isDark ? const Color(0xFFF3F3F3) : AppTheme.ink,
                              fontSize: 32,
                              fontWeight: FontWeight.w400,
                              height: 1.14,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Full original text, with quiet context between the paragraphs.',
                            style: TextStyle(
                              fontFamily: AppTheme.fontReading,
                              color: isDark ? const Color(0xFFB0B0B0) : const Color(0xFF4A4F48),
                              fontSize: 14.5,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 20),
                          _EditorialPillButton(
                            label: _uploading ? 'Adding book…' : 'Add book',
                            icon: Icons.add_rounded,
                            isLoading: _uploading,
                            onPressed: _uploading ? null : _pickAndUpload,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // --- 3. Section Header & Quick Search Filter ---
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        'Your Library',
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          color: isDark ? const Color(0xFFF3F3F3) : AppTheme.ink,
                          fontSize: 22,
                          fontWeight: FontWeight.w400,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (documentCount != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF222222) : const Color(0xFFEFEFEA),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            '$documentCount ${documentCount == 1 ? 'BOOK' : 'BOOKS'}',
                            style: TextStyle(
                              fontFamily: AppTheme.fontUI,
                              color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Search Filter Input
                  Container(
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF202020) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE5E7DC),
                          width: 1.0),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Icon(Icons.search_rounded,
                            size: 18,
                            color: isDark ? const Color(0xFF757575) : AppTheme.textMuted),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            style: TextStyle(
                              fontFamily: AppTheme.fontUI,
                              fontSize: 13,
                              color: isDark ? const Color(0xFFF3F3F3) : AppTheme.ink,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Search books...',
                              hintStyle: TextStyle(
                                fontFamily: AppTheme.fontUI,
                                fontSize: 13,
                                color: isDark ? const Color(0xFF757575) : const Color(0xFF9E9E9E),
                              ),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onChanged: (val) {
                              setState(() =>
                                  _searchQuery = val.trim().toLowerCase());
                            },
                          ),
                        ),
                        if (_searchQuery.isNotEmpty)
                          IconButton(
                            icon: Icon(Icons.close_rounded,
                                size: 16,
                                color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // --- 4. Document List or Minimalist Dropzone ---
                  docsState.when(
                    data: (docs) {
                      if (docs.isEmpty) {
                        return _buildMinimalistDropZone();
                      }

                      final filteredDocs = _searchQuery.isEmpty
                          ? docs
                          : docs.where((d) {
                              final title =
                                  _humanizeTitle(d.title).toLowerCase();
                              final fn = d.filename.toLowerCase();
                              return title.contains(_searchQuery) ||
                                  fn.contains(_searchQuery);
                            }).toList();

                      if (filteredDocs.isEmpty) {
                        return Container(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          alignment: Alignment.center,
                          child: Column(
                            children: [
                              const AthenaAvatar(
                                expression: AthenaExpression.sleepy,
                                size: 44,
                                showBezel: true,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'No books match "$_searchQuery"',
                                style: const TextStyle(
                                  fontFamily: AppTheme.fontUI,
                                  color: AppTheme.textMuted,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        );
                      }

                      return Column(
                        children: filteredDocs
                            .map(
                              (doc) => Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: _DocumentTile(
                                  doc: doc,
                                  onTap: () => _openDocument(doc),
                                  onDelete: () => _deleteDocument(doc),
                                  onRetry: () => _retryDocument(doc),
                                ),
                              ),
                            )
                            .toList(),
                      );
                    },
                    loading: () => const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(
                        child: CircularProgressIndicator(
                          color: AppTheme.ink,
                          strokeWidth: 2,
                        ),
                      ),
                    ),
                    error: (err, _) => _ConnectionCard(
                      onRetry: () => ref.invalidate(documentsProvider),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMinimalistDropZone() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      // Outer shell (Double-Bezel)
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isDark ? const Color(0xFF282828) : const Color(0xFFE5E7DC),
          width: 1.0,
        ),
      ),
      child: Container(
        // Inner core
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 44),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF202020) : Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AthenaAvatar(
              expression: AthenaExpression.neutral,
              size: 58,
              isBreathing: true,
              showBezel: true,
            ),
            const SizedBox(height: 18),
            Text(
              'No books yet',
              style: TextStyle(
                fontFamily: AppTheme.fontDisplay,
                fontSize: 22,
                color: isDark ? const Color(0xFFF3F3F3) : AppTheme.ink,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Add a book or paper to start reading.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AppTheme.fontReading,
                fontSize: 13.5,
                color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 22),
            _EditorialPillButton(
              label: _uploading ? 'Adding…' : 'Add book',
              icon: Icons.upload_file_rounded,
              isLoading: _uploading,
              onPressed: _uploading ? null : _pickAndUpload,
            ),
          ],
        ),
      ),
    );
  }
}

/// High-end Button-in-Button CTA
class _EditorialPillButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool isLoading;

  const _EditorialPillButton({
    required this.label,
    required this.icon,
    this.onPressed,
    this.isLoading = false,
  });

  @override
  State<_EditorialPillButton> createState() => _EditorialPillButtonState();
}

class _EditorialPillButtonState extends State<_EditorialPillButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTapDown: widget.onPressed != null
          ? (_) => setState(() => _isPressed = true)
          : null,
      onTapUp: widget.onPressed != null
          ? (_) {
              setState(() => _isPressed = false);
              HapticFeedback.selectionClick();
              widget.onPressed!();
            }
          : null,
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
          decoration: BoxDecoration(
            color: widget.onPressed != null
                ? (isDark ? Colors.white : const Color(0xFF141714))
                : const Color(0xFF666666),
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black38 : const Color(0x24141714),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  color: isDark ? const Color(0xFF141714) : Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(width: 10),
              // Nested Button-in-Button circle
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF141714).withValues(alpha: 0.14)
                      : Colors.white.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: widget.isLoading
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: isDark ? const Color(0xFF141714) : Colors.white,
                          ),
                        )
                      : Icon(
                          widget.icon,
                          size: 16,
                          color: isDark ? const Color(0xFF141714) : Colors.white,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _humanizeTitle(String raw) {
  var title = raw.trim();
  title = title.replaceAll(RegExp(r'\.(pdf|epub)$', caseSensitive: false), '');
  title = title.replaceAll(
      RegExp(r'[\s_\-]+(?:\(?\d+\)?|EnglishPDF)\s*$', caseSensitive: false),
      '');
  title = title.replaceAll(RegExp(r'\s*\(\d+\)\s*$'), '');
  title =
      title.replaceAll(RegExp(r'[_]+'), ' ').replaceAll(RegExp(r'[\-]+'), ' ');
  title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (title.isEmpty) return 'Untitled Document';

  final isAllUpper =
      title == title.toUpperCase() && title.contains(RegExp(r'[A-Z]'));
  if (isAllUpper) {
    const minorWords = {
      'a',
      'an',
      'the',
      'and',
      'but',
      'or',
      'for',
      'nor',
      'on',
      'at',
      'to',
      'from',
      'by',
      'of',
      'in',
      'with'
    };
    final words = title.split(' ');
    final converted = <String>[];
    for (int i = 0; i < words.length; i++) {
      final w = words[i].toLowerCase();
      if (w.isEmpty) continue;
      if (i == 0 || !minorWords.contains(w)) {
        converted
            .add(w[0].toUpperCase() + (w.length > 1 ? w.substring(1) : ''));
      } else {
        converted.add(w);
      }
    }
    return converted.join(' ');
  }
  return title;
}

class _ConnectionCard extends StatelessWidget {
  final VoidCallback onRetry;

  const _ConnectionCard({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: isDark ? const Color(0xFF282828) : const Color(0xFFE5E7DC)),
      ),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF202020) : Colors.white,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            const AthenaAnimatedMascot(
              size: 38,
              isPulsing: true,
              style: AthenaTileStyle.blackPrimary,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Athena Daemon Offline",
                    style: TextStyle(
                      fontFamily: AppTheme.fontUI,
                      color: isDark ? const Color(0xFFF3F3F3) : AppTheme.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "Ensure backend daemon is running",
                    style: TextStyle(
                      fontFamily: AppTheme.fontUI,
                      color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: () async {
                    final nav = Navigator.of(context);
                    final changed = await nav.push<bool>(
                      MaterialPageRoute<bool>(
                        builder: (_) => const ConnectionSetupScreen(),
                      ),
                    );
                    if (changed == true) onRetry();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isDark ? Colors.white : AppTheme.ink,
                    side: BorderSide(
                      color: isDark ? const Color(0xFF444444) : AppTheme.border,
                    ),
                    minimumSize: const Size(58, 34),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: const Text('Setup',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: onRetry,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark ? Colors.white : AppTheme.ink,
                    foregroundColor:
                        isDark ? const Color(0xFF141714) : Colors.white,
                    minimumSize: const Size(58, 34),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: const Text('Retry',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DocumentTile extends StatefulWidget {
  final Document doc;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRetry;

  const _DocumentTile({
    required this.doc,
    required this.onTap,
    required this.onDelete,
    required this.onRetry,
  });

  @override
  State<_DocumentTile> createState() => _DocumentTileState();
}

class _DocumentTileState extends State<_DocumentTile> {
  int? _savedChunkIndex;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _loadReadingProgress();
  }

  Future<void> _loadReadingProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pos = prefs.getInt('reader_pos_${widget.doc.id}');
      if (mounted && pos != null) {
        setState(() => _savedChunkIndex = pos);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final cleanTitle = _humanizeTitle(doc.title);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      onTap: () {
        if (doc.isReady) {
          widget.onTap();
        } else {
          context.push('/processing/${doc.id}');
        }
      },
      onHighlightChanged: (val) {
        if (mounted) setState(() => _isPressed = val);
      },
      borderRadius: BorderRadius.circular(22),
      child: AnimatedScale(
        scale: _isPressed ? 0.985 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: Container(
          // Outer Shell (Double-Bezel nested architecture)
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isDark ? const Color(0xFF282828) : const Color(0xFFE5E7DC),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black26 : const Color(0x06141714),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Container(
            // Inner Core
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF202020) : Colors.white,
              borderRadius: BorderRadius.circular(19),
            ),
            child: Row(
              children: [
                if (!doc.isReady)
                  const AthenaAvatar(
                    expression: AthenaExpression.thinking,
                    size: 38,
                    isBreathing: true,
                    showBezel: true,
                  )
                else if (_savedChunkIndex != null && _savedChunkIndex! > 0)
                  const AthenaAvatar(
                    expression: AthenaExpression.focused,
                    size: 38,
                    showBezel: true,
                  )
                else
                  const AthenaLogoTile(
                    size: 44,
                    style: AthenaTileStyle.blackPrimary,
                    borderRadius: 12,
                  ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cleanTitle,
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          color: isDark ? const Color(0xFFF3F3F3) : AppTheme.textPrimary,
                          fontWeight: FontWeight.w400,
                          fontSize: 17.5,
                          letterSpacing: 0.1,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          _StatusChip(
                              status: doc.status, pageCount: doc.pageCount),
                          if (doc.isReady &&
                              _savedChunkIndex != null &&
                              _savedChunkIndex! > 0) ...[
                            const SizedBox(width: 8),
                            Text(
                              'Resumed at #${_savedChunkIndex! + 1}',
                              style: TextStyle(
                                fontFamily: AppTheme.fontUI,
                                color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF005E54),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ] else if (!doc.isReady) ...[
                            const SizedBox(width: 8),
                            Text(
                              '${doc.pageCount} ${doc.pageCount == 1 ? 'page' : 'pages'}',
                              style: TextStyle(
                                fontFamily: AppTheme.fontUI,
                                color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (doc.isProcessing) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: (doc.percent ?? 0).clamp(0, 100) / 100,
                            minHeight: 3.5,
                            backgroundColor: isDark ? const Color(0xFF333333) : const Color(0xFFEBEBEB),
                            valueColor: AlwaysStoppedAnimation<Color>(
                              isDark ? Colors.white : AppTheme.ink,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${doc.stageLabel ?? 'Processing'} · ${doc.percent ?? 0}%',
                          style: TextStyle(
                            fontFamily: AppTheme.fontUI,
                            color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ] else if (doc.isFailed && doc.errorMessage != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          doc.errorMessage!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: AppTheme.fontUI,
                            color: Colors.redAccent,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (doc.isFailed)
                  IconButton(
                    icon: const Icon(
                      Icons.refresh_rounded,
                      color: Colors.redAccent,
                      size: 20,
                    ),
                    tooltip: 'Retry',
                    onPressed: widget.onRetry,
                  ),
                if (doc.isReady) ...[
                  const SizedBox(width: 8),
                  // Button-in-Button "Read" CTA
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white : const Color(0xFF141714),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Read',
                          style: TextStyle(
                            fontFamily: AppTheme.fontUI,
                            color: isDark ? const Color(0xFF141714) : Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF141714).withValues(alpha: 0.12)
                                : Colors.white.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Icon(
                              Icons.arrow_forward_rounded,
                              size: 13,
                              color: isDark ? const Color(0xFF141714) : Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert_rounded,
                    color: isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted,
                    size: 18,
                  ),
                  color: isDark ? const Color(0xFF222222) : Colors.white,
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(color: isDark ? const Color(0xFF333333) : const Color(0xFFE5E7DC)),
                  ),
                  onSelected: (value) {
                    if (value == 'delete') widget.onDelete();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(
                            Icons.delete_outline_rounded,
                            color: Colors.redAccent,
                            size: 16,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Delete',
                            style: TextStyle(
                              fontFamily: AppTheme.fontUI,
                              color: Colors.redAccent,
                              fontWeight: FontWeight.w500,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  final int? pageCount;
  const _StatusChip({required this.status, this.pageCount});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Color bgColor;
    Color textColor;
    String label;

    switch (status) {
      case 'ready':
        bgColor = isDark
            ? const Color(0xFF005E54).withValues(alpha: 0.25)
            : const Color(0xFFF2F4EB);
        textColor = isDark ? const Color(0xFF2DD4BF) : const Color(0xFF005E54);
        final pagesStr = pageCount != null
            ? ' · $pageCount ${pageCount == 1 ? 'PAGE' : 'PAGES'}'
            : '';
        label = 'READY$pagesStr';
        break;
      case 'failed':
        bgColor = Colors.redAccent.withValues(alpha: isDark ? 0.20 : 0.10);
        textColor = isDark ? const Color(0xFFFF6B6B) : Colors.redAccent;
        label = 'FAILED';
        break;
      case 'processing':
        bgColor = isDark
            ? Colors.white.withValues(alpha: 0.12)
            : const Color(0xFF141714).withValues(alpha: 0.07);
        textColor = isDark ? const Color(0xFFF3F3F3) : AppTheme.ink;
        label = 'PROCESSING';
        break;
      case 'unsupported':
        bgColor = isDark ? const Color(0xFF282828) : const Color(0xFFF7F7F7);
        textColor = isDark ? const Color(0xFFAAAAAA) : const Color(0xFF888888);
        label = 'OUT OF SCOPE';
        break;
      default:
        bgColor = isDark ? const Color(0xFF252525) : const Color(0xFFF4F4F4);
        textColor = isDark ? const Color(0xFF9E9E9E) : AppTheme.textMuted;
        label = 'QUEUED';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: AppTheme.fontUI,
          color: textColor,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
