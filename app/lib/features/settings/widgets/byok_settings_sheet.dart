import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:athena/core/api/api_client.dart';
import 'package:athena/core/theme/theme.dart';

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
  String _selectedModel = 'gemini-2.5-flash';
  final _keyController = TextEditingController();
  final _baseUrlController = TextEditingController();

  List<String> _availableModels = [
    'gemini-2.5-flash',
    'gemini-2.5-pro',
    'gemini-2.0-flash',
  ];

  bool? _testOk;
  String? _testMessage;

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
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final config = await _api.getAIConfig();
      final prefs = await SharedPreferences.getInstance();

      final savedProvider = prefs.getString('athena_ai_primary_provider') ??
          (config.primaryProvider.isNotEmpty ? config.primaryProvider : 'gemini');
      final savedKey = prefs.getString('athena_ai_primary_api_key') ?? '';
      final savedModel = prefs.getString('athena_ai_primary_model') ??
          (config.primaryModel.isNotEmpty ? config.primaryModel : 'gemini-2.5-flash');
      final savedBaseUrl = prefs.getString('athena_ai_primary_base_url') ??
          (config.primaryBaseUrl ?? '');

      setState(() {
        _provider = savedProvider;
        _keyController.text = savedKey;
        _baseUrlController.text = savedBaseUrl;
        _selectedModel = savedModel;
        _updateModelOptionsForProvider(savedProvider, currentModel: savedModel);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _updateModelOptionsForProvider(String prov, {String? currentModel}) {
    List<String> list;
    switch (prov.toLowerCase()) {
      case 'gemini':
        list = ['gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.0-flash'];
        break;
      case 'groq':
        list = ['llama-3.3-70b-versatile', 'llama-3.1-8b-instant'];
        break;
      case 'openrouter':
        list = [
          'google/gemini-2.5-flash',
          'anthropic/claude-3.5-haiku',
          'meta-llama/llama-3.3-70b-instruct',
        ];
        break;
      case 'openai':
        list = ['gpt-4o-mini', 'gpt-4o'];
        break;
      case 'anthropic':
        list = ['claude-3-5-haiku-20241022', 'claude-3-5-sonnet-20241022'];
        break;
      default:
        list = ['default'];
    }

    final target = currentModel ?? list.first;
    if (!list.contains(target)) {
      list = [target, ...list];
    }

    _availableModels = list;
    _selectedModel = target;
  }

  Future<void> _pasteFromClipboard() async {
    HapticFeedback.selectionClick();
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      setState(() {
        _keyController.text = data.text!.trim();
        _testOk = null;
        _testMessage = null;
      });
    }
  }

  Future<void> _testConnection() async {
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
    });

    try {
      final res = await _api.testAIConnection(
        provider: _provider,
        apiKey: key,
        model: _selectedModel,
        baseUrl: _baseUrlController.text.trim().isNotEmpty
            ? _baseUrlController.text.trim()
            : null,
      );

      if (!mounted) return;

      final ok = (res['ok'] == true || res['valid'] == true);
      final msg = res['message']?.toString() ??
          (ok ? 'Connected successfully!' : 'Connection test failed.');

      final rawModels = res['models'] as List? ?? [];
      final discovered = rawModels
          .map((m) =>
              m is Map ? (m['id'] ?? m['name'])?.toString() : m.toString())
          .where((s) => s != null && s.isNotEmpty)
          .cast<String>()
          .toList();

      setState(() {
        _testing = false;
        _testOk = ok;
        _testMessage = msg;
        if (discovered.isNotEmpty) {
          final merged = <String>{..._availableModels, ...discovered}.toList();
          _availableModels = merged;
          if (!merged.contains(_selectedModel)) {
            _selectedModel = discovered.first;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testMessage = e.toString();
      });
    }
  }

  Future<void> _saveConfig() async {
    setState(() => _saving = true);
    final key = _keyController.text.trim();
    final baseUrl = _baseUrlController.text.trim();

    try {
      await _api.saveAIConfig(
        primaryProvider: _provider,
        primaryApiKey: key.isNotEmpty ? key : null,
        primaryModel: _selectedModel,
        primaryBaseUrl: baseUrl.isNotEmpty ? baseUrl : null,
      );

      if (!mounted) return;
      setState(() => _saving = false);
      widget.onConfigSaved?.call();
      Navigator.of(context).pop();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            key.isEmpty
                ? 'Saved on-device! (Add an API key anytime for deep AI analysis)'
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

  InputDecoration _buildInputDecoration(bool isDark, {String? hintText, Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: TextStyle(
        fontFamily: AppTheme.fontUI,
        fontSize: 13,
        color: isDark ? const Color(0xFF6B6B6B) : const Color(0xFF9E9E9E),
      ),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: isDark ? const Color(0xFF202020) : const Color(0xFFF7F5F0),
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

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF181818) : Colors.white,
          borderRadius: BorderRadius.circular(24),
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
          borderRadius: BorderRadius.circular(24),
          child: _loading
              ? SizedBox(
                  height: 200,
                  child: Center(
                    child: CircularProgressIndicator(
                      color: isDark ? Colors.white : AppTheme.ink,
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
                              Icons.auto_awesome,
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

                      // AI Provider Dropdown
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
                      DropdownButtonFormField<String>(
                        // ignore: deprecated_member_use
                        value: _provider,
                        dropdownColor:
                            isDark ? const Color(0xFF222222) : Colors.white,
                        decoration: _buildInputDecoration(isDark),
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 14,
                          color: isDark
                              ? const Color(0xFFF3F3F3)
                              : AppTheme.textPrimary,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'gemini',
                            child: Text('Google Gemini (Recommended)'),
                          ),
                          DropdownMenuItem(
                            value: 'groq',
                            child: Text('Groq (Ultra-Fast)'),
                          ),
                          DropdownMenuItem(
                            value: 'openrouter',
                            child: Text('OpenRouter'),
                          ),
                          DropdownMenuItem(
                            value: 'openai',
                            child: Text('OpenAI'),
                          ),
                          DropdownMenuItem(
                            value: 'anthropic',
                            child: Text('Anthropic Claude'),
                          ),
                          DropdownMenuItem(
                            value: 'custom',
                            child: Text('Custom Endpoint'),
                          ),
                        ],
                        onChanged: (val) {
                          if (val == null) return;
                          setState(() {
                            _provider = val;
                            _testOk = null;
                            _testMessage = null;
                            _updateModelOptionsForProvider(val);
                          });
                        },
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

                      // API Key TextField
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
                        decoration: _buildInputDecoration(
                          isDark,
                          hintText: _provider == 'gemini'
                              ? 'AIzaSy...'
                              : 'sk-...',
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
                                onPressed: () => setState(
                                    () => _obscureKey = !_obscureKey),
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

                      // Model Dropdown
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
                      DropdownButtonFormField<String>(
                        // ignore: deprecated_member_use
                        value: _availableModels.contains(_selectedModel)
                            ? _selectedModel
                            : _availableModels.firstOrNull,
                        dropdownColor:
                            isDark ? const Color(0xFF222222) : Colors.white,
                        decoration: _buildInputDecoration(isDark),
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 14,
                          color: isDark
                              ? const Color(0xFFF3F3F3)
                              : AppTheme.textPrimary,
                        ),
                        items: _availableModels
                            .map((m) => DropdownMenuItem(
                                  value: m,
                                  child: Text(m),
                                ))
                            .toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _selectedModel = val);
                          }
                        },
                      ),
                      const SizedBox(height: 16),

                      // Test feedback banner
                      if (_testMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: _testOk == true
                                ? const Color(0xFF2D6A4F).withValues(alpha: 0.15)
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
                                    fontFamily: AppTheme.fontUI,
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

                      // Actions: Check Connection + Save & Apply
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _testing ? null : _testConnection,
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                side: BorderSide(
                                  color: isDark
                                      ? const Color(0xFF333333)
                                      : AppTheme.border,
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
                                        fontFamily: AppTheme.fontUI,
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
                                        fontFamily: AppTheme.fontUI,
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
