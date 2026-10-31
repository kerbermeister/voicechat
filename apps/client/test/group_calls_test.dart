import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/group_calls.dart';
import 'package:voicechat_probe/user_action_error.dart';
import 'call_devices_test.dart' show DeviceRoom, DirectDeviceRoom;
import 'call_window_test.dart' show WindowDatabase;

class DiscoveryClient extends Client {
  DiscoveryClient() : super('discovery', database: WindowDatabase());
  @override
  String get accessToken => 'fixture-token';
}

http.Response active([String session = 'ongoing', int participants = 2]) =>
    http.Response(
      jsonEncode({
        'calls': [
          {'session': session, 'video': true, 'participants': participants},
        ],
      }),
      200,
    );

void main() {
  test(
    'reopened clients discover the same live call with authenticated room scope',
    () async {
      final client = DiscoveryClient();
      final room = DeviceRoom(client);
      var requests = 0;
      GroupCalls directory() => GroupCalls(
        client,
        'https://chat.example/api',
        () {},
        network: MockClient((request) async {
          requests++;
          expect(
            request.url.toString(),
            'https://chat.example/api/call/active',
          );
          expect(request.headers['authorization'], 'Bearer fixture-token');
          expect(jsonDecode(request.body), {'room_id': room.id});
          return active();
        }),
      );
      final first = directory();
      final before = await first.find(room);
      first.close();
      final reopened = directory();
      final after = await reopened.find(room);
      expect(after!.session, before!.session);
      expect(after.participants, 2);
      expect(after.video, true);
      expect(await reopened.find(DirectDeviceRoom(client)), isNull);
      expect(
        await reopened.find(
          Room(id: '!plain:local', client: client, membership: Membership.join),
        ),
        isNull,
      );
      expect(requests, 2);
      reopened.close();
      await client.dispose();
    },
  );

  test(
    'invalid discovery and denied membership cannot create a join target',
    () async {
      final client = DiscoveryClient();
      final room = DeviceRoom(client);
      for (final body in [
        '{}',
        '{"calls":null}',
        '{"calls":[{}]}',
        jsonEncode({
          'calls': [
            {'session': '', 'video': true, 'participants': 2},
          ],
        }),
        jsonEncode({
          'calls': [
            {'session': 'call', 'video': 1, 'participants': 2},
          ],
        }),
        jsonEncode({
          'calls': [
            {'session': 'call', 'video': true, 'participants': 11},
          ],
        }),
        jsonEncode({
          'calls': List.filled(11, {
            'session': 'call',
            'video': true,
            'participants': 2,
          }),
        }),
        ' ' * 8193,
      ]) {
        final groups = GroupCalls(
          client,
          'https://chat.example/api',
          () {},
          network: MockClient((_) async => http.Response(body, 200)),
        );
        await expectLater(groups.find(room), throwsFormatException);
        groups.close();
      }
      for (final code in [403, 500, 404]) {
        final groups = GroupCalls(
          client,
          'https://chat.example/api',
          () {},
          network: MockClient((_) async => http.Response('{}', code)),
        );
        if (code == 404) {
          expect(await groups.find(room), isNull);
        } else {
          await expectLater(groups.find(room), throwsA(isA<UserActionError>()));
        }
        groups.close();
      }
      await client.dispose();
    },
  );

  test(
    'switching groups discards a late response and immediately checks the new group',
    () async {
      final client = DiscoveryClient();
      final first = DeviceRoom(client);
      final second = DeviceRoom(client, id: '!second:local');
      final pending = Completer<http.Response>();
      final changed = Completer<void>();
      var requests = 0;
      final groups = GroupCalls(
        client,
        'https://chat.example/api',
        () {
          if (requests == 2 && !changed.isCompleted) changed.complete();
        },
        network: MockClient((_) {
          requests++;
          return requests == 1
              ? pending.future
              : Future.value(active('second-call'));
        }),
      );
      groups.watch(first);
      await Future<void>.delayed(Duration.zero);
      groups.watch(second);
      pending.complete(active('stale-call'));
      await changed.future;
      expect(groups.current!.room, same(second));
      expect(groups.current!.session, 'second-call');
      groups.watch(null);
      expect(groups.current, isNull);
      groups.close();
      await client.dispose();
    },
  );

  testWidgets(
    'network failure retains a recent banner briefly, never indefinitely',
    (tester) async {
      final client = DiscoveryClient();
      var failed = false;
      final groups = GroupCalls(
        client,
        'https://chat.example/api',
        () {},
        network: MockClient((_) async {
          if (failed) throw http.ClientException('offline');
          return active();
        }),
      );
      groups.watch(DeviceRoom(client));
      await tester.pump();
      expect(groups.current, isNotNull);
      failed = true;
      await groups.refresh();
      expect(groups.current, isNotNull);
      await tester.pump(const Duration(seconds: 30));
      expect(groups.current, isNull);
      groups.close();
      await client.dispose();
    },
  );

  test('closing cannot be undone by a late discovery result', () async {
    final client = DiscoveryClient();
    final pending = Completer<http.Response>();
    var changes = 0;
    final groups = GroupCalls(
      client,
      'https://chat.example/api',
      () => changes++,
      network: MockClient((_) => pending.future),
    );
    groups.watch(DeviceRoom(client));
    await Future<void>.delayed(Duration.zero);
    groups.close();
    pending.complete(active());
    await Future<void>.delayed(Duration.zero);
    expect(groups.current, isNull);
    expect(changes, 0);
    await client.dispose();
  });
}
