Uri secureEndpoint(String value, {bool websocket = false}) {
  final uri = Uri.parse(value);
  final secure = websocket ? 'wss' : 'https';
  final localScheme = websocket ? 'ws' : 'http';
  final loopback = const {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
  if (uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (uri.scheme != secure && !(loopback && uri.scheme == localScheme))) {
    throw ArgumentError('TLS is required outside the local test server');
  }
  return uri;
}
