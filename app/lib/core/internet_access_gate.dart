import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Verifies a real HTTPS request to Wikimedia, the source used by Athena's
/// online context features. A connected Wi-Fi icon alone does not prove that
/// the internet is reachable.
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
      baseUrl: 'https://en.wikipedia.org',
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      sendTimeout: const Duration(seconds: 5),
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
    try {
      final response = await _probe.get<Map<String, dynamic>>(
        '/w/api.php',
        queryParameters: const {
          'action': 'query',
          'format': 'json',
          'titles': 'Main_Page',
          'origin': '*',
        },
      );
      reachable = response.statusCode == 200 && response.data?['query'] is Map;
    } on DioException {
      // Offline, captive-portal, DNS, and TLS failures use one clear prompt.
    } catch (_) {
      // A failed probe must not crash application startup.
    }

    if (!mounted) return;
    setState(() {
      _online = reachable;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // On web the Wikipedia CORS probe is always blocked by the browser;
    // skip the gate and render child directly. Connectivity checks only
    // make sense on mobile where Dio can perform raw socket probes.
    if (kIsWeb) return widget.child;
    if (_online) return widget.child;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F5EF),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 76,
                    height: 76,
                    decoration: const BoxDecoration(
                      color: Color(0xFFD7FB61),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _checking
                          ? Icons.wifi_find_rounded
                          : Icons.wifi_off_rounded,
                      size: 36,
                      color: const Color(0xFF171914),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    _checking
                        ? 'Checking your connection'
                        : 'Connect to the internet',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF171914),
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _checking
                        ? 'Athena is checking that online reading context is available.'
                        : 'Turn on Wi-Fi or mobile data, then try again. Athena uses the internet for grounded context.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF66685F),
                      fontSize: 15,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_checking)
                    const CircularProgressIndicator()
                  else ...[
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: _checkInternet,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try again'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFD7FB61),
                          foregroundColor: const Color(0xFF171914),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: () => setState(() => _online = true),
                      icon: const Icon(Icons.menu_book_rounded, size: 18),
                      label: const Text('Continue offline · Read local books'),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF171914),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
