/// Media key lifetimes use the control server clock, not two device clocks.
/// Keep the legacy timestamp for peers that have not updated yet.
class MediaKeyClock {
  final _elapsed = Stopwatch();
  int? _serverTime;

  bool get synchronized => _serverTime != null;
  int get now => _serverTime == null
      ? DateTime.now().millisecondsSinceEpoch
      : _serverTime! + _elapsed.elapsedMilliseconds;

  void synchronize(Object? milliseconds) {
    if (milliseconds == null) return; // Older control server.
    if (milliseconds is! int ||
        milliseconds < 0 ||
        milliseconds > 8640000000000000) {
      throw const FormatException('Invalid media server time');
    }
    _serverTime = milliseconds;
    _elapsed
      ..reset()
      ..start();
  }

  bool accepts(Map<String, dynamic> envelope) {
    return validMediaKeyLifetime(
      envelope,
      now: DateTime.now().millisecondsSinceEpoch,
      serverNow: synchronized ? now : null,
    );
  }
}

bool validMediaKeyLifetime(
  Map<String, dynamic> envelope, {
  required int now,
  int? serverNow,
}) {
  final useServerTime = envelope.containsKey('server_expires_at');
  if (useServerTime && serverNow == null) return false;
  final expiry = useServerTime
      ? envelope['server_expires_at']
      : envelope['expires_at'];
  final current = useServerTime ? serverNow! : now;
  return expiry is int && expiry > current && expiry <= current + 60000;
}
