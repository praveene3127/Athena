import 'package:dio/dio.dart';
import 'package:athena/core/config/config.dart';
import 'package:athena/core/api/lan_discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/models/ai_provider.dart';
import 'package:athena/core/api/api_client.dart';
import 'package:athena/core/widgets/athena_avatar.dart';

/// Pre-populated standard models for each provider so users can immediately
/// select their desired model from a clean dropdown without needing to test
/// connection or make network calls first.

class BYOKSettingsSheet extends StatefulWidget {
  final ApiClient? apiClient;
  final VoidCallback? onConfigSaved;
  final bool initialExpandServer;

  const BYOKSettingsSheet({
    super.key,
    this.apiClient,
    this.onConfigSaved,
    this.initialExpandServer = false,
  });

  static Future<void> show(
    BuildContext context, {
    ApiClient? apiClient,
    VoidCallback? onConfigSaved,
    bool initialExpandServer = false,
  }) {
    return showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => BYOKSettingsSheet(
        apiClient: apiClient,
        onConfigSaved: onConfigSaved,
        initialExpandServer: initialExpandServer,
      ),
    );
  }

  @override
  State<BYOKSettingsSheet> createState() => _BYOKSettingsSheetState();
}

class _BYOKSettingsSheetState extends State<BYOKSettingsSheet> {
  late final ApiClient _api;
  // Server Host State (Optional Collapsible)
  final _serverUrlController = TextEditingController();
  bool _testingServer = false;
  String? _serverTestMessage;
  bool? _serverTestOk;


  bool _loading = true;
  bool _saving = false;

  // Primary Provider State (Defaults to Google Gemini)
  String _primaryProvider = 'gemini';
  final _primaryKeyController = TextEditingController();
  final _primaryModelController = TextEditingController();
  List<String> _primaryDiscoveredModels = [];
  final _primaryBaseUrlController = TextEditingController();
  bool _obscurePrimaryKey = true;
  bool _testingPrimary = false;
  String? _primaryTestMessage;
  bool? _primaryTestOk;

  // Fallback Provider State
  bool _enableFallback = false;
  String _fallbackProvider = 'groq';
  final _fallbackKeyController = TextEditingController();
  final _fallbackModelController = TextEditingController();
  List<String> _fallbackDiscoveredModels = [];
  final _fallbackBaseUrlController = TextEditingController();
  bool _obscureFallbackKey = true;
  bool _testingFallback = false;
  String? _fallbackTestMessage;
  bool? _fallbackTestOk;



  @override
  void initState() {
    super.initState();
    _api = widget.apiClient ?? ApiClient();
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
        final currentServer = AppConfig.runtimeBaseUrl ??
            (AppConfig.apiBaseUrl.isNotEmpty
                ? AppConfig.apiBaseUrl
                : 'http://192.168.1.61:8000');
        _serverUrlController.text = currentServer;
        _primaryProvider = config.primaryProvider.isNotEmpty
            ? config.primaryProvider
            : (savedLocalPrimaryProvider ?? 'gemini');

        final loadedModel = config.primaryModel.isNotEmpty
            ? config.primaryModel
            : (savedLocalPrimaryModel ?? '');
        _primaryModelController.text = loadedModel;
        _primaryDiscoveredModels = [];

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
          final loadedFallback =
              config.fallbackModel ?? (savedLocalFallbackModel ?? '');
          _fallbackModelController.text = loadedFallback;
          _fallbackDiscoveredModels = [];
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


  Future<void> _testConnection({required bool isPrimary}) async {
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
          _primaryTestOk = false;
          _primaryTestMessage = 'Please enter an API key to test.';
        } else {
          _fallbackTestOk = false;
          _fallbackTestMessage = 'Please enter a backup API key to test.';
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
        model: isPrimary ? _primaryModelController.text.trim() : _fallbackModelController.text.trim(),
        baseUrl: baseUrl,
      );

      if (!mounted) return;

      final ok = res['ok'] as bool? ?? false;
      final msg = res['message'] as String? ?? (ok ? 'Connected successfully.' : 'Test failed.');
      final rawModels = res['models'] as List? ?? [];
      final discovered = rawModels
          .map((m) => m is Map ? (m['id'] ?? m['name'])?.toString() : m.toString())
          .where((s) => s != null && s.isNotEmpty)
          .cast<String>()
          .toList();

      setState(() {
        if (isPrimary) {
          _testingPrimary = false;
          _primaryTestOk = ok;
          _primaryTestMessage = msg;
          if (ok && discovered.isNotEmpty) {
            _primaryDiscoveredModels = discovered;
            if (_primaryModelController.text.isEmpty ||
                !discovered.contains(_primaryModelController.text)) {
              _primaryModelController.text = discovered.firstWhere(
                (m) => m.toLowerCase().contains('flash') || m.toLowerCase().contains('chat'),
                orElse: () => discovered.first,
              );
            }
          }
        } else {
          _testingFallback = false;
          _fallbackTestOk = ok;
          _fallbackTestMessage = msg;
          if (ok && discovered.isNotEmpty) {
            _fallbackDiscoveredModels = discovered;
            if (_fallbackModelController.text.isEmpty ||
                !discovered.contains(_fallbackModelController.text)) {
              _fallbackModelController.text = discovered.firstWhere(
                (m) => m.toLowerCase().contains('flash') || m.toLowerCase().contains('chat'),
                orElse: () => discovered.first,
              );
            }
          }
        }
      });
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

    final fallbackKeyToSend =
        (fallbackKeyControllerTrim.isNotEmpty && !fallbackKeyControllerTrim.contains('...'))
            ? fallbackKeyControllerTrim
            : prefs.getString('athena_ai_fallback_api_key');

    await _api.saveAIConfig(
      primaryProvider: _primaryProvider,
      primaryModel: _primaryModelController.text.trim().isNotEmpty
          ? _primaryModelController.text.trim()
          : null,
      primaryApiKey: keyToSend,
      primaryBaseUrl: _primaryBaseUrlController.text.trim().isNotEmpty
          ? _primaryBaseUrlController.text.trim()
          : null,
      fallbackProvider: _enableFallback ? _fallbackProvider : null,
      fallbackModel: _enableFallback && _fallbackModelController.text.trim().isNotEmpty
          ? _fallbackModelController.text.trim()
          : null,
      fallbackApiKey: _enableFallback ? fallbackKeyToSend : null,
      fallbackBaseUrl: _enableFallback && _fallbackBaseUrlController.text.trim().isNotEmpty
          ? _fallbackBaseUrlController.text.trim()
          : null,
    );
  }

