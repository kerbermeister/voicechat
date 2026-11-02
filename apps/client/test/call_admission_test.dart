import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/call_admission.dart';

const identity = '@alice:local/A';
Map<String, dynamic> admission({bool token = true, String generation = 'a'}) =>
    {
      'identity': identity,
      'lease_id': 'b' * 64,
      'lease_seconds': 30,
      'generation': 'vc-${generation * 48}',
      'roster': [
        {'identity': identity, 'curve': 'public-curve', 'ed': 'public-ed'},
      ],
      'heartbeat_supported': true,
      'server_time': 1000000,
      if (token) 'token': 'fixture-jwt-$generation',
    };

void main() {
  test('Initial admission and old servers always require a token', () {
    final initial = admission()..remove('heartbeat_supported');
    expect(
      parseCallAdmission(initial, identity: identity)['token'],
      'fixture-jwt-a',
    );
    expect(
      () => parseCallAdmission(admission(token: false), identity: identity),
      throwsFormatException,
    );
  });
  test(
    'Heartbeat reuses a JWT only for the same authenticated lease and generation',
    () {
      final previous = admission();
      final next = admission(token: false)..['server_time'] = 1003000;
      final parsed = parseCallAdmission(
        next,
        identity: identity,
        heartbeat: true,
        previous: previous,
      );
      expect(parsed['token'], previous['token']);
      expect(parsed['server_time'], 1003000);
      expect(
        next.containsKey('token'),
        false,
        reason: 'Do not mutate the response or previous admission',
      );
      final rotated = parseCallAdmission(
        admission(token: false, generation: 'c'),
        identity: identity,
        heartbeat: true,
        previous: previous,
      );
      expect(
        rotated.containsKey('token'),
        false,
        reason: 'A new generation must request its own JWT',
      );
      for (final invalid in [
        {...next, 'lease_id': 'd' * 64},
        {...next, 'identity': '@other:local/B'},
      ]) {
        expect(
          () => parseCallAdmission(
            invalid,
            identity: identity,
            heartbeat: true,
            previous: previous,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => parseCallAdmission(next, identity: identity, heartbeat: true),
        throwsFormatException,
      );
    },
  );
  test('Malformed control metadata cannot extend a call authorization', () {
    final invalid = <Object?>[
      null,
      [],
      {...admission(), 'generation': 'other-room'},
      {...admission(), 'lease_id': 'short'},
      {...admission(), 'lease_seconds': 300},
      {...admission(), 'roster': []},
      {...admission(), 'roster': List.filled(11, {})},
      {...admission(), 'token': ''},
      {...admission(), 'token': 42},
      {...admission(), 'heartbeat_supported': 'true'},
    ];
    for (final value in invalid) {
      expect(
        () => parseCallAdmission(value, identity: identity),
        throwsFormatException,
      );
    }
    expect(
      () => parseCallAdmission(
        admission(token: false),
        identity: identity,
        heartbeat: true,
        previous: admission()..remove('token'),
      ),
      throwsFormatException,
    );
  });
}
