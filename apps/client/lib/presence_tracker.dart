import 'dart:async';
import 'package:matrix/matrix.dart';

class PresenceTracker {
  final Client client;
  final void Function() changed;
  Timer? _timer;
  StreamSubscription<CachedPresence>? _events;
  bool _loading = false;
  bool _closed = false;
  PresenceTracker(this.client, this.changed);
  void start() {
    client.syncPresence = PresenceType.online;
    _events = client.onPresenceChanged.stream.listen((_) {
      if (!_closed) changed();
    });
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    unawaited(refresh());
  }

  Future<void> refresh([String? userId]) async {
    if (_closed || _loading) return;
    _loading = true;
    try {
      final users = userId == null
          ? client.rooms
                .map((r) => r.directChatMatrixID)
                .whereType<String>()
                .toSet()
          : {userId};
      for (final user in users) {
        if (_closed) return;
        try {
          final response = await client
              .getPresence(user)
              .timeout(const Duration(seconds: 5));
          final presence = CachedPresence.fromPresenceResponse(response, user);
          if (_closed) return;
          // The SDK publishes sync updates here too; no network request from build().
          // ignore: deprecated_member_use
          client.presences[user] = presence;
          await client.database.storePresence(user, presence);
        } catch (_) {
          /* Shared-room privacy can make presence unavailable. */
        }
      }
      if (!_closed) changed();
    } finally {
      _loading = false;
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _events?.cancel();
  }
}

String lastSeen(CachedPresence? presence, DateTime now) {
  if (presence == null || presence.presence == PresenceType.online) return '';
  final last = presence.lastActiveTimestamp?.toLocal();
  if (last == null || last.isAfter(now)) {
    return 'Время последнего посещения недоступно';
  }
  final time =
      '${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}';
  final sameDay =
      last.year == now.year && last.month == now.month && last.day == now.day;
  return sameDay
      ? 'Был(а) сегодня в $time'
      : 'Был(а) ${last.day.toString().padLeft(2, '0')}.${last.month.toString().padLeft(2, '0')}.${last.year} в $time';
}
