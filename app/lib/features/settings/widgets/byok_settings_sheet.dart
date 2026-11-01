import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:athena/core/config/config.dart';
import 'package:athena/core/config/update_service.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/models/ai_provider.dart';
import 'package:athena/core/api/api_client.dart';
import 'package:athena/core/widgets/athena_avatar.dart';

class BYOKSettingsSheet extends StatefulWidget {
  final ApiClient? apiClient;
  final VoidCallback? onConfigSaved;

  const BYOKSettingsSheet({
    super.key,
    this.apiClient,
    this.onConfigSaved,
  });

  static Future<void> show(
    BuildContext context, {
    ApiClient? apiClient,
    VoidCallback? onConfigSaved,
  }) {
    return showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => BYOKSettingsSheet(
        apiClient: apiClient,
        onConfigSaved: onConfigSaved,
      ),
    );
  }

  @override
  State<BYOKSettingsSheet> createState() => _BYOKSettingsSheetState();
}

class _BYOKSettingsSheetState extends State<BYOKSettingsSheet> {
  late final ApiClient _api;
  int _activeSegment = 0; // 0 = AI Key, 1 = Server Host

  bool _loading = true;
  bool _saving = false;

  // Primary Provider State (Defaults to Google Gemini gemini-2.5-flash)
  String _primaryProvider = 'gemini';
  final _primaryKeyController = TextEditingController();
  final _primaryModelController =
      TextEditingController(text: 'gemini-2.5-flash');
  final _primaryBaseUrlController = TextEditingController();
  bool _obscurePrimaryKey = true;
  List<AIModelOption> _primaryModels = [];
  bool _fetchingPrimaryModels = false;
  bool _testingPrimary = false;
  String? _primaryTestMessage;
  bool? _primaryTestOk;

  // Fallback Provider State
  bool _enableFallback = false;
  String _fallbackProvider = 'groq';
  final _fallbackKeyController = TextEditingController();
  final _fallbackModelController =
      TextEditingController(text: 'llama-3.3-70b-versatile');
  final _fallbackBaseUrlController = TextEditingController();
  bool _obscureFallbackKey = true;
  List<AIModelOption> _fallbackModels = [];
  bool _fetchingFallbackModels = false;
  bool _testingFallback = false;
  String? _fallbackTestMessage;
  bool? _fallbackTestOk;

  // Server Host State
  final _serverUrlController = TextEditingController();
  bool _testingServer = false;
  String? _serverTestMessage;
  bool? _serverTestOk;

  // App Updates State
  bool _checkingUpdates = false;
  UpdateInfo? _settingsUpdateInfo;
  String? _updateStatusMessage;

  UpdateInfo get _fallbackSettingsUpdateInfo => UpdateInfo(
        updateAvailable: false,
        currentVersion: kAthenaAppVersion,
        latestVersion: kAthenaAppVersion,
        releaseNotes:
            'Improved Per-Page Document Bouncer, 4-Archetype Marginalia Cards, and Mobile Touch Ergonomics.',
        publishedAt: '2026-11-01',
        android: const UpdatePlatformArtifact(
          filename: 'athena-release.apk',
          downloadUrl: '/api/download/android',
          githubReleaseUrl:
              'https://github.com/praveene3127/Athena/raw/main/releases/athena-release.apk',
        ),
        ios: const UpdatePlatformArtifact(
          filename: 'athena-ios-release.ipa',
          downloadUrl: '/api/download/ios',
          githubReleaseUrl:
              'https://github.com/praveene3127/Athena/raw/main/releases/athena-ios-release.ipa',
          altstoreUrl:
              'altstore://install?url=https://github.com/praveene3127/Athena/raw/main/releases/athena-ios-release.ipa',
        ),
      );

