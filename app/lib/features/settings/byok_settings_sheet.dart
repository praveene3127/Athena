import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/theme.dart';
import '../../models/ai_provider.dart';
import '../../services/api_client.dart';
import '../../widgets/athena_avatar.dart';

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

class _BYOKSettingsSheetState extends State<BYOKSettingsSheet>
    with SingleTickerProviderStateMixin {
  late final ApiClient _api;
  late final TabController _tabController;

  bool _loading = true;
  bool _saving = false;

  // Primary Provider State
  String _primaryProvider = 'openrouter';
  final _primaryKeyController = TextEditingController();
  final _primaryModelController = TextEditingController();
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
  final _fallbackModelController = TextEditingController();
  final _fallbackBaseUrlController = TextEditingController();
  bool _obscureFallbackKey = true;
  List<AIModelOption> _fallbackModels = [];
  bool _fetchingFallbackModels = false;
  bool _testingFallback = false;
  String? _fallbackTestMessage;
  bool? _fallbackTestOk;

  @override
  void initState() {
    super.initState();
    _api = widget.apiClient ?? ApiClient();
    _tabController = TabController(length: 2, vsync: this);
    _loadConfig();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _primaryKeyController.dispose();
    _primaryModelController.dispose();
    _primaryBaseUrlController.dispose();
    _fallbackKeyController.dispose();
    _fallbackModelController.dispose();
    _fallbackBaseUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    setState(() {
      _loading = true;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final config = await _api.getAIConfig();
      if (!mounted) return;

      final savedLocalPrimaryProvider = prefs.getString('athena_ai_primary_provider');
      final savedLocalPrimaryKey = prefs.getString('athena_ai_primary_api_key');
      final savedLocalPrimaryModel = prefs.getString('athena_ai_primary_model');
      final savedLocalPrimaryBaseUrl = prefs.getString('athena_ai_primary_base_url');

      final savedLocalFallbackProvider = prefs.getString('athena_ai_fallback_provider');
      final savedLocalFallbackKey = prefs.getString('athena_ai_fallback_api_key');
      final savedLocalFallbackModel = prefs.getString('athena_ai_fallback_model');
      final savedLocalFallbackBaseUrl = prefs.getString('athena_ai_fallback_base_url');

      setState(() {
        _primaryProvider = config.primaryProvider.isNotEmpty
            ? config.primaryProvider
            : (savedLocalPrimaryProvider ?? 'gemini');

        _primaryModelController.text = config.primaryModel.isNotEmpty
            ? config.primaryModel
            : (savedLocalPrimaryModel ?? '');

        _primaryBaseUrlController.text = config.primaryBaseUrl ?? (savedLocalPrimaryBaseUrl ?? '');

        if (savedLocalPrimaryKey != null && savedLocalPrimaryKey.isNotEmpty) {
          _primaryKeyController.text = savedLocalPrimaryKey;
        } else if (config.primaryApiKeyMasked != null) {
          _primaryKeyController.text = config.primaryApiKeyMasked!;
        }

        if (config.fallbackProvider != null || (savedLocalFallbackProvider != null && savedLocalFallbackProvider.isNotEmpty)) {
          _enableFallback = true;
          _fallbackProvider = config.fallbackProvider ?? (savedLocalFallbackProvider ?? 'groq');
          _fallbackModelController.text = config.fallbackModel ?? (savedLocalFallbackModel ?? '');
          _fallbackBaseUrlController.text = config.fallbackBaseUrl ?? (savedLocalFallbackBaseUrl ?? '');
          if (savedLocalFallbackKey != null && savedLocalFallbackKey.isNotEmpty) {
            _fallbackKeyController.text = savedLocalFallbackKey;
          } else if (config.fallbackApiKeyMasked != null) {
            _fallbackKeyController.text = config.fallbackApiKeyMasked!;
          }
        }
        _loading = false;
      });

      // If backend was empty but local preferences has verified credentials, auto-sync to backend immediately
      if (!config.isConfigured && savedLocalPrimaryKey != null && savedLocalPrimaryKey.isNotEmpty) {
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

    // Require an API key for cloud providers before attempting fetch
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
          _primaryTestMessage = 'Please enter an API key first';
          _primaryModels = [];
        } else {
          _fallbackTestOk = false;
          _fallbackTestMessage = 'Please enter an API key first';
          _fallbackModels = [];
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
      final result = await _api.testAIConnection(
        provider: provider,
        apiKey: key.isNotEmpty ? key : null,
        model: model.isNotEmpty ? model : null,
        baseUrl: baseUrl,
      );

      if (!mounted) return;
      final ok = result['ok'] as bool? ?? false;
      final latency = result['latency_ms'] as int? ?? 0;
      final msg = result['message'] as String? ?? (ok ? 'Verified' : 'Failed');

      if (ok) {
        List<AIModelOption> liveModels = [];
        if (result['models'] is List && (result['models'] as List).isNotEmpty) {
          liveModels = (result['models'] as List)
              .map((item) =>
                  AIModelOption.fromJson(item as Map<String, dynamic>))
              .toList();
        } else {
          liveModels = await _fetchModels(isPrimary: isPrimary);
        }

        setState(() {
          if (isPrimary) {
            _testingPrimary = false;
            _primaryTestOk = true;
            _primaryModels = liveModels;
            if (_primaryModelController.text.isEmpty && liveModels.isNotEmpty) {
              _primaryModelController.text = liveModels.first.id;
            }
            _primaryTestMessage = liveModels.isNotEmpty
                ? 'Saved & Connected in ${latency}ms (${liveModels.length} models discovered)'
                : 'Saved & Connected in ${latency}ms';
          } else {
            _testingFallback = false;
            _fallbackTestOk = true;
            _fallbackModels = liveModels;
            if (_fallbackModelController.text.isEmpty && liveModels.isNotEmpty) {
              _fallbackModelController.text = liveModels.first.id;
            }
            _fallbackTestMessage = liveModels.isNotEmpty
                ? 'Saved & Connected in ${latency}ms (${liveModels.length} models discovered)'
                : 'Saved & Connected in ${latency}ms';
          }
        });

        // Auto-persist verified credentials immediately to SharedPreferences & backend
        _persistToLocalStorageAndBackend().catchError((_) {});
        widget.onConfigSaved?.call();
      } else {
        setState(() {
          if (isPrimary) {
            _testingPrimary = false;
            _primaryTestOk = false;
            _primaryTestMessage = msg;
            _primaryModels = [];
          } else {
            _testingFallback = false;
            _fallbackTestOk = false;
            _fallbackTestMessage = msg;
            _fallbackModels = [];
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (isPrimary) {
          _testingPrimary = false;
          _primaryTestOk = false;
          _primaryTestMessage = 'Connection failed: $e';
          _primaryModels = [];
        } else {
          _testingFallback = false;
          _fallbackTestOk = false;
          _fallbackTestMessage = 'Connection failed: $e';
          _fallbackModels = [];
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

    final fallbackKeyToSend = _enableFallback
        ? ((_fallbackKeyController.text.trim().isNotEmpty &&
                !_fallbackKeyController.text.contains('...'))
            ? _fallbackKeyController.text.trim()
            : prefs.getString('athena_ai_fallback_api_key'))
        : null;

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
    setState(() {
      _saving = true;
    });

    try {
      await _persistToLocalStorageAndBackend();

      if (!mounted) return;
      setState(() {
        _saving = false;
      });

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
            content: Text('AI Intelligence Engines updated and saved successfully.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
      });
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
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return _ModelSelectionModal(
          models: models,
          currentModel: controller.text,
          provider: provider,
          hasKey: key.isNotEmpty,
          onRefresh: key.isNotEmpty ? () => _fetchModels(isPrimary: isPrimary) : null,
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
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final maxHeight = MediaQuery.of(context).size.height * 0.88;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      margin: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: bottomInset > 0 ? bottomInset + 8 : 16,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.border, width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 28,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: _loading
            ? const SizedBox(
                height: 280,
                child: Center(
                  child: CircularProgressIndicator(color: AppTheme.ink),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(),
                  const Divider(height: 1, color: AppTheme.hairline),
                  _buildTabBar(),
                  Flexible(
                    child: TabBarView(
                      controller: _tabController,
                      children: [
                        _buildPrimaryTab(),
                        _buildFallbackTab(),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: AppTheme.hairline),
                  _buildFooter(),
                ],
              ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
      child: Row(
        children: [
          const AthenaAvatar(
            expression: AthenaExpression.happy,
            size: 32,
            showBezel: true,
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Intelligence Engines (BYOK)',
                  style: TextStyle(
                    fontFamily: AppTheme.fontDisplay,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.ink,
                  ),
                ),
                Text(
                  'Open-Source Multi-Provider AI • Dual Failover',
                  style: TextStyle(
                    fontFamily: AppTheme.fontUI,
                    fontSize: 12,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                size: 20, color: AppTheme.textMuted),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      color: AppTheme.surfaceWarm,
      child: TabBar(
        controller: _tabController,
        labelColor: AppTheme.ink,
        unselectedLabelColor: AppTheme.textMuted,
        indicatorColor: AppTheme.ink,
        indicatorWeight: 2,
        labelStyle: const TextStyle(
          fontFamily: AppTheme.fontUI,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
        tabs: const [
          Tab(text: 'PRIMARY ENGINE'),
          Tab(text: 'FAILOVER BACKUP'),
        ],
      ),
    );
  }

  Widget _buildPrimaryTab() {
    final info = kSupportedProviders.firstWhere(
      (p) => p.id == _primaryProvider,
      orElse: () => kSupportedProviders.first,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionLabel('SELECT PROVIDER'),
          const SizedBox(height: 8),
          _buildProviderChips(
            selectedId: _primaryProvider,
            onSelected: (id) {
              setState(() {
                _primaryProvider = id;
                _primaryModelController.text = '';
                _primaryTestMessage = null;
                _primaryTestOk = null;
                _primaryModels = [];
              });
            },
          ),
          const SizedBox(height: 18),
          _buildApiKeyField(
            controller: _primaryKeyController,
            obscureText: _obscurePrimaryKey,
            onToggleObscure: () {
              setState(() => _obscurePrimaryKey = !_obscurePrimaryKey);
            },
            placeholder: info.keyPlaceholder,
            docUrl: info.docUrl,
            providerName: info.name,
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
            const SizedBox(height: 14),
            _buildBaseUrlField(_primaryBaseUrlController),
          ],
          const SizedBox(height: 18),
          _buildModelSelector(
            isPrimary: true,
            modelController: _primaryModelController,
            models: _primaryModels,
            isFetching: _fetchingPrimaryModels,
          ),
          const SizedBox(height: 18),
          _buildTestConnectionButton(
            isPrimary: true,
            testing: _testingPrimary,
            testOk: _primaryTestOk,
            testMessage: _primaryTestMessage,
          ),
        ],
      ),
    );
  }

  Widget _buildFallbackTab() {
    final info = kSupportedProviders.firstWhere(
      (p) => p.id == _fallbackProvider,
      orElse: () => kSupportedProviders.first,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceWarm,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Automatic Failover Backup',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: AppTheme.ink,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Automatically routes requests here if primary engine hits quota or rate limits.',
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 11,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _enableFallback,
                  activeThumbColor: AppTheme.ink,
                  onChanged: (val) {
                    setState(() {
                      _enableFallback = val;
                      if (!val) {
                        _fallbackModels = [];
                      }
                    });
                  },
                ),
              ],
            ),
          ),
          if (_enableFallback &&
              _fallbackKeyController.text.trim().isEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 18, color: Color(0xFFB45309)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No backup key entered. Athena works completely fine using only your primary API key. Failover will remain standby until a backup key is provided.',
                      style: TextStyle(
                        fontFamily: AppTheme.fontUI,
                        fontSize: 11,
                        color: Color(0xFF92400E),
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_enableFallback) ...[
            const SizedBox(height: 20),
            _buildSectionLabel('SELECT BACKUP PROVIDER'),
            const SizedBox(height: 8),
            _buildProviderChips(
              selectedId: _fallbackProvider,
              onSelected: (id) {
                setState(() {
                  _fallbackProvider = id;
                  _fallbackModelController.text = '';
                  _fallbackTestMessage = null;
                  _fallbackTestOk = null;
                  _fallbackModels = [];
                });
              },
            ),
            const SizedBox(height: 18),
            _buildApiKeyField(
              controller: _fallbackKeyController,
              obscureText: _obscureFallbackKey,
              onToggleObscure: () {
                setState(() => _obscureFallbackKey = !_obscureFallbackKey);
              },
              placeholder: info.keyPlaceholder,
              docUrl: info.docUrl,
              providerName: info.name,
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
              const SizedBox(height: 14),
              _buildBaseUrlField(_fallbackBaseUrlController),
            ],
            const SizedBox(height: 18),
            _buildModelSelector(
              isPrimary: false,
              modelController: _fallbackModelController,
              models: _fallbackModels,
              isFetching: _fetchingFallbackModels,
            ),
            const SizedBox(height: 18),
            _buildTestConnectionButton(
              isPrimary: false,
              testing: _testingFallback,
              testOk: _fallbackTestOk,
              testMessage: _fallbackTestMessage,
            ),
          ],
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

  Widget _buildProviderChips({
    required String selectedId,
    required ValueChanged<String> onSelected,
  }) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: kSupportedProviders.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (ctx, i) {
          final prov = kSupportedProviders[i];
          final isSelected = prov.id == selectedId;

          return InkWell(
            onTap: () => onSelected(prov.id),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? AppTheme.ink : AppTheme.surfaceWarm,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected ? AppTheme.ink : AppTheme.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    prov.name,
                    style: TextStyle(
                      fontFamily: AppTheme.fontUI,
                      fontSize: 12,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: isSelected ? Colors.white : AppTheme.ink,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? Colors.white.withValues(alpha: 0.2)
                          : AppTheme.border,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      prov.tag,
                      style: TextStyle(
                        fontFamily: AppTheme.fontUI,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: isSelected ? Colors.white : AppTheme.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
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
              style: const TextStyle(
                fontFamily: AppTheme.fontUI,
                fontSize: 10,
                color: AppTheme.textMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceWarm,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: TextField(
            controller: controller,
            obscureText: obscureText,
            onChanged: onChanged,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: AppTheme.ink,
            ),
            decoration: InputDecoration(
              hintText: placeholder,
              hintStyle: const TextStyle(
                fontFamily: AppTheme.fontUI,
                fontSize: 12,
                color: AppTheme.textMuted,
              ),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              suffixIcon: IconButton(
                icon: Icon(
                  obscureText
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 18,
                  color: AppTheme.textMuted,
                ),
                onPressed: onToggleObscure,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBaseUrlField(TextEditingController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel('CUSTOM BASE URL'),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceWarm,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: TextField(
            controller: controller,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: AppTheme.ink,
            ),
            decoration: const InputDecoration(
              hintText: 'http://localhost:11434/v1',
              hintStyle: TextStyle(
                fontFamily: AppTheme.fontUI,
                fontSize: 12,
                color: AppTheme.textMuted,
              ),
              border: InputBorder.none,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
  }) {
    final currentVal = modelController.text;
    final hasModels = models.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildSectionLabel(hasModels ? 'ACTIVE MODEL' : 'MODEL SELECTION'),
            if (isFetching)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppTheme.ink),
              )
            else if (hasModels)
              InkWell(
                onTap: () => _fetchModels(isPrimary: isPrimary),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.refresh_rounded,
                        size: 12, color: AppTheme.textMuted),
                    const SizedBox(width: 4),
                    Text(
                      '${models.length} live models',
                      style: const TextStyle(
                        fontFamily: AppTheme.fontUI,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              )
            else
              const Text(
                '0 live models',
                style: TextStyle(
                  fontFamily: AppTheme.fontUI,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textMuted,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: () => _showModelPicker(isPrimary: isPrimary),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceWarm,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              (hasModels && currentVal.isNotEmpty)
                                  ? currentVal
                                  : 'No model selected',
                              style: TextStyle(
                                fontFamily: AppTheme.fontUI,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: (hasModels && currentVal.isNotEmpty)
                                    ? AppTheme.ink
                                    : AppTheme.textMuted,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (hasModels && currentVal.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
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
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasModels
                            ? 'Tap to browse live provider catalog (${models.length} models)'
                            : 'Test connection with your key to discover models',
                        style: const TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 11,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.keyboard_arrow_down_rounded,
                    size: 20, color: AppTheme.ink),
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
  }) {
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed:
              testing ? null : () => _testConnection(isPrimary: isPrimary),
          icon: testing
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppTheme.ink),
                )
              : const Icon(Icons.flash_on_rounded, size: 16),
          label: Text(testing ? 'Testing...' : 'Test Connection'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            minimumSize: const Size(0, 38),
          ),
        ),
        const SizedBox(width: 12),
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _saving ? null : _saveConfig,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Save & Apply'),
          ),
        ],
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                    if (widget.onRefresh != null && !_customMode && _models.isNotEmpty)
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
                        borderRadius: BorderRadius.circular(10),
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
                    borderRadius: BorderRadius.circular(12),
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
