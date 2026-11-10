import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:athena/core/api/api_client.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/models/ai_provider.dart';
import 'package:athena/services/secure_storage_service.dart';

class _ProviderOption {
  final String id;
  final String name;
  final String description;

  const _ProviderOption({
    required this.id,
    required this.name,
    required this.description,
  });
}

const _kProviderOptions = [
  _ProviderOption(
    id: 'gemini',
    name: 'Google Gemini (Recommended)',
    description: 'Direct Gemini API key via Google AI Studio',
  ),
  _ProviderOption(
    id: 'groq',
    name: 'Groq (Ultra-Fast)',
    description: 'Direct API key at 500+ tokens/sec',
  ),
  _ProviderOption(
    id: 'openrouter',
    name: 'OpenRouter',
    description: 'Multi-provider gateway with unified API key',
  ),
  _ProviderOption(
    id: 'openai',
    name: 'OpenAI',
    description: 'Direct OpenAI platform API key',
  ),
  _ProviderOption(
    id: 'anthropic',
    name: 'Anthropic Claude',
    description: 'Direct Anthropic console API key',
  ),
  _ProviderOption(
    id: 'deepseek',
    name: 'DeepSeek',
    description: 'Direct DeepSeek API key for V3 & R1 reasoning models',
  ),
  _ProviderOption(
    id: 'mistral',
    name: 'Mistral AI',
    description: 'European frontier models via Mistral API',
  ),
  _ProviderOption(
    id: 'together',
    name: 'Together AI',
    description: 'High-throughput open source models via Together platform',
  ),
  _ProviderOption(
    id: 'nvidia',
    name: 'NVIDIA NIM',
    description: 'Enterprise accelerated inference via NVIDIA build cloud',
  ),
  _ProviderOption(
    id: 'custom',
    name: 'Custom Endpoint',
    description: 'Self-hosted vLLM, Ollama, or OpenAI-compatible API',
  ),
];

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

  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  bool _obscureKey = true;

  String _provider = 'gemini';
  String? _selectedModel;
  final _keyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _serverUrlController = TextEditingController();
  final _pairingTokenController = TextEditingController();

  // Fallback AI Engine state
  bool _expandFallback = false;
  String _fallbackProvider = 'groq';
  String? _fallbackSelectedModel;
  final _fallbackKeyController = TextEditingController();
  final _fallbackBaseUrlController = TextEditingController();
  List<AIModelOption> _fallbackModels = [];
  bool _testingFallback = false;
  bool? _fallbackTestOk;
  String? _fallbackTestMessage;
  bool _fallbackProviderMenuOpen = false;
  bool _fallbackModelMenuOpen = false;
  bool _obscureFallbackKey = true;

  List<AIModelOption> _models = [];
  bool? _testOk;
  String? _testMessage;

  bool _testingServer = false;
  bool? _serverTestOk;
  String? _serverTestMessage;

  bool _providerMenuOpen = false;
  bool _modelMenuOpen = false;
  bool _serverExpanded = false;

  @override
  void initState() {
    super.initState();
    _api = widget.apiClient ?? ApiClient();
    _loadConfig();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _baseUrlController.dispose();
    _serverUrlController.dispose();
    _pairingTokenController.dispose();
    _fallbackKeyController.dispose();
    _fallbackBaseUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final config = await _api.getAIConfig();
      final prefs = await SharedPreferences.getInstance();

      final savedProvider = prefs.getString('athena_ai_primary_provider') ??
          (config.primaryProvider.isNotEmpty
              ? config.primaryProvider
              : 'gemini');
      final savedKey = await SecureStorageService.instance
              .getAIKey('athena_ai_primary_api_key') ??
          '';
      final savedModel = prefs.getString('athena_ai_primary_model') ??
          (config.primaryModel.isNotEmpty ? config.primaryModel : null);
      final savedBaseUrl = prefs.getString('athena_ai_primary_base_url') ??
          (config.primaryBaseUrl ?? '');
      final serverUrl = await SecureStorageService.instance.getBackendUrl();
      final pairingToken = await SecureStorageService.instance.getPairingToken();

      // Fallback config
      final savedFallbackProvider = prefs.getString('athena_ai_fallback_provider') ??
          (config.fallbackProvider?.isNotEmpty == true ? config.fallbackProvider! : 'groq');
      final savedFallbackKey = await SecureStorageService.instance
              .getAIKey('athena_ai_fallback_api_key') ??
          '';
      final savedFallbackModel = prefs.getString('athena_ai_fallback_model') ??
          config.fallbackModel;
      final savedFallbackBaseUrl = prefs.getString('athena_ai_fallback_base_url') ??
          (config.fallbackBaseUrl ?? '');

      if (!mounted) return;
      setState(() {
        _provider = savedProvider;
        _keyController.text = savedKey;
        _baseUrlController.text = savedBaseUrl;
        _serverUrlController.text = serverUrl;
        _pairingTokenController.text = pairingToken;
        _serverExpanded = widget.initialExpandServer;
        _selectedModel = savedModel;
        _models = savedModel != null && savedModel.isNotEmpty
            ? [AIModelOption(id: savedModel, name: savedModel)]
            : [];

        _fallbackProvider = savedFallbackProvider;
        _fallbackKeyController.text = savedFallbackKey;
        _fallbackBaseUrlController.text = savedFallbackBaseUrl;
        _fallbackSelectedModel = savedFallbackModel;
        _fallbackModels = savedFallbackModel != null && savedFallbackModel.isNotEmpty
            ? [AIModelOption(id: savedFallbackModel, name: savedFallbackModel)]
            : [];

        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _testServerConnection() async {
    final serverUrl = _serverUrlController.text.trim();
    if (serverUrl.isEmpty) {
      setState(() {
        _serverTestOk = false;
        _serverTestMessage = 'Please enter a desktop server URL to test (e.g. http://192.168.1.100:8000)';
      });
      return;
    }
    setState(() {
      _testingServer = true;
      _serverTestOk = null;
      _serverTestMessage = null;
    });

    final res = await _api.testServerConnection(
      serverUrl: serverUrl,
      pairingToken: _pairingTokenController.text.trim(),
    );

    if (!mounted) return;
    final isOk = res['ok'] == true;
    final code = res['code']?.toString();
    final msg = res['message']?.toString() ??
        (isOk ? 'Connected successfully!' : 'Connection failed');
    final formattedMessage =
        (!isOk && code != null && code.isNotEmpty) ? '[$code] $msg' : msg;

    setState(() {
      _testingServer = false;
      _serverTestOk = isOk;
      _serverTestMessage = formattedMessage;
    });
  }

  Future<void> _pasteFromClipboard() async {
    HapticFeedback.selectionClick();
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      setState(() {
        _keyController.text = data.text!.trim();
        _testOk = null;
        _testMessage = null;
      });
    }
  }

  Future<void> _testConnectionAndFetchLiveModels() async {
    final key = _keyController.text.trim();
    if (_provider != 'custom' && key.isEmpty) {
      setState(() {
        _testOk = false;
        _testMessage = 'Please enter or paste an API key to test.';
      });
      return;
    }

    setState(() {
      _testing = true;
      _testOk = null;
      _testMessage = null;
      _providerMenuOpen = false;
      _modelMenuOpen = false;
    });

    try {
      final baseUrl = _baseUrlController.text.trim().isNotEmpty
          ? _baseUrlController.text.trim()
          : null;

      final res = await _api.testAIConnection(
        provider: _provider,
        apiKey: key,
        model: _selectedModel,
        baseUrl: baseUrl,
      );

      final liveModels = await _api.fetchModels(
        provider: _provider,
        apiKey: key,
        baseUrl: baseUrl,
      );

      if (!mounted) return;

      final ok = (res['ok'] == true || res['valid'] == true);
      final rawMsg = res['message']?.toString();

      setState(() {
        _testing = false;
        _testOk = ok;

        if (liveModels.isNotEmpty) {
          _models = liveModels;
          final existingMatch = liveModels.any((m) => m.id == _selectedModel);
          if (!existingMatch) {
            _selectedModel = liveModels.first.id;
          }
          _testMessage = ok
              ? 'Connected! Loaded ${liveModels.length} live models from API.'
              : (rawMsg ??
                  'Live models loaded, but validation check returned an error.');
        } else {
          _models = [];
          _selectedModel = null;
          _testMessage = rawMsg ??
              (ok
                  ? 'Connected, but no compatible generation models were found.'
                  : 'Connection test failed. Check your API key.');
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _models = [];
        _selectedModel = null;
        _testMessage = e.toString();
      });
    }
  }

  Future<void> _testFallbackConnection() async {
    final key = _fallbackKeyController.text.trim();
    if (key.isEmpty && _fallbackProvider != 'custom') {
      setState(() {
        _fallbackTestOk = false;
        _fallbackTestMessage =
            'Please enter an API key for fallback provider';
      });
      return;
    }
    setState(() {
      _testingFallback = true;
      _fallbackTestOk = null;
      _fallbackTestMessage = null;
    });
    try {
      final baseUrl = _fallbackBaseUrlController.text.trim().isNotEmpty
          ? _fallbackBaseUrlController.text.trim()
          : null;

      final res = await _api.testAIConnection(
        provider: _fallbackProvider,
        apiKey: key.isNotEmpty ? key : null,
        model: _fallbackSelectedModel,
        baseUrl: baseUrl,
      );

      final liveModels = await _api.fetchModels(
        provider: _fallbackProvider,
        apiKey: key.isNotEmpty ? key : null,
        baseUrl: baseUrl,
      );

      if (mounted) {
        final ok = (res['ok'] == true || res['valid'] == true);
        final rawMsg = res['message']?.toString();
        setState(() {
          _testingFallback = false;
          _fallbackTestOk = ok;
          _fallbackTestMessage = ok
              ? 'Fallback connected! Loaded ${liveModels.length} live models.'
              : (rawMsg ?? 'Fallback test failed.');
          if (liveModels.isNotEmpty) {
            _fallbackModels = liveModels;
            if (_fallbackSelectedModel == null ||
                !_fallbackModels.any((m) => m.id == _fallbackSelectedModel)) {
              _fallbackSelectedModel = liveModels.first.id;
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testingFallback = false;
          _fallbackTestOk = false;
          _fallbackTestMessage = 'Check failed: $e';
        });
      }
    }
  }

  Future<void> _saveConfig() async {
    setState(() => _saving = true);
    final key = _keyController.text.trim();
    final baseUrl = _baseUrlController.text.trim();
    final fallbackKey = _fallbackKeyController.text.trim();
    final fallbackModel = _fallbackSelectedModel;
    final hasFallback = fallbackKey.isNotEmpty || (fallbackModel != null && fallbackModel.isNotEmpty);

    try {
      await _api.saveAIConfig(
        primaryProvider: _provider,
        primaryApiKey: key.isNotEmpty ? key : null,
        primaryModel: _selectedModel,
        primaryBaseUrl: baseUrl.isNotEmpty ? baseUrl : null,
        fallbackProvider: hasFallback ? _fallbackProvider : null,
        fallbackApiKey: fallbackKey.isNotEmpty ? fallbackKey : null,
        fallbackModel: hasFallback ? fallbackModel : null,
        fallbackBaseUrl: _fallbackBaseUrlController.text.trim().isNotEmpty
            ? _fallbackBaseUrlController.text.trim()
            : null,
      );
      await SecureStorageService.instance
          .setBackendUrl(_serverUrlController.text.trim());
      await SecureStorageService.instance
          .setPairingToken(_pairingTokenController.text.trim());

      if (!mounted) return;
      setState(() => _saving = false);
      widget.onConfigSaved?.call();
      Navigator.of(context).pop();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            key.isEmpty
                ? 'Saved on-device (Offline mode).'
                : 'AI Engine Settings updated and saved successfully.',
          ),
          backgroundColor: const Color(0xFF2D6A4F),
          duration: const Duration(seconds: 3),
        ),
      );
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

  InputDecoration _buildInputDecoration(bool isDark,
      {String? hintText, Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: TextStyle(
        fontFamily: AppTheme.fontUI,
        fontSize: 13,
        color: isDark ? const Color(0xFF6B6B6B) : const Color(0xFF9E9E9E),
      ),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: isDark ? const Color(0xFF202020) : const Color(0xFFF5F2EB),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark ? const Color(0xFF2C2C2C) : AppTheme.border,
          width: 1.0,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark ? const Color(0xFF2C2C2C) : AppTheme.border,
          width: 1.0,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark ? const Color(0xFF2DD4BF) : const Color(0xFF2D6A4F),
          width: 1.5,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final sheetBg = isDark ? const Color(0xFF141413) : const Color(0xFFFBF9F5);
    final borderColor = isDark ? const Color(0xFF282828) : AppTheme.border;
    final primaryInk = isDark ? Colors.white : AppTheme.ink;

    final selectedProvObj = _kProviderOptions.firstWhere(
      (p) => p.id == _provider,
      orElse: () => _kProviderOptions.first,
    );

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: sheetBg,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: borderColor,
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
          borderRadius: BorderRadius.circular(24),
          child: _loading
              ? SizedBox(
                  height: 200,
                  child: Center(
                    child: CircularProgressIndicator(
                      color: primaryInk,
                    ),
                  ),
                )
              : SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              color: (isDark
                                      ? const Color(0xFF2DD4BF)
                                      : const Color(0xFF2D6A4F))
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              Icons.tune_rounded,
                              size: 18,
                              color: isDark
                                  ? const Color(0xFF2DD4BF)
                                  : const Color(0xFF2D6A4F),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'AI Engine Settings',
                              style: TextStyle(
                                fontFamily: AppTheme.fontDisplay,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? const Color(0xFFF3F3F3)
                                    : AppTheme.ink,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, size: 20),
                            color: isDark
                                ? const Color(0xFF9E9E9E)
                                : AppTheme.textMuted,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Step 1: AI Provider (Attached In-Sheet Expandable Card)
                      Text(
                        'AI Provider',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? const Color(0xFFB0B0B0)
                              : AppTheme.textMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF202020)
                              : const Color(0xFFF5F2EB),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _providerMenuOpen
                                ? (isDark
                                    ? const Color(0xFF2DD4BF)
                                    : const Color(0xFF2D6A4F))
                                : (isDark
                                    ? const Color(0xFF2C2C2C)
                                    : AppTheme.border),
                            width: _providerMenuOpen ? 1.5 : 1.0,
                          ),
                        ),
                        child: Column(
                          children: [
                            InkWell(
                              onTap: () {
                                setState(() {
                                  _providerMenuOpen = !_providerMenuOpen;
                                  _modelMenuOpen = false;
                                });
                              },
                              borderRadius: BorderRadius.circular(12),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 12),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            selectedProvObj.name,
                                            style: TextStyle(
                                              fontFamily: AppTheme.fontMono,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: isDark
                                                  ? const Color(0xFFF3F3F3)
                                                  : AppTheme.textPrimary,
                                            ),
                                          ),
                                          Text(
                                            selectedProvObj.description,
                                            style: TextStyle(
                                              fontFamily: AppTheme.fontMono,
                                              fontSize: 11,
                                              color: isDark
                                                  ? const Color(0xFF888888)
                                                  : AppTheme.textMuted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      _providerMenuOpen
                                          ? Icons.keyboard_arrow_up_rounded
                                          : Icons.keyboard_arrow_down_rounded,
                                      color: isDark
                                          ? const Color(0xFF888888)
                                          : AppTheme.textMuted,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (_providerMenuOpen) ...[
                              Divider(
                                height: 1,
                                thickness: 1,
                                color: isDark
                                    ? const Color(0xFF2C2C2C)
                                    : AppTheme.border,
                              ),
                              ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxHeight: 220),
                                child: ListView.separated(
                                  shrinkWrap: true,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 4),
                                  itemCount: _kProviderOptions.length,
                                  separatorBuilder: (_, __) => Divider(
                                    height: 1,
                                    thickness: 0.5,
                                    color: isDark
                                        ? const Color(0xFF272727)
                                        : const Color(0xFFECE7DE),
                                  ),
                                  itemBuilder: (ctx, idx) {
                                    final p = _kProviderOptions[idx];
                                    final selected = p.id == _provider;
                                    return Material(
                                      color: Colors.transparent,
                                      child: ListTile(
                                      dense: true,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 2),
                                      title: Text(
                                        p.name,
                                        style: TextStyle(
                                          fontFamily: AppTheme.fontMono,
                                          fontSize: 13,
                                          fontWeight: selected
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: selected
                                              ? (isDark
                                                  ? const Color(0xFF2DD4BF)
                                                  : const Color(0xFF2D6A4F))
                                              : (isDark
                                                  ? Colors.white
                                                  : AppTheme.ink),
                                        ),
                                      ),
                                      subtitle: Text(
                                        p.description,
                                        style: TextStyle(
                                          fontFamily: AppTheme.fontMono,
                                          fontSize: 11,
                                          color: isDark
                                              ? const Color(0xFF888888)
                                              : AppTheme.textMuted,
                                        ),
                                      ),
                                      trailing: selected
                                          ? Icon(
                                              Icons.check_rounded,
                                              size: 16,
                                              color: isDark
                                                  ? const Color(0xFF2DD4BF)
                                                  : const Color(0xFF2D6A4F),
                                            )
                                          : null,
                                      onTap: () {
                                        setState(() {
                                          _provider = p.id;
                                          _providerMenuOpen = false;
                                          _testOk = null;
                                          _testMessage = null;
                                          _models = [];
                                          _selectedModel = null;
                                        });
                                      },
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Custom Base URL field (only shown for custom provider)
                      if (_provider == 'custom') ...[
                        Text(
                          'Endpoint URL',
                          style: TextStyle(
                            fontFamily: AppTheme.fontUI,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? const Color(0xFFB0B0B0)
                                : AppTheme.textMuted,
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _baseUrlController,
                          decoration: _buildInputDecoration(
                            isDark,
                            hintText: 'https://api.example.com/v1',
                          ),
                          style: TextStyle(
                            fontFamily: AppTheme.fontUI,
                            fontSize: 14,
                            color: isDark
                                ? const Color(0xFFF3F3F3)
                                : AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],

                      // Step 2: API Key TextField
                      Text(
                        'API Key',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? const Color(0xFFB0B0B0)
                              : AppTheme.textMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _keyController,
                        obscureText: _obscureKey,
                        onChanged: (_) {
                          if (_testOk != null || _testMessage != null) {
                            setState(() {
                              _testOk = null;
                              _testMessage = null;
                            });
                          }
                        },
                        decoration: _buildInputDecoration(
                          isDark,
                          hintText:
                              _provider == 'gemini' ? 'AIzaSy...' : 'sk-...',
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton.icon(
                                onPressed: _pasteFromClipboard,
                                icon: const Icon(Icons.content_paste_rounded,
                                    size: 14),
                                label: const Text('Paste',
                                    style: TextStyle(fontSize: 12)),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: isDark
                                      ? const Color(0xFF2DD4BF)
                                      : const Color(0xFF2D6A4F),
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  _obscureKey
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 18,
                                ),
                                color: isDark
                                    ? const Color(0xFF888888)
                                    : AppTheme.textMuted,
                                onPressed: () =>
                                    setState(() => _obscureKey = !_obscureKey),
                              ),
                            ],
                          ),
                        ),
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 14,
                          color: isDark
                              ? const Color(0xFFF3F3F3)
                              : AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Step 4: Model Selector (ONLY unlocked when live models exist)
                      Text(
                        'Model',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? const Color(0xFFB0B0B0)
                              : AppTheme.textMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (_models.isEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 14),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF1E1E1E)
                                : const Color(0xFFF5F2EB),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: borderColor,
                              width: 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.lock_outline_rounded,
                                size: 16,
                                color: isDark
                                    ? const Color(0xFF888888)
                                    : AppTheme.textMuted,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  '[ ENTER API KEY & CLICK "CHECK CONNECTION" TO DISCOVER LIVE MODELS ]',
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontMono,
                                    fontSize: 12,
                                    color: isDark
                                        ? const Color(0xFF888888)
                                        : AppTheme.textMuted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        Container(
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF202020)
                                : const Color(0xFFF5F2EB),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _modelMenuOpen
                                  ? (isDark
                                      ? const Color(0xFF2DD4BF)
                                      : const Color(0xFF2D6A4F))
                                  : borderColor,
                              width: _modelMenuOpen ? 1.5 : 1.0,
                            ),
                          ),
                          child: Column(
                            children: [
                              InkWell(
                                onTap: () {
                                  setState(() {
                                    _modelMenuOpen = !_modelMenuOpen;
                                    _providerMenuOpen = false;
                                  });
                                },
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 12),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _models
                                                  .where((m) =>
                                                      m.id == _selectedModel)
                                                  .firstOrNull
                                                  ?.name ??
                                              _selectedModel ??
                                              'Select a model',
                                          style: TextStyle(
                                            fontFamily: AppTheme.fontMono,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: isDark
                                                ? const Color(0xFFF3F3F3)
                                                : AppTheme.textPrimary,
                                          ),
                                        ),
                                      ),
                                      Icon(
                                        _modelMenuOpen
                                            ? Icons.keyboard_arrow_up_rounded
                                            : Icons.keyboard_arrow_down_rounded,
                                        color: isDark
                                            ? const Color(0xFF888888)
                                            : AppTheme.textMuted,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (_modelMenuOpen) ...[
                                Divider(
                                  height: 1,
                                  thickness: 1,
                                  color: borderColor,
                                ),
                                ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxHeight: 220),
                                  child: ListView.separated(
                                    shrinkWrap: true,
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 4),
                                    itemCount: _models.length,
                                    separatorBuilder: (_, __) => Divider(
                                      height: 1,
                                      thickness: 0.5,
                                      color: isDark
                                          ? const Color(0xFF272727)
                                          : const Color(0xFFECE7DE),
                                    ),
                                    itemBuilder: (ctx, idx) {
                                      final m = _models[idx];
                                      final selected = m.id == _selectedModel;
                                      return Material(
                                        color: Colors.transparent,
                                        child: ListTile(
                                        dense: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 14, vertical: 2),
                                        title: Text(
                                          m.name,
                                          style: TextStyle(
                                            fontFamily: AppTheme.fontMono,
                                            fontSize: 13,
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w500,
                                            color: selected
                                                ? (isDark
                                                    ? const Color(0xFF2DD4BF)
                                                    : const Color(0xFF2D6A4F))
                                                : (isDark
                                                    ? Colors.white
                                                    : AppTheme.ink),
                                          ),
                                        ),
                                        subtitle: Text(
                                          m.id,
                                          style: TextStyle(
                                            fontFamily: AppTheme.fontMono,
                                            fontSize: 11,
                                            color: isDark
                                                ? const Color(0xFF888888)
                                                : AppTheme.textMuted,
                                          ),
                                        ),
                                        trailing: selected
                                            ? Icon(
                                                Icons.check_rounded,
                                                size: 16,
                                                color: isDark
                                                    ? const Color(0xFF2DD4BF)
                                                    : const Color(0xFF2D6A4F),
                                              )
                                            : null,
                                        onTap: () {
                                          setState(() {
                                            _selectedModel = m.id;
                                            _modelMenuOpen = false;
                                          });
                                        },
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),

                      // Test feedback banner
                      if (_testMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: _testOk == true
                                ? const Color(0xFF2D6A4F)
                                    .withValues(alpha: 0.15)
                                : Colors.redAccent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: _testOk == true
                                  ? const Color(0xFF2D6A4F)
                                  : Colors.redAccent,
                              width: 1.0,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _testOk == true
                                    ? Icons.check_circle_rounded
                                    : Icons.error_outline_rounded,
                                size: 16,
                                color: _testOk == true
                                    ? const Color(0xFF2D6A4F)
                                    : Colors.redAccent,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _testMessage!,
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontMono,
                                    fontSize: 12,
                                    color: _testOk == true
                                        ? (isDark
                                            ? const Color(0xFF2DD4BF)
                                            : const Color(0xFF2D6A4F))
                                        : Colors.redAccent,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],

                      // Fallback AI Engine (Auto-Failover) Collapsible Section (Audit Batch 3 P1-08)
                      Material(
                        color: Colors.transparent,
                        child: Theme(
                          data: Theme.of(context).copyWith(
                            dividerColor: Colors.transparent,
                            splashColor: Colors.transparent,
                          ),
                          child: ExpansionTile(
                            initiallyExpanded: _expandFallback,
                            onExpansionChanged: (val) =>
                                setState(() => _expandFallback = val),
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: const EdgeInsets.only(bottom: 12),
                            title: Row(
                              children: [
                                Icon(Icons.shield_outlined,
                                    size: 16,
                                    color: isDark
                                        ? const Color(0xFF2DD4BF)
                                        : const Color(0xFF2D6A4F)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Fallback AI Engine (Auto-Failover)',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontFamily: AppTheme.fontUI,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: isDark
                                          ? const Color(0xFFE0E0E0)
                                          : AppTheme.ink,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            children: [
                              Text(
                                'Secondary provider used automatically when primary hits quota or rate limits.',
                                style: TextStyle(
                                  fontFamily: AppTheme.fontUI,
                                  fontSize: 12,
                                  color: isDark
                                      ? AppTheme.darkTextMuted
                                      : AppTheme.textMuted,
                                ),
                              ),
                              const SizedBox(height: 10),
                              // Fallback Provider Selector Card (Zero DropdownButton)
                              Container(
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(0xFF1E1E1E)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: borderColor),
                                ),
                                child: Column(
                                  children: [
                                    InkWell(
                                      onTap: () => setState(() =>
                                          _fallbackProviderMenuOpen =
                                              !_fallbackProviderMenuOpen),
                                      borderRadius: BorderRadius.circular(12),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 14, vertical: 12),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                _kProviderOptions
                                                    .firstWhere((p) =>
                                                        p.id ==
                                                        _fallbackProvider)
                                                    .name,
                                                style: TextStyle(
                                                  fontFamily: AppTheme.fontUI,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  color: isDark
                                                      ? Colors.white
                                                      : AppTheme.ink,
                                                ),
                                              ),
                                            ),
                                            Icon(
                                              _fallbackProviderMenuOpen
                                                  ? Icons
                                                      .keyboard_arrow_up_rounded
                                                  : Icons
                                                      .keyboard_arrow_down_rounded,
                                              size: 20,
                                              color: isDark
                                                  ? const Color(0xFF888888)
                                                  : AppTheme.textMuted,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    if (_fallbackProviderMenuOpen) ...[
                                      const Divider(height: 1),
                                      ..._kProviderOptions.map((opt) {
                                        final isSel =
                                            opt.id == _fallbackProvider;
                                        return InkWell(
                                          onTap: () {
                                            setState(() {
                                              _fallbackProvider = opt.id;
                                              _fallbackProviderMenuOpen = false;
                                              _fallbackModels = [];
                                              _fallbackSelectedModel = null;
                                            });
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 14, vertical: 10),
                                            color: isSel
                                                ? (isDark
                                                    ? const Color(0xFF282828)
                                                    : const Color(0xFFEAE6DF))
                                                : Colors.transparent,
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    opt.name,
                                                    style: TextStyle(
                                                      fontFamily:
                                                          AppTheme.fontUI,
                                                      fontSize: 13,
                                                      fontWeight: isSel
                                                          ? FontWeight.w600
                                                          : FontWeight.normal,
                                                      color: isDark
                                                          ? Colors.white
                                                          : AppTheme.ink,
                                                    ),
                                                  ),
                                                ),
                                                if (isSel)
                                                  Icon(Icons.check_rounded,
                                                      size: 16,
                                                      color: isDark
                                                          ? const Color(
                                                              0xFF2DD4BF)
                                                          : const Color(
                                                              0xFF2D6A4F)),
                                              ],
                                            ),
                                          ),
                                        );
                                      }),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                              // Fallback API Key
                              TextField(
                                controller: _fallbackKeyController,
                                obscureText: _obscureFallbackKey,
                                autocorrect: false,
                                decoration: _buildInputDecoration(
                                  isDark,
                                  hintText: 'Enter fallback API key...',
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureFallbackKey
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                      size: 18,
                                      color: isDark
                                          ? const Color(0xFF9E9E9E)
                                          : AppTheme.textMuted,
                                    ),
                                    onPressed: () => setState(() =>
                                        _obscureFallbackKey =
                                            !_obscureFallbackKey),
                                  ),
                                ),
                                style: TextStyle(
                                  fontFamily: AppTheme.fontMono,
                                  fontSize: 13,
                                  color: isDark
                                      ? Colors.white
                                      : AppTheme.textPrimary,
                                ),
                              ),
                              if (_fallbackProvider == 'custom') ...[
                                const SizedBox(height: 10),
                                TextField(
                                  controller: _fallbackBaseUrlController,
                                  keyboardType: TextInputType.url,
                                  autocorrect: false,
                                  decoration: _buildInputDecoration(
                                    isDark,
                                    hintText: 'http://localhost:11434/v1',
                                  ),
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontUI,
                                    fontSize: 13,
                                    color: isDark
                                        ? Colors.white
                                        : AppTheme.textPrimary,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 10),
                              // Check Fallback Connection Button
                              ElevatedButton(
                                onPressed: _testingFallback
                                    ? null
                                    : _testFallbackConnection,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isDark
                                      ? const Color(0xFF2DD4BF)
                                      : const Color(0xFF2D6A4F),
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                ),
                                child: _testingFallback
                                    ? const SizedBox(
                                        height: 16,
                                        width: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Text(
                                        'Check Fallback Connection',
                                        style: TextStyle(
                                          fontFamily: AppTheme.fontUI,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                              ),
                              if (_fallbackTestMessage != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  _fallbackTestMessage!,
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontMono,
                                    fontSize: 11,
                                    color: _fallbackTestOk == true
                                        ? (isDark
                                            ? const Color(0xFF2DD4BF)
                                            : const Color(0xFF2D6A4F))
                                        : Colors.redAccent,
                                  ),
                                ),
                              ],
                              if (_fallbackModels.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Container(
                                  decoration: BoxDecoration(
                                    color: isDark
                                        ? const Color(0xFF1E1E1E)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: borderColor),
                                  ),
                                  child: Column(
                                    children: [
                                      InkWell(
                                        onTap: () => setState(() =>
                                            _fallbackModelMenuOpen =
                                                !_fallbackModelMenuOpen),
                                        borderRadius: BorderRadius.circular(12),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 12),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  _fallbackSelectedModel ??
                                                      'Select Fallback Model',
                                                  style: TextStyle(
                                                    fontFamily:
                                                        AppTheme.fontMono,
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                    color: isDark
                                                        ? Colors.white
                                                        : AppTheme.ink,
                                                  ),
                                                ),
                                              ),
                                              Icon(
                                                _fallbackModelMenuOpen
                                                    ? Icons
                                                        .keyboard_arrow_up_rounded
                                                    : Icons
                                                        .keyboard_arrow_down_rounded,
                                                size: 20,
                                                color: isDark
                                                    ? const Color(0xFF888888)
                                                    : AppTheme.textMuted,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      if (_fallbackModelMenuOpen) ...[
                                        const Divider(height: 1),
                                        ..._fallbackModels.map((m) {
                                          final isSel =
                                              m.id == _fallbackSelectedModel;
                                          return InkWell(
                                            onTap: () {
                                              setState(() {
                                                _fallbackSelectedModel = m.id;
                                                _fallbackModelMenuOpen = false;
                                              });
                                            },
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 14,
                                                      vertical: 10),
                                              color: isSel
                                                  ? (isDark
                                                      ? const Color(0xFF282828)
                                                      : const Color(0xFFEAE6DF))
                                                  : Colors.transparent,
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      m.name,
                                                      style: TextStyle(
                                                        fontFamily:
                                                            AppTheme.fontMono,
                                                        fontSize: 12,
                                                        fontWeight: isSel
                                                            ? FontWeight.w600
                                                            : FontWeight.normal,
                                                        color: isDark
                                                            ? Colors.white
                                                            : AppTheme.ink,
                                                      ),
                                                    ),
                                                  ),
                                                  if (isSel)
                                                    Icon(Icons.check_rounded,
                                                        size: 16,
                                                        color: isDark
                                                            ? const Color(
                                                                0xFF2DD4BF)
                                                            : const Color(
                                                                0xFF2D6A4F)),
                                                ],
                                              ),
                                            ),
                                          );
                                        }),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),

                      Material(
                        color: Colors.transparent,
                        child: Theme(
                          data: Theme.of(context).copyWith(
                            dividerColor: Colors.transparent,
                            splashColor: Colors.transparent,
                          ),
                          child: ExpansionTile(
                          initiallyExpanded: _serverExpanded,
                          onExpansionChanged: (value) =>
                              setState(() => _serverExpanded = value),
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(bottom: 12),
                          title: Text(
                            'Advanced: Optional Desktop Server URL',
                            style: TextStyle(
                              fontFamily: AppTheme.fontUI,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? const Color(0xFFB0B0B0)
                                  : AppTheme.textMuted,
                            ),
                          ),
                          children: [
                            TextField(
                              controller: _serverUrlController,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              decoration: _buildInputDecoration(
                                isDark,
                                hintText: 'http://192.168.1.20:8000',
                              ),
                              style: TextStyle(
                                fontFamily: AppTheme.fontUI,
                                fontSize: 14,
                                color: isDark
                                    ? Colors.white
                                    : AppTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _pairingTokenController,
                              keyboardType: TextInputType.text,
                              autocorrect: false,
                              decoration: _buildInputDecoration(
                                isDark,
                                hintText: 'Pairing Token (from desktop terminal)',
                              ),
                              style: TextStyle(
                                fontFamily: AppTheme.fontMono,
                                fontSize: 13,
                                color: isDark
                                    ? Colors.white
                                    : AppTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                OutlinedButton(
                                  onPressed: _testingServer
                                      ? null
                                      : _testServerConnection,
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 8),
                                    side: BorderSide(color: borderColor),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: _testingServer
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : const Text(
                                          'Test Server Connection',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                ),
                              ],
                            ),
                            if (_serverTestMessage != null) ...[
                              const SizedBox(height: 8),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: _serverTestOk == true
                                      ? const Color(0xFF2D6A4F)
                                          .withValues(alpha: 0.12)
                                      : Colors.red.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: _serverTestOk == true
                                        ? const Color(0xFF2D6A4F)
                                        : Colors.redAccent,
                                    width: 1.0,
                                  ),
                                ),
                                child: Text(
                                  _serverTestMessage!,
                                  style: TextStyle(
                                    fontFamily: AppTheme.fontUI,
                                    fontSize: 12,
                                    color: _serverTestOk == true
                                        ? const Color(0xFF2D6A4F)
                                        : Colors.redAccent,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 6),
                            Text(
                              'Leave blank to use Athena locally on this device.',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: isDark
                                      ? Colors.white54
                                      : AppTheme.textMuted),
                            ),
                          ],
                          ),
                        ),
                      ),

                      // Actions: Check Connection + Save & Apply
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _testing
                                  ? null
                                  : _testConnectionAndFetchLiveModels,
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                side: BorderSide(
                                  color: borderColor,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: _testing
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : Text(
                                      'Check Connection',
                                      style: TextStyle(
                                        fontFamily: AppTheme.fontMono,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: isDark
                                            ? Colors.white
                                            : AppTheme.ink,
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _saving ? null : _saveConfig,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isDark
                                    ? const Color(0xFF2DD4BF)
                                    : const Color(0xFF2D6A4F),
                                foregroundColor:
                                    isDark ? Colors.black : Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
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
                                      style: TextStyle(
                                        fontFamily: AppTheme.fontMono,
                                        fontSize: 13,
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
  }
}
