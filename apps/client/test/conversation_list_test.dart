import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/theme.dart';

class ListClient implements Client {
  @override
  bool get autoRequestProfileForMissingUsers => false;
  @override
  bool get getDisplayNameAndAvatarFromPrevContent => false;
  @override
  String get userID => '@me:local';
  @override
  final rooms = <Room>[];
  @override
  final directChats = <String, List<String>>{};
  @override
  final presences = <String, CachedPresence>{};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'People and groups stay separate; preview, unread and presence use real state',
    (tester) async {
      final client = ListClient();
      final person = Room(
        id: '!person:local',
        client: client,
        notificationCount: 2,
      );
      final group = Room(id: '!group:local', client: client);
      for (final (room, name) in [(person, 'Анна'), (group, 'Семья')]) {
        room.states[EventTypes.RoomName] = {
          '': StrippedStateEvent(
            type: EventTypes.RoomName,
            content: {'name': name},
            senderId: client.userID,
            stateKey: '',
          ),
        };
        room.lastEvent = Event.fromJson({
          'event_id': '\$${room.id}',
          'type': EventTypes.Message,
          'sender': client.userID,
          'origin_server_ts': 1700000000000,
          'content': {'msgtype': MessageTypes.Text, 'body': 'До встречи!'},
        }, room);
      }
      client.rooms.addAll([person, group]);
      client.directChats['@anna:local'] = [person.id];
      client.presences['@anna:local'] = CachedPresence(
        PresenceType.online,
        0,
        null,
        true,
        '@anna:local',
      );
      bool groups = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppPalette.lavender.theme,
          home: Scaffold(
            body: SizedBox(
              width: 350,
              child: StatefulBuilder(
                builder: (_, setState) => ConversationList(
                  client: client,
                  onSelect: (_) {},
                  onNewPerson: () {},
                  onNewGroup: () {},
                  onSettings: () {},
                  groups: groups,
                  onTabChanged: (value) => setState(() => groups = value),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Анна'), findsOneWidget);
      expect(find.text('Семья'), findsNothing);
      expect(find.text('В сети'), findsOneWidget);
      expect(find.text('Вы: До встречи!'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.text('Группы'));
      await tester.pumpAndSettle();
      expect(find.text('Семья'), findsOneWidget);
      expect(find.text('Анна'), findsNothing);
      expect(find.text('Создать группу'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'нет такого');
      await tester.pumpAndSettle();
      expect(find.text('Ничего не найдено'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
