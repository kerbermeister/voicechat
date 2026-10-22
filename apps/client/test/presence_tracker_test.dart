import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/presence_tracker.dart';
import 'package:voicechat_probe/contact_service.dart';
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

class ContactPresenceClient extends Client {
  ContactPresenceClient(http.Client httpClient)
    : super(
        'contact-presence',
        database: PresenceDatabase(),
        httpClient: httpClient,
      );
  @override
  String get userID => '@self:local';
  @override
  String get accessToken => 'fixture-token';
  @override
  Future<GetPresenceResponse> getPresence(String userId) async {
    throw MatrixException(http.Response('{"errcode":"M_FORBIDDEN"}', 403));
  }
}

void main() {
  test(
    'Only accepted contacts use the authorized presence fallback; server errors never become offline',
    () async {
      var requests = 0, online = false, unavailable = false;
      final client = ContactPresenceClient(
        MockClient((request) async {
          requests++;
          expect(request.url.path, '/presence');
          expect(request.url.queryParameters['user_id'], '@peer:local');
          expect(request.headers['Authorization'], 'Bearer fixture-token');
          return http.Response(
            jsonEncode({
              'presence': online ? 'online' : 'offline',
              'last_active_ago': 45000,
            }),
            unavailable ? 503 : 200,
          );
        }),
      );
      final contacts = ContactService(client, 'http://localhost:8090');
      contacts.requests = [
        ContactRequest.fromJson({
          'id': 'a' * 32,
          'sender': client.userID,
          'recipient': '@peer:local',
          'room_id': '!pair:local',
          'state': 'accepted',
        }),
      ];
      final tracker = PresenceTracker(client, () {});
      await tracker.refresh('@stranger:local');
      expect(requests, 0);
      await tracker.refresh('@peer:local');
      // ignore: deprecated_member_use
      expect(presenceLabel(client.presences['@peer:local']), 'Не в сети');
      // ignore: deprecated_member_use
      expect(
        // ignore: deprecated_member_use
        lastSeen(client.presences['@peer:local'], DateTime.now()),
        contains('сегодня'),
      );
      online = true;
      await tracker.refresh('@peer:local');
      // ignore: deprecated_member_use
      expect(presenceLabel(client.presences['@peer:local']), 'В сети');
      unavailable = true;
      await tracker.refresh('@peer:local');
      // ignore: deprecated_member_use
      expect(
        // ignore: deprecated_member_use
        presenceLabel(client.presences['@peer:local']),
        isNot('Не в сети'),
      );
      await tracker.close();
      await contacts.close();
    },
  );
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
