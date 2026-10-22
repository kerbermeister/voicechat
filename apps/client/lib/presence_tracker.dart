import 'dart:async';
import 'package:matrix/matrix.dart';
import 'contact_service.dart';

class PresenceTracker {
  final Client client;
  final void Function() changed;
  Timer? _timer;
  StreamSubscription<CachedPresence>? _events;
  bool _loading = false;
  final _pending = <String>{};
  bool _closed = false;
  PresenceTracker(this.client, this.changed);
  Future<GetPresenceResponse> _presence(String userId) async {
    try {
      return await client
          .getPresence(userId)
          .timeout(const Duration(seconds: 5));
    } on MatrixException catch (error) {
      final contacts = ContactService.of(client);
      if (error.response?.statusCode != 403 ||
          contacts == null ||
          !contacts.acceptedUsers.contains(userId)) {
        rethrow;
      }
      return contacts.presence(userId);
    }
  }

  void start() {
    client.syncPresence = PresenceType.online;
    _events = client.onPresenceChanged.stream.listen((_) {
      if (!_closed) changed();
    });
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    unawaited(refresh());
  }

  Future<void> refresh([String? userId]) async {
    if (_closed) return;
    _pending.addAll(
      userId == null
          ? {
              if (client.userID != null) client.userID!,
              for (final room in client.rooms)
                for (final user in room.getParticipants()) user.id,
            }
          : {userId},
    );
    if (_loading) return;
    _loading = true;
    try {
      while (_pending.isNotEmpty) {
        if (_closed) return;
        final user = _pending.first;
        _pending.remove(user);
        // ignore: deprecated_member_use
        final previous = client.presences[user];
        try {
          final response = await _presence(user);
          final presence = CachedPresence.fromPresenceResponse(response, user);
          if (_closed) return;
          // A newer sync update wins over an older in-flight HTTP response.
          // ignore: deprecated_member_use
          if (!identical(client.presences[user], previous)) continue;
          // The SDK publishes sync updates here too; no network request from build().
          // ignore: deprecated_member_use
          client.presences[user] = presence;
          await client.database.storePresence(user, presence);
          client.onPresenceChanged.add(presence);
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
    _pending.clear();
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

String presenceLabel(CachedPresence? presence) => switch (presence?.presence) {
  PresenceType.online => 'В сети',
  PresenceType.unavailable => 'Отошёл',
  PresenceType.offline => 'Не в сети',
  _ => 'Статус недоступен',
};
