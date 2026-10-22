import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/media_policy.dart';
import 'package:voicechat_probe/temporary_message.dart';
import 'package:voicechat_probe/theme.dart';
import 'package:voicechat_probe/user_action_error.dart';
import 'chat_actions_test.dart' show OutboxDatabase, OutboxRoom, OutboxTimeline;
import 'message_test.dart' show TestClient;

class QuoteClient extends TestClient {
  Map<String, Object?>? sent;
  @override
  Duration get sendTimelineEventTimeout => const Duration(seconds: 1);
  @override
  Future<String> sendMessage(
    String roomId,
    String type,
    String transaction,
    Map<String, Object?> body,
  ) async {
    sent = body;
    return r'$reply';
  }
}

void main() {
  Event message(Room room, {int? ttl = 10, DateTime? sent}) => Event.fromJson({
    'event_id': r'$temporary',
    'type': EventTypes.Message,
    'sender': '@alice:local',
    'origin_server_ts': (sent ?? DateTime.now()).millisecondsSinceEpoch,
    'content': {
      'msgtype': MessageTypes.Text,
      'body': 'private temporary text',
      if (ttl != null) 'dev.voicechat.ttl_seconds': ttl,
    },
  }, room);

  test(
    'Duration survives the encrypted outbox and follows current server bounds',
    () async {
      final database = OutboxDatabase();
      final client = Client(
        'temporary-test',
        database: database,
        httpClient: MockClient((_) async => http.Response('{}', 503)),
        logLevel: Level.error,
      );
      final actions = ChatActions(client);
      await actions.open();
      addTearDown(actions.close);
      final room = OutboxRoom(client);
      for (final ttl in [0, 9, 11, 610]) {
        await expectLater(
          actions.text(room, 'temporary', ttlSeconds: ttl),
          throwsA(isA<UserActionError>()),
        );
      }
      await actions.text(room, 'temporary', ttlSeconds: 10);
      final items =
          database.values['dev.voicechat.local.outbox']!['items'] as List;
      expect(items.single['content']['dev.voicechat.ttl_seconds'], 10);
      expect(
        jsonEncode(items),
        isNot(contains('org.matrix.self_destruct_after')),
      );
      final defaults = const MediaPolicy().toJson();
      expect(MediaPolicy.fromJson(defaults).temporaryMaxSeconds, 600);
      for (final change in [
        {'temporary_step_seconds': 0},
        {'temporary_min_seconds': 700},
        {'temporary_max_seconds': 605},
        {'temporary_min_seconds': true},
      ]) {
        expect(
          () => MediaPolicy.fromJson({...defaults, ...change}),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'Expired text cannot enter local search or a freshly opened timeline',
    () {
      final room = Room(
        id: '!temporary:local',
        client: Client('expiry-search', database: OutboxDatabase()),
      );
      final sent = DateTime.now().subtract(const Duration(seconds: 11));
      final expired = message(room, sent: sent);
      expect(
        messageExpiry(expired)!.millisecondsSinceEpoch,
        sent.millisecondsSinceEpoch + 10000,
      );
      expect(messageExpired(expired), isTrue);
      expect(messageSearchText(expired), '');
      expect(messageExpiry(message(room, ttl: null)), isNull);
      final unavailable = Event.fromJson({
        ...expired.toJson(),
        'type': EventTypes.Encrypted,
        'content': {'msgtype': MessageTypes.BadEncrypted},
        'original_source': {
          ...expired.toJson(),
          'type': EventTypes.Encrypted,
          'content': {'dev.voicechat.ttl_seconds': 10, 'ciphertext': 'opaque'},
        },
      }, room);
      expect(messageExpired(unavailable), isTrue);
      final pruned = Event.fromJson({
        ...expired.toJson(),
        'type': EventTypes.Encrypted,
        'content': <String, dynamic>{},
      }, room);
      expect(emptyEncryptedEvent(pruned), isTrue);
      expect(
        visibleMessages(OutboxTimeline([expired, unavailable, pruned]), ''),
        isEmpty,
      );
    },
  );

  test(
    'Reply fallback retains the relation without making a permanent copy of temporary text',
    () async {
      final client = QuoteClient();
      final room = Room(id: '!quote:local', client: client);
      final original = message(room);
      await room.sendEvent(
        {'msgtype': MessageTypes.Text, 'body': 'my reply'},
        txid: 'reply-test',
        inReplyTo: original,
        displayPendingEvent: false,
      );
      expect(
        jsonEncode(client.sent),
        isNot(contains('private temporary text')),
      );
      expect(client.sent!['body'], contains('Временное сообщение'));
      expect((client.sent!['m.relates_to'] as Map)['m.in_reply_to'], {
        'event_id': original.eventId,
      });
    },
  );

  testWidgets(
    'Deadline removes plaintext before the one-second evaporation; seven narrow themes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final room = Room(
        id: '!temporary:local',
        client: Client('expiry-widget', database: OutboxDatabase()),
      );
      for (final palette in AppPalette.values) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            theme: palette.theme,
            home: Scaffold(
              body: TemporaryMessage(
                event: message(room),
                child: const Text('private temporary text'),
              ),
            ),
          ),
        );
        expect(find.text('private temporary text'), findsOneWidget);
        await tester.pump(const Duration(seconds: 10));
        expect(find.text('private temporary text'), findsNothing);
        expect(find.text('Сообщение исчезает'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 1100));
        expect(find.text('Сообщение исчезает'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
