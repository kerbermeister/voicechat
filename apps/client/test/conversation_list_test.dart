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
  PushRuleSet? globalPushRules;
  @override
  final directChats = <String, List<String>>{};
  @override
  final presences = <String, CachedPresence>{};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('Muted people and groups show a persistent, accessible icon', (
    tester,
  ) async {
    final client = ListClient();
    final room = Room(id: '!chat:local', client: client);
    client.rooms.add(room);
    for (final direct in [true, false]) {
      client.directChats.clear();
      if (direct) client.directChats['@peer:local'] = [room.id];
      for (final muted in [true, false]) {
        client.globalPushRules = PushRuleSet.fromJson({
          'override': [
            if (muted)
              {
                'rule_id': room.id,
                'enabled': true,
                'default': false,
                'actions': [],
              },
          ],
        });
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            theme: AppPalette.lavender.theme,
            home: Scaffold(
              body: ConversationList(
                client: client,
                groups: !direct,
                onTabChanged: (_) {},
                onSelect: (_) {},
                onNewPerson: () {},
                onNewGroup: () {},
                onSettings: () {},
              ),
            ),
          ),
        );
        expect(
          find.byIcon(Icons.notifications_off_outlined),
          muted ? findsOneWidget : findsNothing,
        );
        expect(
          find.byTooltip('Уведомления отключены'),
          muted ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    }
  });
  testWidgets(
    'Presence uses a larger filled online dot and a hollow offline ring in every theme',
    (tester) async {
      for (final palette in AppPalette.values) {
        for (final online in [true, false]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: palette.theme,
              home: Scaffold(
                body: PersonAvatar(name: 'Анна', online: online),
              ),
            ),
          );
          final icon = find.byIcon(
            online ? Icons.circle : Icons.radio_button_unchecked,
          );
          expect(icon, findsOneWidget);
          expect(tester.widget<Icon>(icon).size, 13);
          final badge = find
              .ancestor(of: icon, matching: find.byType(Container))
              .first;
          expect(tester.getSize(badge), const Size(17, 17));
          expect(tester.takeException(), isNull);
        }
      }
    },
  );
  test(
    'A direct chat uses the peer avatar instead of a legacy room avatar',
    () {
      final client = ListClient();
      final room = Room(id: '!dm:local', client: client);
      client.directChats['@peer:local'] = [room.id];
      room.states[EventTypes.RoomAvatar] = {
        '': StrippedStateEvent(
          type: EventTypes.RoomAvatar,
          stateKey: '',
          senderId: client.userID,
          content: {'url': 'mxc://local/old-room'},
        ),
      };
      expect(roomAvatar(room), isNull);
      room.states[EventTypes.RoomMember] = {
        '@peer:local': StrippedStateEvent(
          type: EventTypes.RoomMember,
          stateKey: '@peer:local',
          senderId: '@peer:local',
          content: {'membership': 'join', 'avatar_url': 'mxc://local/peer'},
        ),
      };
      expect(roomAvatar(room), Uri.parse('mxc://local/peer'));
    },
  );
  testWidgets(
    'People and groups stay separate; preview, unread and presence use real state',
    (tester) async {
      final client = ListClient();
      final person = Room(
        id: '!person:local',
        client: client,
        notificationCount: 0,
        unreadMessageCount: 3,
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
      person.states[EventTypes.RoomMember] = {
        '@anna:local': StrippedStateEvent(
          type: EventTypes.RoomMember,
          senderId: '@anna:local',
          stateKey: '@anna:local',
          content: {'membership': 'join', 'displayname': 'Анна'},
        ),
      };
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
      expect(find.text('3'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SegmentedButton<bool>),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
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
