import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_devices.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'call_window_test.dart' show WindowDatabase, IncomingSession;
import 'package:voicechat_probe/direct_call.dart';
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
  DeviceRoom(Client client, {super.id = '!room:local'})
    : super(client: client, membership: Membership.join);
  @override
  bool get encrypted => true;
}

class DirectDeviceRoom extends DeviceRoom {
  DirectDeviceRoom(super.client, {super.id});
  @override
  bool get isDirectChat => true;
}

class PendingOwnSession extends IncomingSession {
  PendingOwnSession(super.room);
  bool ended = false;
  int terminations = 0;
  @override
  CallState get state => ended ? CallState.kEnded : CallState.kRinging;
  @override
  Future<void> terminate(
    CallParty party,
    CallErrorCode reason,
    bool shouldEmit,
  ) async {
    expect(party, CallParty.kRemote);
    terminations++;
    ended = true;
  }
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
  test(
    'own encrypted group decline dismisses ringing and late invitations only in its room',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Event'),
            (_) async => null,
          );
      final client = DeviceClient();
      final room = DeviceRoom(client);
      final otherRoom = Room(
        client: client,
        id: '!other:local',
        membership: Membership.join,
      );
      client.rooms.add(room);
      final calls = CallController(
        client,
        'https://example.invalid',
        'wss://example.invalid',
        (_) {},
      );
      addTearDown(() async {
        await calls.close();
        await client.dispose();
      });
      final now = DateTime.now().millisecondsSinceEpoch;
      Map<String, dynamic> message(
        String action,
        String sender, {
        bool encrypted = false,
      }) => {
        'type': EventTypes.Message,
        'event_id': r'$' + action + sender,
        'sender': sender,
        'origin_server_ts': now,
        'content': {
          'msgtype': 'dev.voicechat.call',
          'action': action,
          'session': 'b' * 32,
        },
        if (encrypted)
          'original_source': {
            'type': EventTypes.Encrypted,
            'event_id': r'$encrypted-' + action,
            'origin_server_ts': now,
            'sender': sender,
            'content': <String, Object?>{'sender_key': 'trusted'},
          },
      };
      final invite = message('invite', '@peer:local');
      calls.receive(Event.fromJson(invite, room));
      expect(calls.invitations.length, 1);
      calls.receive(
        Event.fromJson(
          message('decline', '@other:local', encrypted: true),
          room,
        ),
      );
      calls.receive(Event.fromJson(message('decline', client.userID), room));
      expect(
        calls.invitations.length,
        1,
        reason: 'another account and plaintext cannot dismiss this account',
      );
      // A decline with a reused session in another room must not suppress this one.
      calls.declined.add((room: otherRoom.id, session: 'b' * 32));
      calls.invitations.clear();
      calls.receive(Event.fromJson(invite, room));
      expect(calls.invitations.length, 1);
      calls.receive(
        Event.fromJson(
          message('decline', client.userID, encrypted: true),
          room,
        ),
      );
      expect(calls.invitations, isEmpty);
      calls.receive(Event.fromJson(invite, room));
      expect(
        calls.invitations,
        isEmpty,
        reason: 'late decryption must not restart a declined incoming call',
      );
      calls.receive(
        Event.fromJson({
          ...invite,
          'content': <String, dynamic>{
            ...invite['content'] as Map,
            'session': 'c' * 32,
          },
        }, room),
      );
      expect(calls.invitations.length, 1, reason: 'a new call still rings');
    },
  );
  test(
    'verified own-device encrypted hangup ends the matching incoming SDK session without echo',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Event'),
            (_) async => null,
          );
      final client = DeviceClient();
      final room = DirectDeviceRoom(client);
      final other = DirectDeviceRoom(client, id: '!other:local');
      client.rooms.addAll([room, other]);
      final calls = CallController(
        client,
        'https://example.invalid',
        'wss://example.invalid',
        (_) {},
      );
      final session = PendingOwnSession(room);
      final incoming = DirectCall(session, () {}, (_) {});
      calls.directInvitations.add(incoming);
      addTearDown(() async {
        await incoming.close();
        await calls.close();
        await client.dispose();
      });
      final now = DateTime.now().millisecondsSinceEpoch;
      Event hangup({
        String curve = 'trusted',
        bool encrypted = true,
        String sender = '@user:local',
        Room? inRoom,
        int? timestamp,
      }) => Event.fromJson({
        'type': EventTypes.CallHangup,
        'event_id': r'$own-hangup',
        'sender': sender,
        'origin_server_ts': timestamp ?? now,
        'content': {
          'call_id': session.callId,
          'party_id': 'own-other-party',
          'version': '1',
          'reason': 'user_hangup',
        },
        if (encrypted)
          'original_source': {
            'type': EventTypes.Encrypted,
            'event_id': r'$own-hangup',
            'sender': sender,
            'origin_server_ts': timestamp ?? now,
            'content': {'sender_key': curve},
          },
      }, inRoom ?? room);
      calls.receive(hangup(encrypted: false));
      calls.receive(hangup(curve: 'unknown'));
      calls.receive(hangup(sender: '@other:local'));
      calls.receive(hangup(inRoom: other));
      calls.receive(hangup(timestamp: now - 600001));
      expect(calls.directInvitations, [incoming]);
      expect(session.terminations, 0);
      client.onCallEvents.add([hangup()]);
      await Future<void>.delayed(Duration.zero);
      expect(calls.directInvitations, isEmpty);
      expect(session.terminations, 1);
      expect(incoming.isClosed, true);
      client.onCallEvents.add([hangup()]);
      await Future<void>.delayed(Duration.zero);
      expect(
        session.terminations,
        1,
        reason: 'duplicate SDK/timeline delivery is idempotent',
      );
      expect(
        calls.declined,
        contains((room: room.id, session: session.callId)),
      );
    },
  );
}
