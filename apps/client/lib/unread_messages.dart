import 'package:matrix/matrix.dart';

import 'chat_actions.dart' show visibleChatMessage;

int serverUnreadCount(Room room) =>
    room.unreadMessageCount ?? room.notificationCount;

/// Encrypted call signalling counts on the server, but is hidden after decryption.
/// Reconcile only a complete, locally stored unread interval; never mark it read.
Future<int> visibleUnreadCount(Room room) async {
  final count = serverUnreadCount(room);
  if (count == 0) return 0;
  final ids = await room.client.database.getEventIdList(room);
  final markers = {
    room.fullyRead,
    room.receiptState.global.latestOwnReceipt?.eventId,
    room.receiptState.mainThread?.latestOwnReceipt?.eventId,
  }.whereType<String>().where((id) => id.isNotEmpty);
  final positions =
      markers.map(ids.indexOf).where((index) => index >= 0).toList()..sort();
  final boundary = positions.isEmpty ? null : ids[positions.first];
  final events = await room.client.database.getEventList(
    room,
    limit: positions.isEmpty ? null : positions.first + 1,
  );
  if (boundary == null &&
      !events.any((event) => event.type == EventTypes.RoomCreate)) {
    return count;
  }
  // Missing/deleted cached events or a sync gap must not silently clear a badge.
  final loaded = events.map((event) => event.eventId).toSet();
  final expected = positions.isEmpty ? ids : ids.take(positions.first + 1);
  if (!expected.every(loaded.contains)) return count;
  // The database retains ciphertext even when the open timeline has decrypted
  // it. Reconcile the same plaintext as the timeline, without advancing receipts.
  final encryption = room.client.encryption;
  if (encryption != null) {
    for (var i = 0; i < events.length; i++) {
      if (events[i].type == EventTypes.Encrypted) {
        events[i] = await encryption.decryptRoomEvent(events[i]);
      }
    }
  }
  final unread = events.takeWhile((event) => event.eventId != boundary);
  if (unread.any((event) => event.type == EventTypes.Encrypted)) return count;
  final incoming = unread.where(
    (event) => event.senderId != room.client.userID && event.status.isSent,
  );
  // A count-only sync can arrive before its events. A cached read boundary alone
  // does not establish that all server-counted unread events are present.
  final counted = incoming
      .where(
        (event) =>
            event.relationshipType != RelationshipTypes.edit &&
            (event.originalSource?.type == EventTypes.Encrypted ||
                event.type == EventTypes.Message &&
                    event.messageType != MessageTypes.Notice &&
                    event.content['body'] is String &&
                    (event.content['body'] as String).isNotEmpty),
      )
      .length;
  if (counted < count) return count;
  return incoming.where(visibleChatMessage).length.clamp(0, count);
}
