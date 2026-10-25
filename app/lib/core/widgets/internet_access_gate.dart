import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:athena/features/settings/screens/connection_setup_screen.dart';
import 'package:athena/core/widgets/athena_avatar.dart';
import 'package:athena/core/config/config.dart';
import 'package:athena/core/theme/theme.dart';

/// Verifies network and backend connectivity for grounded AI features.
/// If unreachable, displays Athena's signature double-bezel offline screen
/// with options to retry, continue reading local books, or configure the backend.
class InternetAccessGate extends StatefulWidget {
  const InternetAccessGate({required this.child, super.key});

  final Widget child;

  @override
  State<InternetAccessGate> createState() => _InternetAccessGateState();
}

class _InternetAccessGateState extends State<InternetAccessGate>
    with WidgetsBindingObserver {
  final Dio _probe = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 4),
      sendTimeout: const Duration(seconds: 4),
      responseType: ResponseType.json,
    ),
  );

  bool _checking = false;
  bool _online = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb) {
      _checkInternet();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _probe.close(force: true);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_online) {
      _checkInternet();
    }
  }

  Future<void> _checkInternet() async {
    if (_checking) return;
    setState(() => _checking = true);

    var reachable = false;

    // 1. Probe Athena Backend first if configured
    final backendUrl = AppConfig.apiBaseUrl;
    if (backendUrl.isNotEmpty) {
      try {
        final res = await _probe.get<Map<String, dynamic>>(
          '$backendUrl/api/health',
          options: Options(
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
          ),
        );
        if (res.statusCode == 200) {
          reachable = true;
        }
      } catch (_) {}
    }

    // 2. If backend probe failed, check public internet via Wikipedia API
    if (!reachable) {
      try {
        final response = await _probe.get<Map<String, dynamic>>(
          'https://en.wikipedia.org/w/api.php',
          queryParameters: const {
            'action': 'query',
            'format': 'json',
            'titles': 'Main_Page',
            'origin': '*',
          },
          options: Options(
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 3),
          ),
        );
        reachable =
            response.statusCode == 200 && response.data?['query'] is Map;
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _online = reachable;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // On web, CORS prevents external probes; allow child directly
    if (kIsWeb) return widget.child;
    if (_online) return widget.child;

    final isDark = AppTheme.isDark(context);

    return Scaffold(
      backgroundColor: AppTheme.bgOf(context),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Container(
                // Outer Shell (Double-Bezel Architecture)
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color:
                      isDark ? const Color(0xFF181818) : const Color(0xFFF7F6F2),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: isDark
                        ? const Color(0xFF282828)
                        : const Color(0xFFE5E7DC),
                    width: 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: isDark ? Colors.black45 : const Color(0x0A141714),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Container(
                  // Inner Core
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF202020) : Colors.white,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Status Badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4.5),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF2DD4BF).withValues(alpha: 0.15)
                              : const Color(0xFF005E54).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isDark
                                ? const Color(0xFF2DD4BF).withValues(alpha: 0.3)
                                : const Color(0xFF005E54)
                                    .withValues(alpha: 0.2),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _checking
                                  ? Icons.wifi_find_rounded
                                  : Icons.wifi_off_rounded,
                              size: 13,
                              color: isDark
                                  ? const Color(0xFF2DD4BF)
                                  : const Color(0xFF005E54),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _checking ? 'TESTING LINK' : 'OFFLINE MODE',
                              style: TextStyle(
                                fontFamily: AppTheme.fontUI,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.8,
                                color: isDark
                                    ? const Color(0xFF2DD4BF)
                                    : const Color(0xFF005E54),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Athena Mascot
                      AthenaAvatar(
                        expression: _checking
                            ? AthenaExpression.thinking
                            : AthenaExpression.sleepy,
                        size: 64,
                        isBreathing: true,
                        showBezel: true,
                      ),
                      const SizedBox(height: 18),

                      // Title
                      Text(
                        _checking ? 'Checking Connection' : 'Connection Offline',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: AppTheme.fontDisplay,
                          fontSize: 23,
                          color: isDark ? Colors.white : AppTheme.ink,
                          fontWeight: FontWeight.w400,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Description
                      Text(
                        _checking
                            ? 'Athena is verifying connection to your reading backend and knowledge network...'
                            : 'Turn on Wi-Fi or mobile data to generate grounded context cards, or continue offline to read your saved library.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: AppTheme.fontUI,
                          fontSize: 13,
                          height: 1.45,
                          color: isDark
                              ? const Color(0xFF9E9E9E)
                              : AppTheme.textMuted,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Primary Button: Try Again
                      InkWell(
                        onTap: _checking ? null : _checkInternet,
                        borderRadius: BorderRadius.circular(24),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 13),
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
                          child: _checking
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      isDark
                                          ? const Color(0xFF141714)
                                          : Colors.white,
                                    ),
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.refresh_rounded,
                                      size: 16,
                                      color: isDark
                                          ? const Color(0xFF141714)
                                          : Colors.white,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Try Again',
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
                      const SizedBox(height: 10),

                      // Secondary Button: Continue Offline
                      InkWell(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() => _online = true);
                        },
                        borderRadius: BorderRadius.circular(24),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF181818)
                                : const Color(0xFFF7F6F2),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: isDark
                                  ? const Color(0xFF282828)
                                  : const Color(0xFFE5E7DC),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.menu_book_rounded,
                                size: 15,
                                color: isDark ? Colors.white : AppTheme.ink,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Continue Offline · Read Books',
                                style: TextStyle(
                                  fontFamily: AppTheme.fontUI,
                                  color: isDark ? Colors.white : AppTheme.ink,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Tertiary: Configure Server
                      TextButton.icon(
                        onPressed: () async {
                          HapticFeedback.selectionClick();
                          final changed =
                              await Navigator.of(context).push<bool>(
                            MaterialPageRoute(
                              builder: (_) => const ConnectionSetupScreen(),
                            ),
                          );
                          if (changed == true) {
                            _checkInternet();
                          }
                        },
                        icon: Icon(
                          Icons.dns_outlined,
                          size: 14,
                          color: isDark
                              ? const Color(0xFF2DD4BF)
                              : const Color(0xFF005E54),
                        ),
                        label: Text(
                          'Configure Backend Link',
                          style: TextStyle(
                            fontFamily: AppTheme.fontUI,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? const Color(0xFF2DD4BF)
                                : const Color(0xFF005E54),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
