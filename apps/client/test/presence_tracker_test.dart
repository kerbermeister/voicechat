import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/presence_tracker.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class PresenceDatabase extends OutboxDatabase {
  @override
  Future<void> storePresence(String userId, CachedPresence presence) async {}
}

class PresenceClient extends Client {
  final first = Completer<GetPresenceResponse>();
  final requested = <String>[];
  PresenceClient() : super('presence-test', database: PresenceDatabase());
  @override
  Future<GetPresenceResponse> getPresence(String userId) {
    requested.add(userId);
    return userId == '@a:local'
        ? first.future
        : Future.value(
            GetPresenceResponse.fromJson({
              'presence': 'offline',
              'last_active_ago': 1000,
            }),
          );
  }
}

void main() {
  test(
    'Concurrent presence requests are not dropped; fresh sync wins over old HTTP',
    () async {
      final client = PresenceClient();
      final tracker = PresenceTracker(client, () {});
      final loading = tracker.refresh('@a:local');
      await tracker.refresh('@b:local');
      // ignore: deprecated_member_use
      client.presences['@a:local'] = CachedPresence(
        PresenceType.online,
        0,
        null,
        true,
        '@a:local',
      );
      client.first.complete(
        GetPresenceResponse.fromJson({'presence': 'offline'}),
      );
      await loading;
      expect(client.requested, ['@a:local', '@b:local']);
      // ignore: deprecated_member_use
      expect(presenceLabel(client.presences['@a:local']), 'В сети');
      // ignore: deprecated_member_use
      final offline = client.presences['@b:local'];
      expect(presenceLabel(offline), 'Не в сети');
      expect(lastSeen(offline, DateTime.now()), contains('сегодня'));
      expect(presenceLabel(null), 'Статус недоступен');
      await tracker.close();
    },
  );
}
