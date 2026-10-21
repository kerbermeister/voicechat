import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/transport.dart';

void main() {
  test('Remote endpoints require TLS; local lab stays usable', () {
    expect(secureEndpoint('https://example.com').scheme, 'https');
    expect(secureEndpoint('http://localhost:8008').host, 'localhost');
    expect(secureEndpoint('wss://example.com', websocket: true).scheme, 'wss');
    for (final url in [
      'http://example.com',
      'https://user:password@example.com',
      'file:///tmp/a',
    ]) {
      expect(() => secureEndpoint(url), throwsArgumentError);
    }
    expect(
      () => secureEndpoint('ws://example.com', websocket: true),
      throwsArgumentError,
    );
  });
}
