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