  String get fallbackKeyControllerTrim => _fallbackKeyController.text.trim();

  Future<void> _saveConfig() async {
    setState(() => _saving = true);
    try {
      final sUrl = _serverUrlController.text.trim();
      if (sUrl.isNotEmpty) {
        await AppConfig.setBaseUrl(sUrl);
      }


      await _persistToLocalStorageAndBackend();

      if (!mounted) return;
      setState(() => _saving = false);
      widget.onConfigSaved?.call();
      Navigator.of(context).pop();

      final primaryKey = _primaryKeyController.text.trim();
      if (primaryKey.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No API key provided. Free offline Wikipedia & pre-cached cards will be used.',
            ),
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
                      child: _buildAIKeyTab(isDark),
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
              'AI Configuration',
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
            if (val != null && val != _primaryProvider) {
              setState(() {
                _primaryProvider = val;
                _primaryDiscoveredModels.clear();
                _primaryModelController.clear();
                _primaryTestMessage = null;
                _primaryTestOk = null;
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
            if (_primaryTestOk != null) {
              setState(() {
                _primaryTestOk = null;
                _primaryTestMessage = null;
              });
            }
          },
        ),
        if (_primaryProvider == 'custom') ...[
          const SizedBox(height: 12),
          _buildBaseUrlField(_primaryBaseUrlController, isDark),
        ],
        const SizedBox(height: 14),
        _buildModelDropdown(
          provider: _primaryProvider,
          controller: _primaryModelController,
          discoveredModels: _primaryDiscoveredModels,
          isDark: isDark,
          onChanged: (val) {
            if (val != null) {
              setState(() {
                _primaryModelController.text = val;
              });
            }
          },
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
        _buildServerAccordion(isDark),
        const SizedBox(height: 18),
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
      {'id': 'groq', 'label': 'Groq (Ultra-Fast)'},
      {'id': 'openrouter', 'label': 'OpenRouter'},
      {'id': 'openai', 'label': 'OpenAI'},
      {'id': 'anthropic', 'label': 'Anthropic Claude'},
      {'id': 'deepseek', 'label': 'DeepSeek'},
      {'id': 'mistral', 'label': 'Mistral AI'},
      {'id': 'nvidia', 'label': 'NVIDIA NIM'},
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

  Widget _buildModelDropdown({
    required String provider,
    required TextEditingController controller,
    required List<String> discoveredModels,
    required bool isDark,
    required ValueChanged<String?> onChanged,
  }) {
    final currentVal = controller.text.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('AI MODEL'),
        const SizedBox(height: 6),
        if (discoveredModels.isEmpty) ...[
          Container(
            width: double.infinity,
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
                Icon(
                  Icons.info_outline_rounded,
                  size: 15,
                  color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Enter API key and click "Test Connection" to fetch models',
                    style: TextStyle(
                      fontFamily: AppTheme.fontUI,
                      fontSize: 12,
                      color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          Builder(builder: (context) {
            final options = discoveredModels.toSet().toList();
            final effectiveValue =
                options.contains(currentVal) ? currentVal : options.first;

            if (controller.text != effectiveValue) {
              controller.text = effectiveValue;
            }

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
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : AppTheme.ink,
                  ),
                  items: options.map((opt) {
                    return DropdownMenuItem<String>(
                      value: opt,
                      child: Text(
                        opt,
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      controller.text = val;
                      onChanged(val);
                    }
                  },
                ),
              ),
            );
          }),
        ],
      ],
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
                  if (val != null && val != _fallbackProvider) {
                    setState(() {
                      _fallbackProvider = val;
                      _fallbackDiscoveredModels.clear();
                      _fallbackModelController.clear();
                      _fallbackTestMessage = null;
                      _fallbackTestOk = null;
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
                  if (_fallbackTestOk != null) {
                    setState(() {
                      _fallbackTestOk = null;
                      _fallbackTestMessage = null;
                    });
                  }
                },
              ),
              if (_fallbackProvider == 'custom') ...[
                const SizedBox(height: 12),
                _buildBaseUrlField(_fallbackBaseUrlController, isDark),
              ],
              const SizedBox(height: 12),
              _buildModelDropdown(
                provider: _fallbackProvider,
                controller: _fallbackModelController,
                discoveredModels: _fallbackDiscoveredModels,
                isDark: isDark,
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _fallbackModelController.text = val;
                    });
                  }
                },
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



  
  Future<void> _testServerConnection() async {
    final raw = _serverUrlController.text.trim();
    if (raw.isEmpty) return;

    setState(() {
      _testingServer = true;
      _serverTestMessage = null;
      _serverTestOk = null;
    });

    try {
      final sanitized = raw.replaceAll(RegExp(r'/+$'), '');
      final dioClient = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
      final res = await dioClient.get('$sanitized/api/health');
      if (res.statusCode == 200) {
        setState(() {
          _testingServer = false;
          _serverTestOk = true;
          _serverTestMessage = 'Server link active (HTTP 200 OK)';
        });
      } else {
        setState(() {
          _testingServer = false;
          _serverTestOk = false;
          _serverTestMessage = 'Server responded with HTTP ${res.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _testingServer = false;
        _serverTestOk = false;
        _serverTestMessage = 'Cannot connect: $e';
      });
    }
  }

  Widget _buildServerAccordion(bool isDark) {
    return Container(
      margin: const EdgeInsets.only(top: 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF9F9F7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF2C2C2C) : AppTheme.border,
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: widget.initialExpandServer,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
          leading: Icon(
            Icons.dns_rounded,
            size: 18,
            color: isDark ? Colors.white70 : AppTheme.ink,
          ),
          title: Text(
            'Optional: Companion Server URL',
            style: TextStyle(
              fontFamily: AppTheme.fontUI,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : AppTheme.ink,
            ),
          ),
          subtitle: Text(
            'Connect phone to laptop daemon on Wi-Fi',
            style: TextStyle(
              fontFamily: AppTheme.fontUI,
              fontSize: 11,
              color: isDark ? AppTheme.darkTextMuted : AppTheme.textMuted,
            ),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF252525)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF383838)
                            : AppTheme.border,
                      ),
                    ),
                    child: TextField(
                      controller: _serverUrlController,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        color: isDark ? Colors.white : AppTheme.ink,
                      ),
                      decoration: InputDecoration(
                        hintText: 'http://192.168.1.5:8000',
                        hintStyle: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: isDark
                              ? AppTheme.darkTextMuted
                              : AppTheme.textMuted,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.content_paste_rounded,
                              size: 16),
                          tooltip: 'Paste',
                          onPressed: () async {
                            final data = await Clipboard.getData(
                                Clipboard.kTextPlain);
                            if (data?.text != null &&
                                data!.text!.trim().isNotEmpty) {
                              _serverUrlController.text =
                                  data.text!.trim();
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              _testingServer ? null : _testServerConnection,
                          icon: _testingServer
                              ? const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                  ),
                                )
                              : const Icon(Icons.sensors_rounded, size: 14),
                          label: Text(
                            _testingServer ? 'Pinging...' : 'Test Link',
                            style: const TextStyle(fontSize: 12),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor:
                                isDark ? Colors.white : AppTheme.ink,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _testingServer
                              ? null
                              : () async {
                                  setState(() {
                                    _testingServer = true;
                                    _serverTestMessage =
                                        'Scanning local Wi-Fi...';
                                    _serverTestOk = null;
                                  });
                                  final found =
                                      await LanDiscovery.discoverServer(
                                          timeoutMs: 600);
                                  if (found != null && found.isNotEmpty) {
                                    _serverUrlController.text = found;
                                    await _testServerConnection();
                                  } else {
                                    setState(() {
                                      _testingServer = false;
                                      _serverTestOk = false;
                                      _serverTestMessage =
                                          'No Athena server discovered on Wi-Fi.';
                                    });
                                  }
                                },
                          icon: const Icon(Icons.wifi_find_rounded, size: 14),
                          label: const Text(
                            'Scan Wi-Fi',
                            style: TextStyle(fontSize: 12),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor:
                                isDark ? Colors.white : AppTheme.ink,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_serverTestMessage != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: _serverTestOk == true
                            ? const Color(0x15007A3D)
                            : const Color(0x15C84B31),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _serverTestMessage!,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: _serverTestOk == true
                              ? const Color(0xFF007A3D)
                              : const Color(0xFFC84B31),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
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
