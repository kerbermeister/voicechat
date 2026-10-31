import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/media_key_clock.dart';

void main() {
  test(
    'Server expiry works with clocks far apart; legacy expiry stays local',
    () {
      final key = {'expires_at': 120000, 'server_expires_at': 220000};
      for (final deviceTime in [10000, 500000, 90000000]) {
        expect(
          validMediaKeyLifetime(key, now: deviceTime, serverNow: 200000),
          isTrue,
        );
      }
      expect(
        validMediaKeyLifetime({'expires_at': 120000}, now: 100000),
        isTrue,
      );
      expect(
        validMediaKeyLifetime({'expires_at': 120000}, now: 500000),
        isFalse,
      );
    },
  );
  test('Server expiry cannot fall back to a permissive legacy timestamp', () {
    for (final expiry in [null, '220000', 200000, 199999, 260001]) {
      expect(
        validMediaKeyLifetime(
          {'expires_at': 120000, 'server_expires_at': expiry},
          now: 100000,
          serverNow: 200000,
        ),
        isFalse,
      );
    }
    expect(
      validMediaKeyLifetime({
        'expires_at': 120000,
        'server_expires_at': 220000,
      }, now: 100000),
      isFalse,
    );
  });
  test('Clock uses validated server time and elapsed time', () async {
    final clock = MediaKeyClock();
    expect(clock.synchronized, isFalse);
    clock.synchronize(null);
    expect(clock.synchronized, isFalse);
    for (final invalid in [-1, '1000', 1.5, 8640000000000001]) {
      expect(() => clock.synchronize(invalid), throwsFormatException);
    }
    clock.synchronize(200000);
    expect(clock.synchronized, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(clock.now, greaterThanOrEqualTo(200020));
    expect(
      clock.accepts({'expires_at': 0, 'server_expires_at': 220000}),
      isTrue,
    );
  });
}
