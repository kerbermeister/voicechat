// Diagnostic reproduction for UA-05.C12. Run from apps/client with:
// flutter test ../../docs/iterations/scenario-audit-2026-11-01/left_room_invitation_probe.dart
// The assertions describe the intended behavior; failure reproduces the defect.
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_controller.dart';

import 'call_devices_test.dart' show DeviceClient;

class AuditRoom extends Room {
  AuditRoom(Client client, Membership membership)
    : super(client: client, id: '!audit:local', membership: membership);
  @override
  bool get encrypted => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final membership in [
    Membership.join,
    Membership.leave,
    Membership.ban,
    Membership.invite,
  ]) {
    test('Delayed group invitation with membership ${membership.name}', () async {
      final client = DeviceClient();
      final room = AuditRoom(client, membership);
      client.rooms.add(room);
      final calls = CallController(
        client,
        'http://localhost:18090',
        'ws://localhost:17880',
        (_) {},
      );
      addTearDown(() async {
        await calls.close();
        await client.dispose();
      });
      calls.receive(
        Event.fromJson({
          'event_id': r'$late-invite',
          'type': EventTypes.Message,
          'sender': '@peer:local',
          'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
          'content': {
            'msgtype': 'dev.voicechat.call',
            'session': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'action': 'invite',
            'video': false,
          },
        }, room),
      );
      expect(
        calls.invitations.length,
        membership == Membership.join ? 1 : 0,
        reason:
            'A delayed invitation must not ring after leaving, removal, or before joining',
      );
    });
  }
}
