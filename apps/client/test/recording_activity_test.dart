import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/recording_activity.dart';
import 'first_keys_test.dart' show PinClient, PinDevice;

class ActivityClient extends PinClient {
  late Room room;
  final peer = PinDevice('@friend:local', 'A', 'key')..directVerified = true;
  @override
  Room? getRoomById(String id) => id == room.id ? room : null;
  @override
  DeviceKeys? getUserDeviceKeysByCurve25519Key(String key) =>
      key == peer.curve25519Key ? peer : null;
}

void main() {
  test(
    'recording activity requires encrypted trusted joined sender and expires',
    () async {
      final client = ActivityClient();
      final room = client.room = Room(id: '!test:local', client: client);
      room.states[EventTypes.RoomMember] = {
        client.peer.userId: StrippedStateEvent(
          type: EventTypes.RoomMember,
          stateKey: client.peer.userId,
          senderId: client.peer.userId,
          content: {'membership': 'join'},
        ),
      };
      final activity = RecordingActivity(client, () {});
      ToDeviceEvent event(
        String kind, {
        bool encrypted = true,
        int? expiry,
        String? sender,
      }) => ToDeviceEvent(
        sender: sender ?? client.peer.userId,
        type: 'dev.voicechat.recording',
        encryptedContent: encrypted
            ? {'sender_key': client.peer.curve25519Key}
            : null,
        content: {
          'room_id': room.id,
          'kind': kind,
          'expires_at':
              expiry ??
              DateTime.now()
                  .add(const Duration(seconds: 10))
                  .millisecondsSinceEpoch,
        },
      );
      activity.receive(event('audio', encrypted: false));
      activity.receive(event('audio', sender: '@imposter:local'));
      activity.receive(event('audio', expiry: 0));
      activity.receive(
        event(
          'audio',
          expiry: DateTime.now()
              .add(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
        ),
      );
      expect(activity.users(room), isEmpty);
      client.peer.directVerified = false;
      activity.receive(event('audio'));
      expect(activity.users(room), isEmpty);
      client.peer.directVerified = true;
      activity.receive(event('audio'));
      expect(activity.users(room), {client.peer.userId: 'audio'});
      activity.receive(event('video'));
      expect(activity.users(room), {client.peer.userId: 'video'});
      activity.receive(event('stop'));
      expect(activity.users(room), isEmpty);
      await activity.close();
    },
  );
}
