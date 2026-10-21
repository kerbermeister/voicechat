import 'package:matrix/matrix.dart';

String _key(Room room) => 'dev.voicechat.local.history:${room.id}';
Future<({int limit, bool complete})> historyWindow(Room room) async {
  final saved =
      (await room.client.database.getAccountData())[_key(room)]?.content;
  final oldest = saved?['oldest'];
  if (oldest is! String) {
    return (limit: Room.defaultHistoryCount, complete: false);
  }
  final ids = await room.client.database.getEventIdList(room);
  final index = ids.indexOf(oldest);
  if (index < 0) return (limit: Room.defaultHistoryCount, complete: false);
  return (
    limit: index + 1 < Room.defaultHistoryCount
        ? Room.defaultHistoryCount
        : index + 1,
    complete: saved?['complete'] == true,
  );
}

bool historyComplete(Timeline timeline) =>
    timeline.events.any((e) => e.type == EventTypes.RoomCreate) ||
    !timeline.canRequestHistory;
Future<void> rememberHistory(Timeline timeline) async {
  if (timeline.events.isEmpty || timeline.canRequestFuture) return;
  await timeline.room.client.database.storeAccountData(_key(timeline.room), {
    'oldest': timeline.events.last.eventId,
    'complete': historyComplete(timeline),
  });
}
