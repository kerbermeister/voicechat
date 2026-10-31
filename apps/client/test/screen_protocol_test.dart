import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voicechat_probe/screen_api.dart';
import 'package:voicechat_probe/screen_key.dart';
import 'package:voicechat_probe/screen_state.dart';

Map<String, dynamic> active() => {
  'protocol_version': 1,
  'binding_id': '22222222-2222-4222-8222-222222222222',
  'state': 'active',
  'revision': 4,
  'roster_version': 2,
  'owner_identity': '@a:local/A',
  'generation': 'screen-${'b' * 48}',
  'roster': [
    {
      'identity': '@a:local/A',
      'curve': base64Encode(List.filled(32, 12)).replaceAll('=', ''),
      'ed': base64Encode(List.filled(32, 13)).replaceAll('=', ''),
    },
  ],
};

void main() {
  test('Серверные fixture snapshots совместимы с клиентом', () {
    final fixture = jsonDecode(
      File('../../prototype/screen_protocol_fixtures.json').readAsStringSync(),
    );
    for (final entry in (fixture['responses'] as Map).entries) {
      final data = entry.value as Map<String, dynamic>;
      final snapshot = entry.key == 'state' ? data : data['snapshot'];
      if (snapshot != null) {
        expect(ScreenSnapshot.parse(snapshot).state, 'idle');
      }
    }
  });
  test(
    'Snapshot запрещает неизвестного владельца, дубликаты и неверные ключи',
    () {
      expect(ScreenSnapshot.parse(active()).owner, '@a:local/A');
      for (final change in <Map<String, dynamic>>[
        {'protocol_version': 1.0},
        {'revision': -1},
        {'revision': 1.5},
        {'owner_identity': '@b:local/B'},
        {'generation': 'audio-room'},
        {'binding_id': '-' * 36},
        {'state': 'idle'},
        {
          'roster': [active()['roster'][0], active()['roster'][0]],
        },
        {
          'roster': [
            {
              'identity': 'bad',
              'curve': base64Encode(List.filled(32, 12)).replaceAll('=', ''),
              'ed': base64Encode(List.filled(32, 13)).replaceAll('=', ''),
            },
          ],
        },
        {
          'roster': [
            {
              'identity': '@a:local/A',
              'curve': 'bad',
              'ed': base64Encode(List.filled(32, 13)).replaceAll('=', ''),
            },
          ],
        },
      ]) {
        expect(
          () => ScreenSnapshot.parse({...active(), ...change}),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'Ключ привязан к устройству, поколению и сроку, повтор старого отклонён',
    () {
      final snapshot = ScreenSnapshot.parse(active());
      final envelope = <String, dynamic>{
        'protocol_version': 1,
        'room_id': '!r:local',
        'call_session': 'call',
        'binding_id': snapshot.binding,
        'screen_generation': snapshot.generation,
        'revision': 4,
        'roster_version': 2,
        'sender_identity': snapshot.owner,
        'sender_device': 'A',
        'expires_at': 20000,
        'key': base64Encode(List.generate(32, (i) => i)),
      };
      dynamic read(
        Map<String, dynamic> data, {
        String sender = '@a:local',
        String curve = '',
        int now = 10000,
        int? serverNow,
      }) => screenKey(
        data,
        snapshot: snapshot,
        room: '!r:local',
        session: 'call',
        sender: sender,
        device: 'A',
        curve: curve.isEmpty
            ? base64Encode(List.filled(32, 12)).replaceAll('=', '')
            : curve,
        ed: base64Encode(List.filled(32, 13)).replaceAll('=', ''),
        now: now,
        serverNow: serverNow,
      );
      expect(read(envelope), List.generate(32, (i) => i));
      final synchronized = {...envelope, 'server_expires_at': 220000};
      expect(
        read(synchronized, now: 500000, serverNow: 200000),
        List.generate(32, (i) => i),
      );
      expect(read(synchronized, now: 0, serverNow: 220000), isNull);
      expect(read({...synchronized, 'revision': 3}, serverNow: 200000), isNull);
      expect(read(envelope, sender: '@forged:local'), isNull);
      expect(read(envelope, curve: 'e' * 43), isNull);
      for (final change in <Map<String, dynamic>>[
        {'protocol_version': true},
        {'screen_generation': 'screen-${'a' * 48}'},
        {'revision': 3},
        {'roster_version': 1},
        {'call_session': 'other'},
        {'room_id': '!other:local'},
        {'sender_device': 'B'},
        {'expires_at': 10000},
        {'expires_at': 70001},
        {'key': '!' * 44},
      ]) {
        expect(read({...envelope, ...change}), isNull);
      }
    },
  );
  test(
    'HTTP сохраняет bearer в header и не превращает отказ в успех',
    () async {
      final api = ScreenApi(
        'https://example.test/api',
        () => 'secret',
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'https://example.test/api/screen/capabilities',
          );
          expect(request.headers['Authorization'], 'Bearer secret');
          return http.Response('{"error":"screen_access_denied"}', 403);
        }),
      );
      await expectLater(
        api.request('capabilities'),
        throwsA(isA<ScreenApiError>().having((e) => e.status, 'status', 403)),
      );
      api.close();
    },
  );
  test('HTTP ограничивает и проверяет ответ', () async {
    for (final body in ['[]', 'invalid', ' ' * 32769]) {
      final api = ScreenApi(
        'http://localhost',
        () => '',
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(api.request('capabilities'), throwsFormatException);
      api.close();
    }
    final ids = List.generate(100, (_) => screenRequestId());
    expect(ids.toSet().length, 100);
    expect(
      ids.every(
        (id) => RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ).hasMatch(id),
      ),
      isTrue,
    );
  });
}
