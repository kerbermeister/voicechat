import 'package:matrix/matrix.dart';

const hiddenMessagesType = 'dev.voicechat.hidden_messages';
Set<String> hiddenMessages(Room room) {
  final ids = room.roomAccountData[hiddenMessagesType]?.content['event_ids'];
  if (ids is! List) return {};
  return {
    for (final id in ids)
      if (id is String && id.startsWith(r'$') && id.length <= 255) id,
  };
}

bool messageHidden(Event event) =>
    hiddenMessages(event.room).contains(event.eventId);