  Future<void> _checkSettingsUpdates() async {
    setState(() {
      _checkingUpdates = true;
      _updateStatusMessage = null;
    });

    try {
      final info = await _api.checkAppUpdate(
        currentVersion: kAthenaAppVersion,
        platform: detectDevicePlatform(),
      );

      if (!mounted) return;

      if (info != null) {
        setState(() {
          _settingsUpdateInfo = UpdateInfo.fromJson(info);
          _checkingUpdates = false;
          _updateStatusMessage = _settingsUpdateInfo!.updateAvailable
              ? 'New version ${_settingsUpdateInfo!.latestVersion} available!'
              : 'You are on the latest version ($kAthenaAppVersion).';
        });
      } else {
        setState(() {
          _settingsUpdateInfo = _fallbackSettingsUpdateInfo;
          _checkingUpdates = false;
          _updateStatusMessage =
              'You are running version $kAthenaAppVersion (up to date).';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _settingsUpdateInfo = _fallbackSettingsUpdateInfo;
        _checkingUpdates = false;
        _updateStatusMessage =
            'Running $kAthenaAppVersion (could not query remote update feed).';
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _api = widget.apiClient ?? ApiClient();
    _serverUrlController.text = AppConfig.apiBaseUrl;
    _loadCurrentConfig();
  }

  @override
  void dispose() {
    _primaryKeyController.dispose();
    _primaryModelController.dispose();
    _primaryBaseUrlController.dispose();
    _fallbackKeyController.dispose();
    _fallbackModelController.dispose();
    _fallbackBaseUrlController.dispose();
    _serverUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentConfig() async {
    try {
      final config = await _api.getAIConfig();
      final prefs = await SharedPreferences.getInstance();

      final savedLocalPrimaryProvider =
          prefs.getString('athena_ai_primary_provider');
      final savedLocalPrimaryKey =
          prefs.getString('athena_ai_primary_api_key');
      final savedLocalPrimaryModel =
          prefs.getString('athena_ai_primary_model');
      final savedLocalPrimaryBaseUrl =
          prefs.getString('athena_ai_primary_base_url');

      final savedLocalFallbackProvider =
          prefs.getString('athena_ai_fallback_provider');
      final savedLocalFallbackKey =
          prefs.getString('athena_ai_fallback_api_key');
      final savedLocalFallbackModel =
          prefs.getString('athena_ai_fallback_model');
      final savedLocalFallbackBaseUrl =
          prefs.getString('athena_ai_fallback_base_url');

      setState(() {
        _primaryProvider = config.primaryProvider.isNotEmpty
            ? config.primaryProvider
            : (savedLocalPrimaryProvider ?? 'gemini');

        final loadedModel = config.primaryModel.isNotEmpty
            ? config.primaryModel
            : (savedLocalPrimaryModel ?? '');
        _primaryModelController.text = loadedModel.isNotEmpty
            ? loadedModel
            : (_primaryProvider == 'gemini' ? 'gemini-2.5-flash' : '');

        _primaryBaseUrlController.text =
            config.primaryBaseUrl ?? (savedLocalPrimaryBaseUrl ?? '');

        if (savedLocalPrimaryKey != null && savedLocalPrimaryKey.isNotEmpty) {
          _primaryKeyController.text = savedLocalPrimaryKey;
        } else if (config.primaryApiKeyMasked != null) {
          _primaryKeyController.text = config.primaryApiKeyMasked!;
        }

        if (config.fallbackProvider != null ||
            (savedLocalFallbackProvider != null &&
                savedLocalFallbackProvider.isNotEmpty)) {
          _enableFallback = true;
          _fallbackProvider = config.fallbackProvider ??
              (savedLocalFallbackProvider ?? 'groq');
          _fallbackModelController.text =
              config.fallbackModel ?? (savedLocalFallbackModel ?? '');
          _fallbackBaseUrlController.text =
              config.fallbackBaseUrl ?? (savedLocalFallbackBaseUrl ?? '');
          if (savedLocalFallbackKey != null &&
              savedLocalFallbackKey.isNotEmpty) {
            _fallbackKeyController.text = savedLocalFallbackKey;
          } else if (config.fallbackApiKeyMasked != null) {
            _fallbackKeyController.text = config.fallbackApiKeyMasked!;
          }
        }
        _loading = false;
      });

      if (!config.isConfigured &&
          savedLocalPrimaryKey != null &&
          savedLocalPrimaryKey.isNotEmpty) {
        _persistToLocalStorageAndBackend();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  Future<List<AIModelOption>> _fetchModels({required bool isPrimary}) async {
    final provider = isPrimary ? _primaryProvider : _fallbackProvider;
    final key = isPrimary
        ? _primaryKeyController.text.trim()
        : _fallbackKeyController.text.trim();
    final baseUrl = isPrimary
        ? (_primaryBaseUrlController.text.trim().isNotEmpty
            ? _primaryBaseUrlController.text.trim()
            : null)
        : (_fallbackBaseUrlController.text.trim().isNotEmpty
            ? _fallbackBaseUrlController.text.trim()
            : null);

    if (provider != 'custom' && key.isEmpty) {
      setState(() {
        if (isPrimary) {
          _primaryModels = [];
          _fetchingPrimaryModels = false;
        } else {
          _fallbackModels = [];
          _fetchingFallbackModels = false;
        }
      });
      return [];
    }

    setState(() {
      if (isPrimary) {
        _fetchingPrimaryModels = true;
      } else {
        _fetchingFallbackModels = true;
      }
    });

    try {
      final models = await _api.fetchModels(
        provider: provider,
        apiKey: key.isNotEmpty ? key : null,
        baseUrl: baseUrl,
      );

      if (!mounted) return models;
      setState(() {
        if (isPrimary) {
          _primaryModels = models;
          _fetchingPrimaryModels = false;
          if (_primaryModelController.text.isEmpty && models.isNotEmpty) {
            _primaryModelController.text = models.first.id;
          }
        } else {
          _fallbackModels = models;
          _fetchingFallbackModels = false;
          if (_fallbackModelController.text.isEmpty && models.isNotEmpty) {
            _fallbackModelController.text = models.first.id;
          }
        }
      });
      return models;
    } catch (_) {
      if (!mounted) return [];
      setState(() {
        if (isPrimary) {
          _fetchingPrimaryModels = false;
          _primaryModels = [];
        } else {
          _fetchingFallbackModels = false;
          _fallbackModels = [];
        }
      });
      return [];
    }
  }

  Future<void> _testConnection({required bool isPrimary}) async {
    final provider = isPrimary ? _primaryProvider : _fallbackProvider;
    final key = isPrimary
        ? _primaryKeyController.text.trim()
        : _fallbackKeyController.text.trim();
    final model = isPrimary
        ? _primaryModelController.text.trim()
        : _fallbackModelController.text.trim();
    final baseUrl = isPrimary
        ? (_primaryBaseUrlController.text.trim().isNotEmpty
            ? _primaryBaseUrlController.text.trim()
            : null)
        : (_fallbackBaseUrlController.text.trim().isNotEmpty
            ? _fallbackBaseUrlController.text.trim()
            : null);

    if (provider != 'custom' && key.isEmpty) {
      setState(() {
        if (isPrimary) {
          _primaryTestOk = false;
          _primaryTestMessage = 'Please enter an API key first.';
        } else {
          _fallbackTestOk = false;
          _fallbackTestMessage = 'Please enter a backup API key first.';
        }
      });
      return;
    }

    setState(() {
      if (isPrimary) {
        _testingPrimary = true;
        _primaryTestMessage = null;
        _primaryTestOk = null;
      } else {
        _testingFallback = true;
        _fallbackTestMessage = null;
        _fallbackTestOk = null;
      }
    });

    try {
      final res = await _api.testAIConnection(
        provider: provider,
        apiKey: key.isNotEmpty ? key : null,
        model: model.isNotEmpty ? model : null,
        baseUrl: baseUrl,
      );

      final ok = res['status'] == 'ok';
      final msg = res['message'] as String? ??
          (ok ? 'Connected successfully!' : 'Connection test failed.');

      if (!mounted) return;
      setState(() {
        if (isPrimary) {
          _testingPrimary = false;
          _primaryTestOk = ok;
          _primaryTestMessage = msg;
        } else {
          _testingFallback = false;
          _fallbackTestOk = ok;
          _fallbackTestMessage = msg;
        }
      });

      if (ok) {
        _fetchModels(isPrimary: isPrimary);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (isPrimary) {
          _testingPrimary = false;
          _primaryTestOk = false;
          _primaryTestMessage = 'Connection error: $e';
        } else {
          _testingFallback = false;
          _fallbackTestOk = false;
          _fallbackTestMessage = 'Connection error: $e';
        }
      });
    }
  }

  Future<void> _testServerConnection() async {
    final raw = _serverUrlController.text.trim();
    final sanitized = raw.isEmpty ? AppConfig.apiBaseUrl : raw;

    setState(() {
      _testingServer = true;
      _serverTestMessage = null;
      _serverTestOk = null;
    });

    final sw = Stopwatch()..start();
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
          headers: {'Accept': 'application/json'},
        ),
      );

      final targetUrl = sanitized.endsWith('/')
          ? '${sanitized}api/health'
          : '$sanitized/api/health';

      final response = await dio.get(targetUrl);
      sw.stop();

      if (!mounted) return;

      if (response.statusCode == 200) {
        setState(() {
          _testingServer = false;
          _serverTestOk = true;
          _serverTestMessage =
              'Connected (${sw.elapsedMilliseconds}ms) — Server live at $sanitized';
        });
        widget.onConfigSaved?.call();
      } else {
        setState(() {
          _testingServer = false;
          _serverTestOk = false;
          _serverTestMessage =
              'Server responded with HTTP ${response.statusCode}. Expected 200 OK.';
        });
      }
    } catch (e) {
      sw.stop();
      if (!mounted) return;
      setState(() {
        _testingServer = false;
        _serverTestOk = false;
        _serverTestMessage =
            "Connection failed. Ensure Athena is running and reachable on your phone's network.";
      });
    }
  }

  Future<void> _persistToLocalStorageAndBackend() async {
    final prefs = await SharedPreferences.getInstance();

    final primaryKey = _primaryKeyController.text.trim();
    if (primaryKey.isNotEmpty && !primaryKey.contains('...')) {
      await prefs.setString('athena_ai_primary_api_key', primaryKey);
    }
    await prefs.setString('athena_ai_primary_provider', _primaryProvider);
    if (_primaryModelController.text.trim().isNotEmpty) {
      await prefs.setString(
          'athena_ai_primary_model', _primaryModelController.text.trim());
    }
    if (_primaryBaseUrlController.text.trim().isNotEmpty) {
      await prefs.setString(
          'athena_ai_primary_base_url', _primaryBaseUrlController.text.trim());
    }

    if (_enableFallback) {
      final fallbackKey = _fallbackKeyController.text.trim();
      if (fallbackKey.isNotEmpty && !fallbackKey.contains('...')) {
        await prefs.setString('athena_ai_fallback_api_key', fallbackKey);
      }
      await prefs.setString('athena_ai_fallback_provider', _fallbackProvider);
      if (_fallbackModelController.text.trim().isNotEmpty) {
        await prefs.setString(
            'athena_ai_fallback_model', _fallbackModelController.text.trim());
      }
      if (_fallbackBaseUrlController.text.trim().isNotEmpty) {
        await prefs.setString('athena_ai_fallback_base_url',
            _fallbackBaseUrlController.text.trim());
      }
    }

    final keyToSend = (primaryKey.isNotEmpty && !primaryKey.contains('...'))
        ? primaryKey
        : prefs.getString('athena_ai_primary_api_key');

    final fallbackKeyToSend = _enableFallback
        ? ((_fallbackKeyController.text.trim().isNotEmpty &&
                !_fallbackKeyController.text.contains('...'))
            ? _fallbackKeyController.text.trim()
            : prefs.getString('athena_ai_fallback_api_key'))
        : null;

    await AppConfig.setBaseUrl(_serverUrlController.text.trim());

    await _api.saveAIConfig(
      primaryProvider: _primaryProvider,
      primaryApiKey: keyToSend,
      primaryModel: _primaryModelController.text.trim().isNotEmpty
          ? _primaryModelController.text.trim()
          : null,
      primaryBaseUrl: _primaryBaseUrlController.text.trim().isNotEmpty
          ? _primaryBaseUrlController.text.trim()
          : null,
      fallbackProvider: _enableFallback ? _fallbackProvider : null,
      fallbackApiKey: fallbackKeyToSend,
      fallbackModel:
          _enableFallback && _fallbackModelController.text.trim().isNotEmpty
              ? _fallbackModelController.text.trim()
              : null,
      fallbackBaseUrl:
          _enableFallback && _fallbackBaseUrlController.text.trim().isNotEmpty
              ? _fallbackBaseUrlController.text.trim()
              : null,
    );
  }

  Future<void> _saveConfig() async {
    setState(() => _saving = true);

    try {
      await _persistToLocalStorageAndBackend();

      if (!mounted) return;
      setState(() => _saving = false);

      widget.onConfigSaved?.call();
      Navigator.of(context).pop();

      if (_enableFallback && _fallbackKeyController.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Saved! Athena is active with your primary key. (Note: Backup failover is standby until a secondary key is set).'),
            backgroundColor: Color(0xFFB45309),
            duration: Duration(seconds: 4),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('AI Intelligence Engines updated and saved successfully.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save configuration: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _showModelPicker({required bool isPrimary}) {
    final models = isPrimary ? _primaryModels : _fallbackModels;
    final controller =
        isPrimary ? _primaryModelController : _fallbackModelController;
    final provider = isPrimary ? _primaryProvider : _fallbackProvider;
    final key = isPrimary
        ? _primaryKeyController.text.trim()
        : _fallbackKeyController.text.trim();

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _ModelSelectionModal(
          models: models,
          currentModel: controller.text,
          provider: provider,
          hasKey: key.isNotEmpty,
          onRefresh:
              key.isNotEmpty ? () => _fetchModels(isPrimary: isPrimary) : null,
          onModelSelected: (selectedId) {
            setState(() {
              controller.text = selectedId;
            });
            Navigator.of(ctx).pop();
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = (screenHeight * 0.88).clamp(320.0, screenHeight);

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      margin: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF181818) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(
          color: isDark ? const Color(0xFF282828) : AppTheme.border,
          width: 1.5,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x18000000),
            blurRadius: 28,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: _loading
            ? SizedBox(
                height: 260,
                child: Center(
                  child: CircularProgressIndicator(
                    color: isDark ? Colors.white : AppTheme.ink,
                  ),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCompactHeader(isDark),
                  Divider(
                    height: 1,
                    color: isDark ? const Color(0xFF282828) : AppTheme.hairline,
                  ),
                  _buildSegmentedToggle(isDark),
                  Flexible(
                    child: SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: EdgeInsets.fromLTRB(
                        16,
                        10,
                        16,
                        bottomInset > 0 ? bottomInset + 16 : 24,
                      ),
                      child: _activeSegment == 0
                          ? _buildAIKeyTab(isDark)
                          : _buildServerTab(isDark),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildCompactHeader(bool isDark) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const AthenaAvatar(
            expression: AthenaExpression.happy,
            size: 24,
            showBezel: true,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'AI & Server Settings',
              style: TextStyle(
                fontFamily: AppTheme.fontDisplay,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : AppTheme.ink,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.close_rounded,
              size: 20,
              color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
            ),
            onPressed: () => Navigator.of(context).pop(),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentedToggle(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Container(
        height: 38,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF222222) : const Color(0xFFEEEEEE),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: _buildSegmentButton(
                index: 0,
                label: 'AI Key',
                icon: Icons.key_rounded,
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: _buildSegmentButton(
                index: 1,
                label: 'Server Host',
                icon: Icons.dns_rounded,
                isDark: isDark,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSegmentButton({
    required int index,
    required String label,
    required IconData icon,
    required bool isDark,
  }) {
    final isSelected = _activeSegment == index;
    return GestureDetector(
      onTap: () => setState(() => _activeSegment = index),
      behavior: HitTestBehavior.opaque,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? const Color(0xFF333333) : Colors.white)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: isSelected
              ? const [
                  BoxShadow(
                    color: Color(0x0C000000),
                    blurRadius: 4,
                    offset: Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected
                  ? (isDark ? Colors.white : AppTheme.ink)
                  : (isDark ? AppTheme.darkTextMuted : AppTheme.textMuted),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: AppTheme.fontUI,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? (isDark ? Colors.white : AppTheme.ink)
                    : (isDark ? AppTheme.darkTextMuted : AppTheme.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAIKeyTab(bool isDark) {
    final info = kSupportedProviders.firstWhere(
      (p) => p.id == _primaryProvider,
      orElse: () => kSupportedProviders.first,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('AI PROVIDER'),
        const SizedBox(height: 6),
        _buildProviderDropdown(
          value: _primaryProvider,
          isDark: isDark,
          onChanged: (val) {
            if (val != null) {
              setState(() {
                _primaryProvider = val;
                if (val == 'gemini') {
                  _primaryModelController.text = 'gemini-2.5-flash';
                } else if (val == 'groq') {
                  _primaryModelController.text = 'llama-3.3-70b-versatile';
                } else {
                  _primaryModelController.text = '';
                }
                _primaryTestMessage = null;
                _primaryTestOk = null;
                _primaryModels = [];
              });
            }
          },
        ),
        const SizedBox(height: 14),
        _buildApiKeyField(
          controller: _primaryKeyController,
          obscureText: _obscurePrimaryKey,
          onToggleObscure: () =>
              setState(() => _obscurePrimaryKey = !_obscurePrimaryKey),
          placeholder: info.keyPlaceholder,
          docUrl: info.docUrl,
          providerName: info.name,
          isDark: isDark,
          onChanged: (val) {
            if (_primaryTestOk != null || _primaryModels.isNotEmpty) {
              setState(() {
                _primaryTestOk = null;
                _primaryTestMessage = null;
                _primaryModels = [];
              });
            }
          },
        ),
        if (_primaryProvider == 'custom') ...[
          const SizedBox(height: 12),
          _buildBaseUrlField(_primaryBaseUrlController, isDark),
        ],
        const SizedBox(height: 14),
        _buildModelSelector(
          isPrimary: true,
          modelController: _primaryModelController,
          models: _primaryModels,
          isFetching: _fetchingPrimaryModels,
          isDark: isDark,
        ),
        const SizedBox(height: 14),
        _buildTestConnectionButton(
          isPrimary: true,
          testing: _testingPrimary,
          testOk: _primaryTestOk,
          testMessage: _primaryTestMessage,
          isDark: isDark,
        ),
        const SizedBox(height: 16),
        _buildFailoverAccordion(isDark),
        const SizedBox(height: 20),
        _buildActionButtons(isDark),
      ],
    );
  }

  Widget _buildProviderDropdown({
    required String value,
    required bool isDark,
    required ValueChanged<String?> onChanged,
  }) {
    final dropdownOptions = [
      {'id': 'gemini', 'label': 'Google Gemini (Recommended)'},
      {'id': 'openrouter', 'label': 'OpenRouter'},
      {'id': 'groq', 'label': 'Groq (Ultra-Fast)'},
      {'id': 'openai', 'label': 'OpenAI'},
      {'id': 'anthropic', 'label': 'Anthropic Claude'},
      {'id': 'nvidia', 'label': 'NVIDIA NIM'},
      {'id': 'deepseek', 'label': 'DeepSeek'},
      {'id': 'mistral', 'label': 'Mistral AI'},
      {'id': 'together', 'label': 'Together AI'},
      {'id': 'custom', 'label': 'Local Ollama / Custom'},
    ];

    // Ensure value exists in options
    final effectiveValue =
        dropdownOptions.any((opt) => opt['id'] == value) ? value : 'gemini';

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF222222) : AppTheme.surfaceWarm,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDark ? const Color(0xFF383838) : AppTheme.border,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: effectiveValue,
          isExpanded: true,
          dropdownColor: isDark ? const Color(0xFF222222) : Colors.white,
          borderRadius: BorderRadius.circular(6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          style: TextStyle(
            fontFamily: AppTheme.fontUI,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : AppTheme.ink,
          ),
          items: dropdownOptions.map((opt) {
            return DropdownMenuItem<String>(
              value: opt['id'],
              child: Text(opt['label']!),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildApiKeyField({
    required TextEditingController controller,
    required bool obscureText,
    required VoidCallback onToggleObscure,
    required String placeholder,
    required String docUrl,
    required String providerName,
    required bool isDark,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildSectionLabel('API KEY'),
            Text(
              'Get key: $docUrl',
              style: TextStyle(
                fontFamily: AppTheme.fontUI,
                fontSize: 10,
                color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF222222) : AppTheme.surfaceWarm,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isDark ? const Color(0xFF383838) : AppTheme.border,
            ),
          ),
          child: TextField(
            controller: controller,
            obscureText: obscureText,
            onChanged: onChanged,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: isDark ? Colors.white : AppTheme.ink,
            ),
            decoration: InputDecoration(
              hintText: placeholder,
              hintStyle: TextStyle(
                fontFamily: AppTheme.fontUI,
                fontSize: 12,
                color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
              ),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.content_paste_rounded, size: 18),
                    tooltip: 'Paste from clipboard',
                    onPressed: () async {
                      final data =
                          await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null &&
                          data!.text!.trim().isNotEmpty) {
                        controller.text = data.text!.trim();
                        onChanged(controller.text);
                      }
                    },
                  ),
                  IconButton(
                    icon: Icon(
                      obscureText
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 18,
                      color:
                          isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
                    ),
                    tooltip: obscureText ? 'Show key' : 'Hide key',
                    onPressed: onToggleObscure,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBaseUrlField(TextEditingController controller, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('CUSTOM BASE URL'),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF222222) : AppTheme.surfaceWarm,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isDark ? const Color(0xFF383838) : AppTheme.border,
            ),
          ),
          child: TextField(
            controller: controller,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: isDark ? Colors.white : AppTheme.ink,
            ),
            decoration: InputDecoration(
              hintText: 'http://localhost:11434/v1',
              hintStyle: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
              ),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildModelSelector({
    required bool isPrimary,
    required TextEditingController modelController,
    required List<AIModelOption> models,
    required bool isFetching,
    required bool isDark,
  }) {
    final currentVal = modelController.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildSectionLabel(isPrimary ? 'AI MODEL' : 'BACKUP MODEL'),
            if (isFetching)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: isDark ? Colors.white : AppTheme.ink,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => _showModelPicker(isPrimary: isPrimary),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF222222) : AppTheme.surfaceWarm,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isDark ? const Color(0xFF383838) : AppTheme.border,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    currentVal.isNotEmpty
                        ? currentVal
                        : (isPrimary ? 'gemini-2.5-flash' : 'Select model...'),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : AppTheme.ink,
                    ),
                  ),
                ),
                Icon(
                  Icons.unfold_more_rounded,
                  size: 18,
                  color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTestConnectionButton({
    required bool isPrimary,
    required bool testing,
    required bool? testOk,
    required String? testMessage,
    required bool isDark,
  }) {
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed:
              testing ? null : () => _testConnection(isPrimary: isPrimary),
          icon: testing
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: isDark ? Colors.white : AppTheme.ink,
                  ),
                )
              : const Icon(Icons.flash_on_rounded, size: 16),
          label: Text(testing ? 'Testing...' : 'Test Connection'),
          style: OutlinedButton.styleFrom(
            foregroundColor: isDark ? Colors.white : AppTheme.ink,
            side: BorderSide(
              color: isDark ? const Color(0xFF444444) : AppTheme.border,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            minimumSize: const Size(0, 38),
          ),
        ),
        const SizedBox(width: 10),
        if (testMessage != null)
          Expanded(
            child: Row(
              children: [
                if (testOk == true)
                  const AthenaAvatar(
                    expression: AthenaExpression.wink,
                    size: 18,
                  )
                else
                  const AthenaAvatar(
                    expression: AthenaExpression.surprised,
                    size: 18,
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    testMessage,
                    style: TextStyle(
                      fontFamily: AppTheme.fontUI,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: testOk == true
                          ? const Color(0xFF007A3D)
                          : Colors.redAccent,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildFailoverAccordion(bool isDark) {
    final info = kSupportedProviders.firstWhere(
      (p) => p.id == _fallbackProvider,
      orElse: () => kSupportedProviders.first,
    );

    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF9F9F8),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isDark ? const Color(0xFF2C2C2C) : AppTheme.border,
          ),
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          title: Text(
            'Failover Backup Engine (Optional)',
            style: TextStyle(
              fontFamily: AppTheme.fontUI,
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: isDark ? Colors.white : AppTheme.ink,
            ),
          ),
          subtitle: Text(
            _enableFallback
                ? 'Active failover: ${_fallbackProvider.toUpperCase()}'
                : 'Standby: Routes requests here if primary engine hits quota',
            style: TextStyle(
              fontFamily: AppTheme.fontUI,
              fontSize: 11,
              color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
            ),
          ),
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Enable Automatic Failover',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                Switch(
                  value: _enableFallback,
                  activeThumbColor: isDark ? Colors.white : AppTheme.ink,
                  onChanged: (val) {
                    setState(() {
                      _enableFallback = val;
                      if (!val) _fallbackModels = [];
                    });
                  },
                ),
              ],
            ),
            if (_enableFallback) ...[
              const SizedBox(height: 10),
              _buildSectionLabel('SELECT BACKUP PROVIDER'),
              const SizedBox(height: 6),
              _buildProviderDropdown(
                value: _fallbackProvider,
                isDark: isDark,
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _fallbackProvider = val;
                      _fallbackModelController.text = '';
                      _fallbackTestMessage = null;
                      _fallbackTestOk = null;
                      _fallbackModels = [];
                    });
                  }
                },
              ),
              const SizedBox(height: 12),
              _buildApiKeyField(
                controller: _fallbackKeyController,
                obscureText: _obscureFallbackKey,
                onToggleObscure: () => setState(
                    () => _obscureFallbackKey = !_obscureFallbackKey),
                placeholder: info.keyPlaceholder,
                docUrl: info.docUrl,
                providerName: info.name,
                isDark: isDark,
                onChanged: (val) {
                  if (_fallbackTestOk != null || _fallbackModels.isNotEmpty) {
                    setState(() {
                      _fallbackTestOk = null;
                      _fallbackTestMessage = null;
                      _fallbackModels = [];
                    });
                  }
                },
              ),
              if (_fallbackProvider == 'custom') ...[
                const SizedBox(height: 12),
                _buildBaseUrlField(_fallbackBaseUrlController, isDark),
              ],
              const SizedBox(height: 12),
              _buildModelSelector(
                isPrimary: false,
                modelController: _fallbackModelController,
                models: _fallbackModels,
                isFetching: _fetchingFallbackModels,
                isDark: isDark,
              ),
              const SizedBox(height: 12),
              _buildTestConnectionButton(
                isPrimary: false,
                testing: _testingFallback,
                testOk: _fallbackTestOk,
                testMessage: _fallbackTestMessage,
                isDark: isDark,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(bool isDark) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: isDark ? Colors.white70 : AppTheme.textMuted,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: _saving ? null : _saveConfig,
          style: ElevatedButton.styleFrom(
            backgroundColor: isDark ? Colors.white : AppTheme.ink,
            foregroundColor: isDark ? Colors.black : Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text(
                  'Save & Apply',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
        ),
      ],
    );
  }

  Widget _buildServerTab(bool isDark) {
    final currentResolved = AppConfig.apiBaseUrl;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('BACKEND SERVER URL'),
        const SizedBox(height: 6),
        Text(
          kIsWeb
              ? 'Web defaults to this page origin ($currentResolved). Change only if backend is on a separate machine.'
              : 'Native APK/IPA: laptop Wi-Fi IP (http://192.168.x.x:8000) or Cloudflare Tunnel URL.',
          style: TextStyle(
            fontFamily: AppTheme.fontUI,
            fontSize: 12,
            height: 1.4,
            color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF222222) : AppTheme.surfaceWarm,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isDark ? const Color(0xFF333333) : AppTheme.border,
            ),
          ),
          child: TextField(
            controller: _serverUrlController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: isDark ? Colors.white : AppTheme.ink,
            ),
            decoration: InputDecoration(
              hintText: 'http://192.168.1.5:8000',
              hintStyle: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
              ),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.content_paste_rounded, size: 18),
                    tooltip: 'Paste from clipboard',
                    onPressed: () async {
                      final data =
                          await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null &&
                          data!.text!.trim().isNotEmpty) {
                        _serverUrlController.text = data.text!.trim();
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () => _serverUrlController.clear(),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildSectionLabel('QUICK PRESETS'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (kIsWeb)
              _buildPresetChip('Web Origin', Uri.base.origin, isDark)
            else if (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS) ...[
              _buildPresetChip('Wi-Fi (:8000)', 'http://192.168.1.', isDark),
              _buildPresetChip(
                  'Android Emulator', 'http://10.0.2.2:8000', isDark),
              _buildPresetChip(
                  'USB Tether (:8000)', 'http://127.0.0.1:8000', isDark),
            ] else ...[
              _buildPresetChip(
                  'Localhost (:8000)', 'http://127.0.0.1:8000', isDark),
              _buildPresetChip(
                  'Alt Port (:8080)', 'http://127.0.0.1:8080', isDark),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _testingServer ? null : _testServerConnection,
                icon: _testingServer
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: isDark ? Colors.white : AppTheme.ink,
                        ),
                      )
                    : const Icon(Icons.bolt_rounded, size: 16),
                label: Text(_testingServer ? 'Pinging...' : 'Test Connection'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: isDark ? Colors.white : AppTheme.ink,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(
                    color: isDark ? const Color(0xFF444444) : AppTheme.border,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () async {
                  final raw = _serverUrlController.text.trim();
                  await AppConfig.setBaseUrl(raw);
                  widget.onConfigSaved?.call();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(raw.isEmpty
                          ? 'Server URL reset to automatic host detection.'
                          : 'Server URL saved: $raw'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                icon: const Icon(Icons.check_rounded, size: 16),
                label: const Text('Save Host'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? Colors.white : AppTheme.ink,
                  foregroundColor: isDark ? Colors.black : Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_serverTestMessage != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _serverTestOk == true
                  ? const Color(0x1A10B981)
                  : const Color(0x1AEF4444),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _serverTestOk == true
                    ? const Color(0xFF10B981)
                    : const Color(0xFFEF4444),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _serverTestOk == true
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  size: 18,
                  color: _serverTestOk == true
                      ? const Color(0xFF10B981)
                      : const Color(0xFFEF4444),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _serverTestMessage!,
                    style: TextStyle(
                      fontFamily: AppTheme.fontUI,
                      fontSize: 12,
                      color: _serverTestOk == true
                          ? const Color(0xFF10B981)
                          : const Color(0xFFEF4444),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        _buildAppVersionAndDownloadsCard(isDark),
        const SizedBox(height: 16),
        _buildMobileGuideCard(isDark),
      ],
    );
  }

  Widget _buildPresetChip(String label, String value, bool isDark) {
    return ActionChip(
      label: Text(
        label,
        style: TextStyle(
          fontFamily: AppTheme.fontUI,
          fontSize: 11,
          color: isDark ? Colors.white70 : AppTheme.ink,
        ),
      ),
      backgroundColor: isDark ? const Color(0xFF282828) : AppTheme.surfaceWarm,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
          color: isDark ? const Color(0xFF383838) : AppTheme.border,
        ),
      ),
      onPressed: () {
        setState(() {
          _serverUrlController.text = value;
          _serverTestMessage = null;
          _serverTestOk = null;
        });
      },
    );
  }

  Widget _buildAppVersionAndDownloadsCard(bool isDark) {
    final currentPlatform = detectDevicePlatform();
    final effectiveInfo = _settingsUpdateInfo ?? _fallbackSettingsUpdateInfo;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F1F1F) : const Color(0xFFF9F9F7),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDark ? const Color(0xFF2E2E2E) : AppTheme.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.system_update_rounded,
                size: 16,
                color: isDark ? Colors.white70 : AppTheme.ink,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Athena App Version: v$kAthenaAppVersion',
                  style: TextStyle(
                    fontFamily: AppTheme.fontUI,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : AppTheme.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _checkingUpdates ? null : _checkSettingsUpdates,
              icon: _checkingUpdates
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  : const Icon(Icons.sync_rounded, size: 14),
              label: Text(
                _checkingUpdates ? 'Checking...' : 'Check for Updates',
                style: const TextStyle(fontSize: 11),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: isDark ? Colors.white : AppTheme.ink,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          if (_updateStatusMessage != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _settingsUpdateInfo?.updateAvailable == true
                    ? const Color(0x15C84B31)
                    : (isDark
                        ? const Color(0xFF282828)
                        : const Color(0xFFEAE7E0)),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _settingsUpdateInfo?.updateAvailable == true
                      ? const Color(0xFFC84B31)
                      : (isDark
                          ? const Color(0xFF383838)
                          : const Color(0xFFDDD8CE)),
                ),
              ),
              child: Text(
                _updateStatusMessage!,
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: _settingsUpdateInfo?.updateAvailable == true
                      ? const Color(0xFFC84B31)
                      : (isDark ? Colors.white70 : AppTheme.ink),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: currentPlatform == 'android'
                    ? ElevatedButton.icon(
                        onPressed: () {
                          UpdateService.downloadPlatformUpdate(
                            updateInfo: effectiveInfo,
                            platform: 'android',
                          );
                        },
                        icon: const Icon(Icons.android_rounded, size: 15),
                        label: const Text(
                          'Android (.APK) ★',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF161615),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      )
                    : OutlinedButton.icon(
                        onPressed: () {
                          UpdateService.downloadPlatformUpdate(
                            updateInfo: effectiveInfo,
                            platform: 'android',
                          );
                        },
                        icon: const Icon(Icons.android_rounded, size: 15),
                        label: const Text(
                          'Android (.APK)',
                          style: TextStyle(fontSize: 11.5),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor:
                              isDark ? Colors.white : AppTheme.ink,
                          side: BorderSide(
                            color: isDark
                                ? const Color(0xFF444444)
                                : const Color(0xFFCCCCCC),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: currentPlatform == 'ios'
                    ? ElevatedButton.icon(
                        onPressed: () {
                          UpdateService.downloadPlatformUpdate(
                            updateInfo: effectiveInfo,
                            platform: 'ios',
                          );
                        },
                        icon: const Icon(Icons.apple_rounded, size: 15),
                        label: const Text(
                          'iOS (.IPA) ★',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF161615),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      )
                    : OutlinedButton.icon(
                        onPressed: () {
                          UpdateService.downloadPlatformUpdate(
                            updateInfo: effectiveInfo,
                            platform: 'ios',
                          );
                        },
                        icon: const Icon(Icons.apple_rounded, size: 15),
                        label: const Text(
                          'iOS (.IPA)',
                          style: TextStyle(fontSize: 11.5),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor:
                              isDark ? Colors.white : AppTheme.ink,
                          side: BorderSide(
                            color: isDark
                                ? const Color(0xFF444444)
                                : const Color(0xFFCCCCCC),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
              ),
            ],
          ),
          if (currentPlatform == 'ios') ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  UpdateService.downloadPlatformUpdate(
                    updateInfo: effectiveInfo,
                    platform: 'ios',
                    useAltStore: true,
                  );
                },
                icon: const Icon(Icons.install_mobile_rounded, size: 15),
                label: const Text(
                  'Open in AltStore / SideStore (1-Tap Install)',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFC84B31),
                  side: const BorderSide(color: Color(0xFFC84B31)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMobileGuideCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F1F1F) : const Color(0xFFF9F9F7),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDark ? const Color(0xFF2E2E2E) : AppTheme.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.phone_iphone_rounded,
                size: 16,
                color: isDark ? Colors.white70 : AppTheme.ink,
              ),
              const SizedBox(width: 8),
              Text(
                'Connecting your phone to Athena',
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : AppTheme.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '1. Ensure phone & Windows laptop are on the same Wi-Fi.\n'
            '2. Run "ipconfig" in PowerShell to find your IPv4 (e.g. 192.168.1.15).\n'
            '3. Set Server URL to http://<your-ipv4>:8000 and tap "Test Connection".\n'
            '4. Alternatively, use Cloudflare Tunnel (https://xxx.trycloudflare.com) to read anywhere over mobile 5G.',
            style: TextStyle(
              fontFamily: AppTheme.fontUI,
              fontSize: 11.5,
              height: 1.45,
              color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String label) {
    return Text(
      label,
      style: const TextStyle(
        fontFamily: AppTheme.fontUI,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
        color: AppTheme.textMuted,
      ),
    );
  }
}

class _ModelSelectionModal extends StatefulWidget {
  final List<AIModelOption> models;
  final String currentModel;
  final String provider;
  final bool hasKey;
  final ValueChanged<String> onModelSelected;
  final Future<List<AIModelOption>> Function()? onRefresh;

  const _ModelSelectionModal({
    required this.models,
    required this.currentModel,
    this.provider = '',
    this.hasKey = false,
    required this.onModelSelected,
    this.onRefresh,
  });

  @override
  State<_ModelSelectionModal> createState() => _ModelSelectionModalState();
}

class _ModelSelectionModalState extends State<_ModelSelectionModal> {
  final _searchController = TextEditingController();
  final _manualController = TextEditingController();
  late List<AIModelOption> _models;
  String _query = '';
  bool _customMode = false;
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    _models = List.from(widget.models);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _manualController.dispose();
    super.dispose();
  }

  Future<void> _handleRefresh() async {
    if (widget.onRefresh == null || _isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      final updated = await widget.onRefresh!();
      if (!mounted) return;
      setState(() {
        _models = updated;
        _isRefreshing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isRefreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _models.where((m) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return m.id.toLowerCase().contains(q) || m.name.toLowerCase().contains(q);
    }).toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Select Model',
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onRefresh != null &&
                        !_customMode &&
                        _models.isNotEmpty)
                      IconButton(
                        icon: _isRefreshing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: AppTheme.ink),
                              )
                            : const Icon(Icons.refresh_rounded,
                                size: 20, color: AppTheme.ink),
                        tooltip: 'Refresh Available Models',
                        onPressed: _handleRefresh,
                      ),
                    TextButton(
                      onPressed: () {
                        setState(() => _customMode = !_customMode);
                      },
                      child: Text(
                          _customMode ? 'Browse Catalog' : 'Enter Manually'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppTheme.hairline),
          if (_customMode)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Exact Model Slug',
                    style: TextStyle(
                      fontFamily: AppTheme.fontUI,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _manualController,
                    decoration: InputDecoration(
                      hintText: widget.currentModel.isNotEmpty
                          ? widget.currentModel
                          : 'e.g. meta-llama/llama-3.3-70b-instruct',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 14),
                  ElevatedButton(
                    onPressed: () {
                      if (_manualController.text.trim().isNotEmpty) {
                        widget.onModelSelected(_manualController.text.trim());
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: const Text('Use This Model'),
                  ),
                ],
              ),
            )
          else if (_models.isEmpty)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: const BoxDecoration(
                          color: AppTheme.surfaceWarm,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.vpn_key_outlined,
                          size: 32,
                          color: AppTheme.textMuted,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'No live models fetched',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.ink,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        widget.hasKey
                            ? 'Tap "Test Connection" on the settings sheet to verify your key and discover models.'
                            : 'Enter your API key and tap "Test Connection" to discover available models.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 12,
                          color: AppTheme.textMuted,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 18),
                      OutlinedButton(
                        onPressed: () {
                          setState(() => _customMode = true);
                        },
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        child: const Text('Enter Model Slug Manually'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                onChanged: (val) => setState(() => _query = val),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _isRefreshing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: Center(
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: AppTheme.ink),
                            ),
                          ),
                        )
                      : null,
                  hintText: 'Search ${_models.length} live models...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: AppTheme.border),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No models matching "$_query"',
                        style: const TextStyle(color: AppTheme.textMuted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (ctx, i) {
                        final m = filtered[i];
                        final isSelected = m.id == widget.currentModel;

                        return ListTile(
                          onTap: () => widget.onModelSelected(m.id),
                          title: Text(
                            m.name,
                            style: TextStyle(
                              fontFamily: AppTheme.fontUI,
                              fontWeight: isSelected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: isSelected
                                  ? AppTheme.ink
                                  : AppTheme.textPrimary,
                            ),
                          ),
                          subtitle: Text(
                            m.id,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: AppTheme.textMuted,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isSelected) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE0F2FE),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'CHOSEN',
                                    style: TextStyle(
                                      fontFamily: AppTheme.fontUI,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF0369A1),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              if (m.contextLength != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.surfaceWarm,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: AppTheme.border),
                                  ),
                                  child: Text(
                                    '${(m.contextLength! / 1024).round()}K ctx',
                                    style: const TextStyle(
                                      fontFamily: AppTheme.fontUI,
                                      fontSize: 10,
                                      color: AppTheme.textMuted,
                                    ),
                                  ),
                                ),
                              if (isSelected) ...[
                                const SizedBox(width: 8),
                                const Icon(Icons.check_rounded,
                                    color: AppTheme.ink, size: 20),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }
}
