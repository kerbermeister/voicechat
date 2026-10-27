import 'personal_room.dart';
import 'package:matrix/matrix.dart';

/// Both unthreaded and main-timeline public receipts acknowledge normal messages.
Iterable<LatestReceiptStateData> messageReadReceipts(Room room) sync* {
  for (final state in [
    room.receiptState.global,
    room.receiptState.mainThread,
  ]) {
    if (state == null) continue;
    for (final entry in state.otherUsers.entries) {
      if (entry.key != room.client.userID) yield entry.value;
    }
  }
}

/// A delivered note to oneself has no other recipient to wait for.
bool personalMessageIsRead(Event event) =>
    isPersonalRoom(event.room) &&
    event.senderId == event.room.client.userID &&
    event.status != EventStatus.sending &&
    event.status != EventStatus.error;
