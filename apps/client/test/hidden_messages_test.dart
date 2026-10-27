import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/hidden_messages.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'chat_actions_test.dart' show OutboxDatabase, OutboxTimeline;

class HiddenDatabase extends OutboxDatabase {
  final rows = <String, BasicEvent>{};
  @override
  Future<void> storeRoomAccountData(String roomId, BasicEvent event) async =>
      rows[roomId] = event;
}

class HiddenClient extends Client {
  HiddenClient(super.clientName, {required super.database});
  @override
  String get userID => '@me:local';
  bool fail = false;
  final writes = <String>[];
  @override
  Future<void> setAccountDataPerRoom(
    String user,
    String room,
    String type,
    Map<String, Object?> data,
  ) async {
    expect(user, userID);
    expect(type, hiddenMessagesType);
    if (fail) throw StateError('offline');
    writes.add(room);
  }
}

void main() {
  test(
    'Hide belongs to my account, persists and filters history; failed request leaves message visible',
    () async {
      final db = HiddenDatabase();
      final client = HiddenClient('hidden-test', database: db);
      final room = Room(id: '!group:local', client: client);
      final event = Event.fromJson({
        'event_id': r'$message',
        'type': EventTypes.Message,
        'sender': '@friend:local',
        'content': {'msgtype': MessageTypes.Text, 'body': 'hello'},
      }, room);
      room.lastEvent = event;
      final actions = ChatActions(client);
      client.fail = true;
      await expectLater(actions.hideMessage(event), throwsStateError);
      expect(messageHidden(event), false);
      client.fail = false;
      await actions.hideMessage(event);
      expect(messageHidden(event), true);
      expect(visibleMessages(OutboxTimeline([event]), ''), isEmpty);
      expect(lastMessage(room), 'Сообщение удалено у вас');
      final restored = Room(id: room.id, client: client);
      restored.roomAccountData[hiddenMessagesType] = db.rows[room.id]!;
      expect(hiddenMessages(restored), {r'$message'});
      expect(client.writes, [room.id]);
      restored.roomAccountData[hiddenMessagesType] = BasicEvent(
        type: hiddenMessagesType,
        content: {'event_ids': 'invalid'},
      );
      expect(hiddenMessages(restored), isEmpty);
      await actions.close();
    },
  );
}
