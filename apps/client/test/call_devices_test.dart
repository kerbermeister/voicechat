import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_devices.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'call_window_test.dart' show WindowDatabase;
import 'message_test.dart' show TestDevice;

class DeviceClient extends Client {
  DeviceClient() : super('devices', database: WindowDatabase());
  @override
  String get userID => '@user:local';
  @override
  String get deviceID => 'CURRENT';
  final trusted = TestDevice('PHONE')..directVerified = true;
  @override
  DeviceKeys? getUserDeviceKeysByCurve25519Key(String key) =>
      key == 'trusted' ? trusted : null;
}

class DeviceRoom extends Room {
  DeviceRoom(Client client)
    : super(client: client, id: '!room:local', membership: Membership.join);
  @override
  bool get encrypted => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Only a trusted own device can suppress the matching invitation; stale and reordered updates are ignored',
    () async {
      final client = DeviceClient();
      final room = DeviceRoom(client);
      client.rooms.add(room);
      var changes = 0;
      final devices = CallDevices(client, () => changes++);
      final now = DateTime.now().millisecondsSinceEpoch;
      ToDeviceEvent signal({
        String sender = '@user:local',
        String curve = 'trusted',
        bool encrypted = true,
        bool active = true,
        int? sent,
      }) => ToDeviceEvent(
        sender: sender,
        type: 'dev.voicechat.call_device',
        encryptedContent: encrypted ? {'sender_key': curve} : null,
        content: {
          'room_id': room.id,
          'session': 'call',
          'device': 'PHONE',
          'active': active,
          'sent_at': sent ?? now,
        },
      );
      devices.receive(signal(sender: '@other:local'));
      devices.receive(signal(curve: 'unknown'));
      devices.receive(signal(encrypted: false));
      devices.receive(signal(sent: now - 61000));
      devices.receive(signal(sent: 9223372036854775807));
      client.trusted.directVerified = false;
      devices.receive(signal());
      expect(changes, 0);
      client.trusted.directVerified = true;
      devices.receive(signal());
      expect(devices.answered(room.id, 'call'), true);
      expect(devices.answered(room.id, 'another'), false);
      expect(devices.remote.length, 1);
      devices.receive(signal(active: false, sent: now + 1));
      devices.receive(signal());
      expect(devices.remote, isEmpty);
      expect(changes, 2);
      expect(devices.answered(room.id, 'call'), true);
      await devices.close();
      await client.dispose();
    },
  );
  test(
    'A delayed decryption delivers a live group invitation, history does not',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Event'),
            (_) async => null,
          );
      final client = DeviceClient();
      final room = DeviceRoom(client);
      client.rooms.add(room);
      final calls = CallController(
        client,
        'https://example.invalid',
        'wss://example.invalid',
        (_) {},
      );
      final event = {
        'type': EventTypes.Message,
        'event_id': r'$invite',
        'sender': '@peer:local',
        'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
        'content': {
          'msgtype': 'dev.voicechat.call',
          'action': 'invite',
          'session': 'a' * 32,
          'video': true,
        },
      };
      // ignore: deprecated_member_use
      client.onEvent.add(
        // ignore: deprecated_member_use
        EventUpdate(
          roomID: room.id,
          type: EventUpdateType.history,
          content: event,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.invitations, isEmpty);
      // ignore: deprecated_member_use
      client.onEvent.add(
        // ignore: deprecated_member_use
        EventUpdate(
          roomID: room.id,
          type: EventUpdateType.decryptedTimelineQueue,
          content: event,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls.invitations.values.single.video, true);
      calls.receive(
        Event.fromJson({
          ...event,
          'content': <String, dynamic>{
            ...Map<String, dynamic>.from(event['content'] as Map),
            'action': 'end',
          },
        }, room),
      );
      calls.receive(Event.fromJson(event, room));
      expect(
        calls.invitations,
        isEmpty,
        reason: 'late invite must not restart an ended call',
      );
      await calls.close();
      await client.dispose();
    },
  );
}
