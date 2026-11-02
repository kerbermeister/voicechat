import 'package:flutter/material.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'package:voicechat_probe/unread_messages.dart';
import 'chat_actions_test.dart' show OutboxDatabase;
import 'conversation_list_test.dart' show ListClient;

class UnreadEvents extends OutboxDatabase {
  final events = <Event>[];
  String? missing;
  @override
  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    bool includeSending = false,
    int? limit,
  }) async => events.map((event) => event.eventId).toList();
  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async => events
      .take(limit ?? events.length)
      .where((event) => event.eventId != missing)
      .toList();
}

class UnreadClient extends ListClient {
  @override
  Encryption? encryption;
  @override
  final UnreadEvents database;
  UnreadClient(this.database);
}

class StoredCiphertext extends Fake implements Encryption {
  final Map<String, Event> plaintext;
  StoredCiphertext(this.plaintext);
  @override
  Future<Event> decryptRoomEvent(
    Event event, {
    bool store = false,
    EventUpdateType updateType = EventUpdateType.timeline,
  }) async => plaintext[event.eventId] ?? event;
}

void main() {
  late UnreadEvents database;
  late Room room;
  Event event(
    String id,
    String type, {
    String? sender,
    Map<String, dynamic>? content,
  }) => Event.fromJson({
    'event_id': '\$$id',
    'type': type,
    'sender': sender ?? '@friend:local',
    'origin_server_ts': 1700000000000,
    'original_source': {
      'event_id': '\$$id',
      'sender': sender ?? '@friend:local',
      'origin_server_ts': 1700000000000,
      'type': EventTypes.Encrypted,
      'content': {'ciphertext': 'fixture'},
    },
    'content': content ?? {'msgtype': MessageTypes.Text, 'body': 'Message'},
  }, room);
  setUp(() {
    database = UnreadEvents();
    room = Room(
      id: '!unread:local',
      client: UnreadClient(database),
      unreadMessageCount: 9,
      notificationCount: 0,
    );
    room.roomAccountData['m.fully_read'] = BasicEvent(
      type: 'm.fully_read',
      content: {'event_id': r'$read'},
    );
    database.events.addAll([
      event('text2', EventTypes.Message),
      for (var i = 0; i < 6; i++)
        event('signal$i', 'm.call.candidates', content: {}),
      event('text1', EventTypes.Message),
      event('invite', EventTypes.CallInvite, content: {}),
      event('own', EventTypes.Message, sender: room.client.userID),
      event('read', EventTypes.Message),
    ]);
  });

  test(
    'Muted chat counts three visible incoming items, not nine encrypted call events',
    () async {
      expect(await visibleUnreadCount(room), 3);
      expect(
        room.unreadMessageCount,
        9,
        reason: 'Do not rewrite server state or receipts',
      );
      expect(room.notificationCount, 0);
      expect(room.fullyRead, r'$read');
    },
  );
  test(
    'Stored ciphertext is decrypted before counting hidden call signals',
    () async {
      final plaintext = {
        for (final event in database.events) event.eventId: event,
      };
      (room.client as UnreadClient).encryption = StoredCiphertext(plaintext);
      for (var i = 0; i < database.events.length; i++) {
        final previous = database.events[i];
        database.events[i] = Event.fromJson({
          ...previous.toJson(),
          'type': EventTypes.Encrypted,
          'content': {'ciphertext': 'stored'},
        }, room);
      }
      expect(await visibleUnreadCount(room), 3);
      plaintext.remove(r'$text2');
      expect(
        await visibleUnreadCount(room),
        9,
        reason: 'Missing keys preserve the badge',
      );
    },
  );
  test('Only hidden signalling leaves no false unread badge', () async {
    database.events.removeWhere(
      (event) =>
          event.eventId.startsWith(r'$text') ||
          event.type == EventTypes.CallInvite,
    );
    room.unreadMessageCount = 6;
    expect(await visibleUnreadCount(room), 0);
  });
  test(
    'Missing read boundary, sync gaps and undeciphered events preserve the badge',
    () async {
      database.missing = r'$text1';
      expect(await visibleUnreadCount(room), 9);
      database.missing = null;
      database.events.insert(
        0,
        event(
          'encrypted',
          EventTypes.Encrypted,
          content: {'ciphertext': 'unavailable'},
        ),
      );
      expect(await visibleUnreadCount(room), 9);
      database.events.removeAt(0);
      database.events.removeLast();
      expect(await visibleUnreadCount(room), 9);
    },
  );
  test(
    'Count-only sync with events not yet cached preserves unread messages',
    () async {
      room.unreadMessageCount = 20;
      expect(await visibleUnreadCount(room), 20);
    },
  );
  test(
    'Latest own receipt and count-only sync never revive an older unread count',
    () async {
      room.receiptState.global = LatestReceiptStateForTimeline.empty()
        ..latestOwnReceipt = LatestReceiptStateData(r'$text1', 0);
      room.unreadMessageCount = 7;
      expect(await visibleUnreadCount(room), 1);
      room.unreadMessageCount = 0;
      expect(await visibleUnreadCount(room), 0);
    },
  );
  testWidgets(
    'Conversation badge reconciles call signals and retains a count-only update',
    (tester) async {
      final client = room.client as UnreadClient;
      client.rooms.add(room);
      client.directChats['@friend:local'] = [room.id];
      room.lastEvent = database.events.first;
      Widget screen() => MaterialApp(
        home: Scaffold(
          body: ConversationList(
            client: client,
            groups: false,
            onSelect: (_) {},
            onNewPerson: () {},
            onNewGroup: () {},
            onSettings: () {},
            onTabChanged: (_) {},
          ),
        ),
      );
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.text('3'), findsOneWidget);
      expect(find.text('9'), findsNothing);
      room.unreadMessageCount = 20;
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.text('20'), findsOneWidget);
      expect(find.text('3'), findsNothing);
      room.unreadMessageCount = 0;
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.text('20'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
