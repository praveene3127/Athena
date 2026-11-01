import 'lan_discovery_stub.dart'
    if (dart.library.io) 'lan_discovery_io.dart';

abstract class LanDiscovery {
  /// Probes the local Wi-Fi / LAN network for a running Athena backend server.
  static Future<String?> discoverServer({int timeoutMs = 800}) =>
      discoverServerImpl(timeoutMs: timeoutMs);
}

