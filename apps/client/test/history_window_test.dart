import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/history_window.dart';
import 'chat_actions_test.dart' show OutboxDatabase, OutboxRoom;

class HistoryDatabase extends OutboxDatabase {
  List<String> ids = [];
  @override
  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    bool includeSending = false,
    int? limit,
  }) async => ids;
}

class HistoryClient implements Client {
  @override
  final HistoryDatabase database = HistoryDatabase();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class HistoryTimeline implements Timeline {
  @override
  final Room room;
  @override
  final List<Event> events;
  @override
  bool canRequestFuture = false;
  @override
  bool canRequestHistory = true;
  HistoryTimeline(this.room, this.events);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'reopening retains loaded history even after new messages arrive',
    () async {
      final client = HistoryClient();
      final room = OutboxRoom(client);
      expect((await historyWindow(room)).limit, Room.defaultHistoryCount);
      final events = List.generate(
        150,
        (i) => Event(
          eventId: '\$event$i',
          type: EventTypes.Message,
          content: {'body': '$i'},
          room: room,
          senderId: '@friend:local',
          originServerTs: DateTime(2026),
        ),
      );
      final timeline = HistoryTimeline(room, events);
      client.database.ids = events.map((e) => e.eventId).toList();
      await rememberHistory(timeline);
      expect(await historyWindow(room), (limit: 150, complete: false));
      client.database.ids.insertAll(0, ['\$new1', '\$new2']);
      expect(await historyWindow(room), (limit: 152, complete: false));
      timeline.canRequestHistory = false;
      await rememberHistory(timeline);
      expect((await historyWindow(room)).complete, true);

      // A calendar fragment must not replace the saved continuous history window.
      timeline.canRequestFuture = true;
      timeline.canRequestHistory = true;
      await rememberHistory(timeline);
      expect((await historyWindow(room)).complete, true);
      client.database.ids = ['\$disconnected-fragment'];
      expect(await historyWindow(room), (
        limit: Room.defaultHistoryCount,
        complete: false,
      ));
    },
  );
}
