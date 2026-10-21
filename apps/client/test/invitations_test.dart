import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/group_invitations.dart';
import 'package:voicechat_probe/invitations_dialog.dart';
import 'message_test.dart' show TestClient;

class InvitationClient extends TestClient {
  @override
  final rooms = <Room>[];
  @override
  final directChats = <String, List<String>>{};
  @override
  bool get autoRequestProfileForMissingUsers => false;
}

void main() {
  test('Group invitation outcome survives membership updates and restart', () {
    final client = InvitationClient();
    final room = Room(id: '!group:local', client: client);
    client.rooms.add(room);
    void member(String membership, String sender) {
      room.states[EventTypes.RoomMember] = {
        client.userID: Event(
          type: EventTypes.RoomMember,
          eventId: '\$$membership',
          originServerTs: DateTime(2026),
          room: room,
          senderId: sender,
          stateKey: client.userID,
          content: {'membership': membership},
        ),
      };
    }

    member('invite', '@owner:local');
    var entries = groupInvitations(client, []);
    expect(entries.single.state, 'pending');
    member('join', client.userID);
    entries = groupInvitations(client, entries);
    expect(entries.single.state, 'accepted');
    entries = entries.map((v) => GroupInvitation.fromJson(v.toJson())).toList();
    member('leave', client.userID);
    expect(groupInvitations(client, entries).single.state, 'accepted');
    member('invite', '@owner:local');
    entries = groupInvitations(client, entries);
    expect(entries.single.state, 'pending');
    member('leave', client.userID);
    expect(groupInvitations(client, entries).single.state, 'declined');
    member('leave', '@owner:local');
    expect(groupInvitations(client, entries).single.state, 'cancelled');
    client.rooms.clear();
    expect(
      groupInvitations(
        client,
        entries,
        updates: [
          (
            roomId: room.id,
            state: room.states[EventTypes.RoomMember]![client.userID]!,
          ),
        ],
      ).single.state,
      'cancelled',
    );
    client.rooms.add(room);
    room.states['dev.voicechat.kind'] = {
      '': Event(
        type: 'dev.voicechat.kind',
        eventId: '\$direct',
        originServerTs: DateTime(2026),
        room: room,
        senderId: '@owner:local',
        content: {'kind': 'direct'},
      ),
    };
    member('invite', '@owner:local');
    expect(groupInvitations(client, []), isEmpty);
  });
  testWidgets('Invitation outcomes have distinct labels and icons', (
    tester,
  ) async {
    for (final (state, label, icon) in [
      ('pending', 'Ожидает ответа', Icons.schedule),
      ('accepted', 'Принято', Icons.check_circle_outline),
      ('declined', 'Отклонено', Icons.highlight_off),
      ('cancelled', 'Отменено', Icons.block),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: InvitationStateBadge(state: state)),
        ),
      );
      expect(find.text(label), findsOneWidget);
      expect(find.byIcon(icon), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
