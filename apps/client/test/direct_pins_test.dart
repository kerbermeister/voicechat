import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/pinned_message.dart';
import 'package:voicechat_probe/user_action_error.dart';
import 'message_test.dart' show TestClient;

class PinClient extends TestClient {
  int status = 200;
  final requests = <http.Request>[];
  @override
  http.Client get httpClient => _http;
  late final _http = MockClient((request) async {
    requests.add(request);
    return http.Response('{}', status);
  });
}

class DirectPinRoom extends mx.Room {
  DirectPinRoom(PinClient client)
    : super(client: client, id: '!dm:local', membership: mx.Membership.join) {
    states[mx.EventTypes.RoomPowerLevels] = {
      '': mx.StrippedStateEvent(
        type: mx.EventTypes.RoomPowerLevels,
        senderId: '@owner:local',
        stateKey: '',
        content: {
          'users': {'@owner:local': 100},
          'state_default': 50,
          'events': <String, dynamic>{},
        },
      ),
    };
    states['dev.voicechat.kind'] = {
      '': mx.StrippedStateEvent(
        type: 'dev.voicechat.kind',
        senderId: '@owner:local',
        stateKey: '',
        content: {
          'kind': 'direct',
          'owner': '@owner:local',
          'peer': client.userID,
        },
      ),
    };
  }
  bool direct = true;
  final writes = <List<String>>[];
  @override
  bool get isDirectChat => direct;
  @override
  Future<String> setPinnedEvents(List<String> ids) async {
    writes.add(List.of(ids));
    return r'$pins';
  }
}

void main() {
  test(
    'DM member can request narrowly scoped shared pin permission before setting standard room pins',
    () async {
      final client = PinClient();
      final room = DirectPinRoom(client);
      expect(room.canChangeStateEvent(mx.EventTypes.RoomPinnedEvents), false);
      expect(canPinMessages(room), true);
      await setPinnedMessages(room, [r'$message']);
      expect(
        client.requests.single.url.path,
        '/_synapse/client/voicechat-direct-pins',
      );
      expect(jsonDecode(client.requests.single.body), {'room_id': room.id});
      expect(room.writes, [
        [r'$message'],
      ]);
      client.status = 403;
      await expectLater(
        setPinnedMessages(room, []),
        throwsA(isA<UserActionError>()),
      );
      expect(
        room.writes,
        hasLength(1),
        reason: 'Failure must not look like a successful pin update',
      );
    },
  );
  test(
    'Group and explicitly restricted pins never use DM permission normalization',
    () async {
      final client = PinClient();
      final room = DirectPinRoom(client)..direct = false;
      expect(canPinMessages(room), false);
      await expectLater(
        setPinnedMessages(room, []),
        throwsA(isA<UserActionError>()),
      );
      room.direct = true;
      (room.states[mx.EventTypes.RoomPowerLevels]!['']!.content['events']
              as Map)[mx.EventTypes.RoomPinnedEvents] =
          50;
      expect(canPinMessages(room), false);
      await expectLater(
        setPinnedMessages(room, []),
        throwsA(isA<UserActionError>()),
      );
      expect(client.requests, isEmpty);
      expect(room.writes, isEmpty);
    },
  );
}
