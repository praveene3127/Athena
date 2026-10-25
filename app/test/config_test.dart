import 'package:flutter_test/flutter_test.dart';
import 'package:athena/core/config/config.dart';

void main() {
  test('web on LAN IP uses page origin, not loopback', () {
    expect(
      AppConfig.resolveBaseUrl(
        isWeb: true,
        host: '192.168.1.5',
        origin: 'http://192.168.1.5:8000',
      ),
      'http://192.168.1.5:8000',
    );
  });

  test('web on a public tunnel uses page origin', () {
    expect(
      AppConfig.resolveBaseUrl(
        isWeb: true,
        host: 'athena.example.com',
        origin: 'https://athena.example.com',
      ),
      'https://athena.example.com',
    );
  });

  test('web on localhost uses same origin so :8080 still hits /api', () {
    expect(
      AppConfig.resolveBaseUrl(
        isWeb: true,
        host: 'localhost',
        origin: 'http://localhost:8080',
      ),
      'http://localhost:8080',
    );
  });

  test('native uses saved Server URL then USB loopback', () {
    expect(
      AppConfig.resolveBaseUrl(isWeb: false, host: '', origin: ''),
      'http://127.0.0.1:8000',
    );
    expect(
      AppConfig.resolveBaseUrl(
        isWeb: false,
        host: '',
        origin: '',
        runtime: 'http://192.168.1.5:8000',
      ),
      'http://192.168.1.5:8000',
    );
  });
}
