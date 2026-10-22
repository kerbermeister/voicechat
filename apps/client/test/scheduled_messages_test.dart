import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/media_policy.dart';
import 'package:voicechat_probe/scheduled_messages.dart';
import 'package:voicechat_probe/scheduled_view.dart';
import 'package:voicechat_probe/theme.dart';
import 'chat_actions_test.dart' show OutboxDatabase, OutboxRoom;

class AcknowledgementClient extends Client {
  AcknowledgementClient(
    super.name, {
    required super.database,
    required super.httpClient,
  });
  @override
  Room? getRoomById(String id) => OutboxRoom(this);
  @override
  String get userID => '@owner:local';
  @override
  Future<TokenOwnerInfo> getTokenOwner() =>
      throw StateError('Do not reauthorize an acknowledged transaction');
}

void main() {
  test(
    'Server-compatible audience hash binds members and every published device',
    () {
      final keys = {
        '@a:local': {
          'Z': {
            'keys': {'curve25519:Z': 'curve', 'ed25519:Z': 'ed'},
          },
        },
      };
      expect(
        scheduledAudienceDigest(['@z:local', '@a:local'], keys),
        '990e753147daa31c5361d9bcd913d16543f255af419b71e7aed214aa0ea9a307',
      );
      expect(
        scheduledAudienceDigest(['@a:local', '@z:local'], keys),
        scheduledAudienceDigest(['@z:local', '@a:local'], keys),
      );
      expect(
        scheduledAudienceDigest(['@a:local'], keys),
        isNot(scheduledAudienceDigest(['@a:local', '@z:local'], keys)),
      );
      final now = DateTime.utc(2026, 10, 22);
      validateSchedule(now.add(const Duration(hours: 48)), 172800, now: now);
      for (final delay in [
        Duration.zero,
        const Duration(seconds: -1),
        const Duration(hours: 49),
      ]) {
        expect(
          () => validateSchedule(now.add(delay), 172800, now: now),
          throwsStateError,
        );
      }
      final policy = const MediaPolicy().toJson();
      expect(MediaPolicy.fromJson(policy).scheduleMaxSeconds, 172800);
      expect(
        () => MediaPolicy.fromJson({...policy, 'schedule_max_seconds': 0}),
        throwsFormatException,
      );
    },
  );

  test(
    'Schedule remains in encrypted local outbox until server acknowledgement for text and media',
    () async {
      final database = OutboxDatabase();
      final client = Client(
        'scheduled-outbox',
        database: database,
        httpClient: MockClient((_) async => http.Response('{}', 503)),
        logLevel: Level.error,
      );
      final actions = ChatActions(client, policyUrl: 'http://localhost:8090');
      await actions.open();
      final due = DateTime.now().add(const Duration(hours: 1));
      final room = OutboxRoom(client);
      await actions.text(room, 'later', scheduledFor: due, ttlSeconds: 10);
      await actions.attachment(
        room,
        MatrixAudioFile(bytes: Uint8List.fromList([1, 2]), name: 'voice.wav'),
        scheduledFor: due,
      );
      await actions.album(
        room,
        [
          MatrixImageFile(
            bytes: Uint8List.fromList([1, 2]),
            name: 'photo.jpg',
            mimeType: 'image/jpeg',
          ),
        ],
        'album',
        scheduledFor: due,
      );
      await actions.close();
      final items =
          database.values['dev.voicechat.local.outbox']!['items'] as List;
      expect(items, hasLength(3));
      expect(
        items.every(
          (item) => item['scheduled_at'] == due.millisecondsSinceEpoch,
        ),
        true,
      );
      expect(items.first['content']['dev.voicechat.ttl_seconds'], 10);
      expect(items.map((item) => item['id']).toSet(), hasLength(3));
      await expectLater(
        actions.text(
          room,
          'past',
          scheduledFor: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
        throwsStateError,
      );
    },
  );

  test(
    'Only ciphertext and a stable transaction go to schedule API; rejection differs from outage',
    () async {
      var status = 200;
      final requests = <Map<String, dynamic>>[];
      final client = Client(
        'scheduled-api',
        database: OutboxDatabase(),
        httpClient: MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          expect(request.headers['Authorization'], startsWith('Bearer '));
          return http.Response(
            status == 200
                ? '{"id":"job"}'
                : '{"error":"invalid_schedule_time"}',
            status,
          );
        }),
      );
      final service = ScheduledMessages(client, 'http://localhost:8090');
      final item = {
        'id': 'stable',
        'room': '!room:local',
        'scheduled_at': 123,
        'sealed': {'ciphertext': 'opaque'},
        'audience': 'digest',
        'content': {'body': 'private plaintext'},
      };
      await service.create(item);
      await service.create(item);
      expect(requests[0], requests[1]);
      expect(jsonEncode(requests), isNot(contains('private plaintext')));
      await service.withdraw(item);
      expect(requests.last, {
        'action': 'withdraw',
        'transaction': 'stable',
        'room_id': '!room:local',
      });
      status = 400;
      await expectLater(service.create(item), throwsA(isA<ScheduleRejected>()));
      status = 503;
      await expectLater(
        service.create(item),
        throwsA(isNot(isA<ScheduleRejected>())),
      );
    },
  );

  test(
    'Preview rejects a different owner or transaction before looking up keys',
    () async {
      var wrongOwner = true;
      final client = AcknowledgementClient(
        'preview-owner',
        database: OutboxDatabase(),
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'id': 'expected',
              'user_id': wrongOwner ? '@other:local' : '@owner:local',
              'payload': null,
            }),
            200,
          ),
        ),
      );
      final service = ScheduledMessages(client, 'http://localhost:8090');
      await expectLater(service.preview('expected'), throwsFormatException);
      wrongOwner = false;
      expect(
        await service.preview('expected'),
        'Сообщение опубликовано или отменено.',
      );
      await expectLater(service.preview('different'), throwsFormatException);
    },
  );

  test(
    'Lost acknowledgement is resolved without fresh key trust; rejected schedule does not block the chat',
    () async {
      final database = OutboxDatabase();
      final client = AcknowledgementClient(
        'schedule-ack',
        database: database,
        httpClient: MockClient(
          (_) async =>
              http.Response('{"id":"server-job","state":"pending"}', 200),
        ),
      );
      final actions = ChatActions(client, policyUrl: 'http://localhost:8090');
      Map<String, dynamic> item(String id) => {
        'id': id,
        'room': '!test:local',
        'type': EventTypes.Message,
        'created': 0,
        'scheduled_at': DateTime.now().millisecondsSinceEpoch + 60000,
        'content': {'body': 'private', 'msgtype': MessageTypes.Text},
        'sealed': {'ciphertext': 'opaque'},
        'audience': 'digest',
      };
      actions.pending.add({...item('rejected'), 'schedule_rejected': true});
      actions.pending.add(item('lost-ack'));
      await actions.flush();
      expect(actions.pending.single['id'], 'rejected');
      expect(
        (database.values['dev.voicechat.local.outbox']!['items'] as List)
            .single['id'],
        'rejected',
      );
      await actions.close();
    },
  );

  testWidgets(
    'Scheduled list remains usable at 320px in every theme and exposes failure and cancellation',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var cancelled = false;
      final client = Client(
        'scheduled-ui',
        database: OutboxDatabase(),
        httpClient: MockClient((request) async {
          if (request.method == 'POST') {
            cancelled = true;
            return http.Response('{"ok":true}', 200);
          }
          return http.Response(
            jsonEncode({
              'messages': [
                {
                  'id': 'job',
                  'room_id': '!room:local',
                  'due': DateTime.now().millisecondsSinceEpoch,
                  'state': cancelled ? 'cancelled' : 'pending',
                },
                {
                  'id': 'failed',
                  'room_id': '!room:local',
                  'due': DateTime.now().millisecondsSinceEpoch,
                  'state': 'failed',
                  'error': 'audience_changed',
                },
              ],
            }),
            200,
          );
        }),
      );
      for (final palette in AppPalette.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: palette.theme,
            home: Scaffold(
              body: ScheduledView(
                key: UniqueKey(),
                service: ScheduledMessages(client, 'http://localhost:8090'),
                roomId: '!room:local',
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        expect(
          find.text('Ожидает публикации'),
          cancelled ? findsNothing : findsOneWidget,
        );
        expect(find.text('Запланированные сообщения'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(
        find.byTooltip('Отменить запланированное сообщение').first,
      );
      for (var i = 0; i < 5 && find.text('Отменено').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(cancelled, true);
      expect(find.text('Отменено'), findsOneWidget);
      expect(scheduledTime(DateTime(2026, 10, 22, 13, 5)), '22.10.2026 13:05');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
