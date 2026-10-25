import 'package:flutter/material.dart';
import 'package:athena/core/config/config.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/services/secure_storage_service.dart';

class ConnectionSetupScreen extends StatefulWidget {
  const ConnectionSetupScreen({super.key});

  @override
  State<ConnectionSetupScreen> createState() => _ConnectionSetupScreenState();
}

class _ConnectionSetupScreenState extends State<ConnectionSetupScreen> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _obscureToken = true;
  bool _testing = false;
  bool _saving = false;
  String? _testResult;
  bool? _testSuccess;

  @override
  void initState() {
    super.initState();
    _loadCurrentSettings();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentSettings() async {
    final storage = SecureStorageService.instance;
    final url = await storage.getBackendUrl();
    final token = await storage.getContextToken();
    if (mounted) {
      setState(() {
        _urlController.text = url.isNotEmpty ? url : AppConfig.apiBaseUrl;
        if (token != null) _tokenController.text = token;
      });
    }
  }

  Future<void> _testConnection() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _testResult = null;
      _testSuccess = null;
    });

    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();

    final result = await SecureStorageService.instance.testConnection(
      testUrl: url,
      testToken: token,
    );

    if (mounted) {
      setState(() {
        _testing = false;
        _testSuccess = result.success;
        _testResult = result.message;
      });
    }
  }

  Future<void> _saveSettings() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a backend URL.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    if (!SecureStorageService.isSecureUrl(url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Remote backend URLs must use HTTPS to safeguard privacy.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final storage = SecureStorageService.instance;
    await storage.setBackendUrl(url);
    await storage.setContextToken(_tokenController.text.trim());
    await AppConfig.setBaseUrl(url);

    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connection settings securely saved to Keystore.'),
          backgroundColor: AppTheme.figmaBlack,
        ),
      );
      Navigator.of(context).pop(true);
    }
  }

  Widget _buildPresetChip(String label, String url) {
    final currentUrl =
        _urlController.text.trim().replaceAll(RegExp(r'/+$'), '');
    final targetUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    final isSelected = currentUrl == targetUrl;

    return InkWell(
      onTap: () {
        setState(() {
          _urlController.text = url;
          _testResult = null;
          _testSuccess = null;
        });
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF005E54).withValues(alpha: 0.12)
              : const Color(0xFFF2F0E8),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color:
                isSelected ? const Color(0xFF005E54) : const Color(0xFFE5E7DC),
            width: isSelected ? 1.2 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color:
                isSelected ? const Color(0xFF005E54) : const Color(0xFF333333),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFCFBF7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFCFBF7),
        elevation: 0,
        leading: Container(
          margin: const EdgeInsets.only(left: 16),
          child: IconButton(
            icon: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFF2F0E8),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFE5E7DC)),
              ),
              child: const Icon(Icons.arrow_back_rounded,
                  color: Color(0xFF141714), size: 18),
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        title: const Text(
          'AI & Backend Connection',
          style: TextStyle(
            fontFamily: 'DM Serif Display',
            color: Color(0xFF141714),
            fontSize: 20,
            letterSpacing: -0.2,
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              children: [
                // Double-Bezel Bento Header
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F6F2),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: const Color(0xFFE5E7DC)),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFECEEE4)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF005E54).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            Icons.vpn_key_rounded,
                            color: Color(0xFF005E54),
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'AUTHENTICATED GATEWAY',
                                style: TextStyle(
                                  color: Color(0xFF005E54),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.0,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Secure Device Setup',
                                style: TextStyle(
                                  fontFamily: 'DM Serif Display',
                                  color: Color(0xFF141714),
                                  fontSize: 19,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                'Keys stay on your backend; proxy tokens are stored securely in device Keystore.',
                                style: TextStyle(
                                  color: Color(0xFF666666),
                                  fontSize: 12,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Double-Bezel Fields Card
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F6F2),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: const Color(0xFFE5E7DC)),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFECEEE4)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Backend Endpoint URL',
                          style: TextStyle(
                            color: Color(0xFF141714),
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _urlController,
                          keyboardType: TextInputType.url,
                          style: const TextStyle(
                              color: Color(0xFF141714), fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'http://localhost:8000',
                            filled: true,
                            fillColor: const Color(0xFFFBFBF9),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide:
                                  const BorderSide(color: Color(0xFFE5E7DC)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide:
                                  const BorderSide(color: Color(0xFFE5E7DC)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(
                                  color: Color(0xFF005E54), width: 1.5),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Quick Presets:',
                          style: TextStyle(
                            color: Color(0xFF555555),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            _buildPresetChip(
                                'Localhost (USB / this PC)',
                                'http://127.0.0.1:8000'),
                            _buildPresetChip(
                                'Android emulator', 'http://10.0.2.2:8000'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'On the same Wi-Fi, enter http://<laptop-LAN-IP>:8000. A public tunnel URL is optional when you are not on that network.',
                          style:
                              TextStyle(color: Color(0xFF888888), fontSize: 11),
                        ),
                        const SizedBox(height: 18),
                        const Text(
                          'Context Proxy Token (X-Athena-Context-Token)',
                          style: TextStyle(
                            color: Color(0xFF141714),
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _tokenController,
                          obscureText: _obscureToken,
                          style: const TextStyle(
                              color: Color(0xFF141714), fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'Enter ATHENA_CONTEXT_PROXY_TOKEN',
                            filled: true,
                            fillColor: const Color(0xFFFBFBF9),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureToken
                                    ? Icons.visibility_off_rounded
                                    : Icons.visibility_rounded,
                                color: const Color(0xFF888888),
                                size: 20,
                              ),
                              onPressed: () => setState(
                                  () => _obscureToken = !_obscureToken),
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide:
                                  const BorderSide(color: Color(0xFFE5E7DC)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide:
                                  const BorderSide(color: Color(0xFFE5E7DC)),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: const BorderSide(
                                  color: Color(0xFF005E54), width: 1.5),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Configured in backend/.env. Authorizes search-grounded Gemini context without baking keys into the mobile client.',
                          style:
                              TextStyle(color: Color(0xFF888888), fontSize: 11),
                        ),
                        if (_testResult != null) ...[
                          const SizedBox(height: 18),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: (_testSuccess == true)
                                  ? const Color(0xFF005E54)
                                      .withValues(alpha: 0.08)
                                  : Colors.redAccent.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: (_testSuccess == true)
                                    ? const Color(0xFF005E54)
                                        .withValues(alpha: 0.3)
                                    : Colors.redAccent.withValues(alpha: 0.3),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  (_testSuccess == true)
                                      ? Icons.check_circle_rounded
                                      : Icons.error_outline_rounded,
                                  color: (_testSuccess == true)
                                      ? const Color(0xFF005E54)
                                      : Colors.redAccent,
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _testResult!,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: (_testSuccess == true)
                                          ? const Color(0xFF141714)
                                          : Colors.redAccent.shade700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 22),
                        Row(
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: _testing ? null : _testConnection,
                                borderRadius: BorderRadius.circular(24),
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF7F6F2),
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                        color: const Color(0xFFE5E7DC)),
                                  ),
                                  alignment: Alignment.center,
                                  child: _testing
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                    Color(0xFF141714)),
                                          ),
                                        )
                                      : const Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(Icons.cable_rounded,
                                                size: 16,
                                                color: Color(0xFF141714)),
                                            SizedBox(width: 8),
                                            Text(
                                              'Test Link',
                                              style: TextStyle(
                                                color: Color(0xFF141714),
                                                fontWeight: FontWeight.w700,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: InkWell(
                                onTap: _saving ? null : _saveSettings,
                                borderRadius: BorderRadius.circular(24),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF005E54),
                                    borderRadius: BorderRadius.circular(24),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF005E54)
                                            .withValues(alpha: 0.18),
                                        blurRadius: 10,
                                        offset: const Offset(0, 3),
                                      ),
                                    ],
                                  ),
                                  alignment: Alignment.center,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        _saving ? 'Saving...' : 'Save Settings',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        width: 26,
                                        height: 26,
                                        decoration: BoxDecoration(
                                          color: Colors.white
                                              .withValues(alpha: 0.2),
                                          shape: BoxShape.circle,
                                        ),
                                        alignment: Alignment.center,
                                        child: _saving
                                            ? const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  valueColor:
                                                      AlwaysStoppedAnimation<
                                                          Color>(Colors.white),
                                                ),
                                              )
                                            : const Icon(Icons.check_rounded,
                                                size: 14, color: Colors.white),
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
                const SizedBox(height: 18),

                // Double-Bezel Security Callout
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F6F2),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: const Color(0xFFE5E7DC)),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFECEEE4)),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.shield_outlined,
                            color: Color(0xFF005E54), size: 20),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Athena guarantees that raw book PDFs stay private on this device. When you ask a passage question or view a grounded context card, only the specific passage excerpt is sent to your authenticated backend.',
                            style: TextStyle(
                                color: Color(0xFF666666),
                                fontSize: 12,
                                height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
