import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class UnreadDatabase extends OutboxDatabase {
  final saved = <int?>[];
  @override
  Future<void> storeRoomUpdate(
    String roomId,
    SyncRoomUpdate update,
    Event? lastEvent,
    Client client,
  ) async {
    saved.add((update as JoinedRoomUpdate).unreadMessageCount);
  }

  @override
  Future<void> close() async {}
}

void main() {
  test(
    'Count-only sync updates muted rooms after reading on another device',
    () async {
      final database = UnreadDatabase();
      final client = Client('unread-sync', database: database);
      addTearDown(client.dispose);
      final room = Room(
        id: '!muted:local',
        client: client,
        membership: Membership.join,
        notificationCount: 0,
        unreadMessageCount: 2,
      );
      client.rooms.add(room);
      var updates = 0;
      final subscription = client.onSync.stream.listen((_) => updates++);
      addTearDown(subscription.cancel);
      Future<void> sync(Map<String, Object?> update) => client.handleSync(
        SyncUpdate.fromJson({
          'next_batch': 'next',
          'rooms': {
            'join': {room.id: update},
          },
        }),
      );

      for (final count in [0, 4]) {
        await sync({
          'org.matrix.msc2654.unread_count': count,
          'unread_notifications': {
            'notification_count': 0,
            'highlight_count': 0,
          },
        });
        await Future<void>.delayed(Duration.zero);
        expect(room.unreadMessageCount, count);
        expect(room.notificationCount, 0);
      }
      expect(updates, 2);
      expect(database.saved, [0, 4]);
      await sync({});
      expect(room.unreadMessageCount, 4);
      await sync({'org.matrix.msc2654.unread_count': 0});
      expect(room.unreadMessageCount, 0);
    },
  );
}
