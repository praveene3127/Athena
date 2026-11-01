import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<String?> discoverServerImpl({int timeoutMs = 800}) async {
  final candidateIps = <String>{};

  // Known default laptop LAN IP
  candidateIps.add('192.168.1.61');

  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (ip.startsWith('192.168.') ||
            ip.startsWith('10.') ||
            ip.startsWith('172.')) {
          final lastDot = ip.lastIndexOf('.');
          if (lastDot > 0) {
            final prefix = ip.substring(0, lastDot + 1);
            candidateIps.add('${prefix}1');
            candidateIps.add('${prefix}61');
            candidateIps.add('${prefix}100');
            candidateIps.add('${prefix}101');
            candidateIps.add('${prefix}2');

            // Probe primary IP ranges in home subnets
            for (int i = 1; i <= 40; i++) {
              candidateIps.add('$prefix$i');
            }
            for (int i = 50; i <= 80; i++) {
              candidateIps.add('$prefix$i');
            }
          }
        }
      }
    }
  } catch (_) {}

  final client = HttpClient()
    ..connectionTimeout = Duration(milliseconds: timeoutMs);

  final completer = Completer<String?>();
  int pending = candidateIps.length;
  if (pending == 0) return null;

  for (final host in candidateIps) {
    _probeHost(client, host, 8000).then((found) {
      if (found && !completer.isCompleted) {
        completer.complete('http://$host:8000');
      } else {
        pending--;
        if (pending <= 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }
    }).catchError((_) {
      pending--;
      if (pending <= 0 && !completer.isCompleted) {
        completer.complete(null);
      }
    });
  }

  return Future.any([
    completer.future,
    Future.delayed(const Duration(milliseconds: 2000), () => null),
  ]);
}

Future<bool> _probeHost(HttpClient client, String host, int port) async {
  try {
    final uri = Uri.parse('http://$host:$port/api/health');
    final req = await client.getUrl(uri);
    final resp = await req.close();
    if (resp.statusCode == 200) {
      final body = await resp.transform(utf8.decoder).join();
      if (body.contains('"status":"ok"') || body.contains('"database"')) {
        return true;
      }
    }
  } catch (_) {}
  return false;
}

