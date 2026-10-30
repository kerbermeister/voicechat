import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/composer_focus.dart';
import 'package:voicechat_probe/read_after.dart';
import 'package:voicechat_probe/pinned_message.dart';
import 'package:voicechat_probe/temporary_message.dart';
import 'chat_actions_test.dart'
    show OutboxDatabase, SendingQueueClient, SendingQueueRoom, OutboxTimeline;
import 'message_test.dart' show TestClient;

class SlowDatabase extends OutboxDatabase {
  final gate = Completer<void>();
  @override
  Future<void> storeAccountData(
    String type,
    Map<String, Object?> content,
  ) async {
    if (type == 'dev.voicechat.local.outbox') await gate.future;
    await super.storeAccountData(type, content);
  }
}

class LocalClient extends SendingQueueClient {
  LocalClient(this.localDatabase);
  final OutboxDatabase localDatabase;
  int transaction = 0;
  @override
  String generateUniqueTransactionId() => 'local-${transaction++}';
  @override
  OutboxDatabase get database => localDatabase;
}

class ReadClient extends TestClient {
  ReadClient(this.localDatabase);
  final OutboxDatabase localDatabase;
  bool offline = false;
  int starts = 0;
  final statusSizes = <int>[];
  int now = DateTime.now().millisecondsSinceEpoch;
  int? deadline;
  @override
  OutboxDatabase get database => localDatabase;
  @override
  http.Client get httpClient => _http;
  late final _http = MockClient((request) async {
    if (offline) throw StateError('offline');
    final data = jsonDecode(request.body) as Map;
    if (data.containsKey('event_ids')) {
      statusSizes.add((data['event_ids'] as List).length);
      return http.Response(
        jsonEncode({
          'server_time_ms': now,
          'deadlines': {if (deadline != null) r'$burn': deadline},
        }),
        200,
      );
    }
    starts++;
    deadline ??= now + 5000;
    return http.Response(
      jsonEncode({'server_time_ms': now, 'expires_at': deadline}),
      200,
    );
  });
}

class PinRoom extends mx.Room {
  PinRoom(mx.Client client) : super(client: client, id: '!pin:local');
  bool rights = true;
  List<String> pins = [];
  @override
  List<String> get pinnedEventIds => pins;
  @override
  bool canChangeStateEvent(String type) => rights;
  @override
  Future<String> setPinnedEvents(List<String> ids) async {
    pins = ids;
    return r'$pinstate';
  }
}

mx.Event message(mx.Room room, String id, {Map<String, dynamic>? content}) =>
    mx.Event.fromJson({
      'type': mx.EventTypes.Message,
      'event_id': id,
      'sender': '@peer:local',
      'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
      'content': content ?? {'msgtype': mx.MessageTypes.Text, 'body': 'hello'},
    }, room);
void main() {
  test(
    'Local row appears before storage; never publishes an uncommitted item',
    () async {
      final db = SlowDatabase();
      final client = LocalClient(db);
      final room = SendingQueueRoom(client, '!queue:local');
      client.roomsById[room.id] = room;
      final actions = ChatActions(client);
      final queued = actions.enqueue(room, {
        'msgtype': mx.MessageTypes.Text,
        'body': 'first',
      });
      expect(actions.pending.single['content']['body'], 'first');
      await actions.flush();
      expect(room.sent, isEmpty);
      db.failWrite = true;
      db.gate.complete();
      await expectLater(queued, throwsStateError);
      expect(actions.pending, isEmpty);
      expect(room.sent, isEmpty);
      actions.dispose();
    },
  );
  test(
    'Acknowledged outgoing card remains until timeline echo, without a duplicate',
    () async {
      final client = LocalClient(OutboxDatabase());
      final gate = Completer<String?>();
      final room = SendingQueueRoom(client, '!queue:local', gate: gate);
      client.roomsById[room.id] = room;
      final actions = ChatActions(client);
      final timeline = OutboxTimeline([]);
      final tx = await actions.enqueue(room, {
        'msgtype': mx.MessageTypes.Text,
        'body': 'hello',
      });
      expect(actions.outgoing(room, timeline).single['id'], tx);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete(r'$confirmed');
      await actions.waitForDelivery(tx);
      expect(actions.pending, isEmpty);
      expect(actions.outgoing(room, timeline).single['confirmed'], true);
      timeline.events.add(message(room, r'$confirmed'));
      expect(actions.outgoing(room, timeline), isEmpty);
      actions.dispose();
    },
  );
  test(
    'Recipient starts read timer once; restart is fail closed until server time',
    () async {
      final db = OutboxDatabase();
      final client = ReadClient(db);
      final room = mx.Room(client: client, id: '!read:local');
      final event = message(
        room,
        r'$burn',
        content: {
          'msgtype': mx.MessageTypes.Text,
          'body': 'secret',
          readAfterKey: 5,
        },
      );
      final state = ReadAfterState.of(client);
      await state.syncRoom(room, [event], read: false);
      expect(client.starts, 0);
      expect(messageExpiry(event), isNull);
      await state.syncRoom(room, [event], read: true);
      expect(client.starts, 1);
      await state.syncRoom(room, [event], read: true);
      expect(client.starts, 1);
      expect(messageExpired(event), false);
      final restoredClient = ReadClient(db)..now = client.now;
      final restored = ReadAfterState.of(restoredClient);
      await restored.load();
      expect(restored.expired(r'$burn'), true);
      expect(restored.expiry(r'$burn')!.millisecondsSinceEpoch, 0);
      restored.observe(client.now);
      expect(restored.expired(r'$burn'), false);
      restored.observe(client.now + 6000);
      expect(restored.expired(r'$burn'), true);
      restored.observe(client.now - 60000);
      expect(
        restored.expired(r'$burn'),
        true,
        reason: 'A backwards clock must not revive content',
      );
    },
  );
  test(
    'Read acknowledgement covers more than one API batch without dropping events',
    () async {
      final client = ReadClient(OutboxDatabase());
      final room = mx.Room(client: client, id: '!batch:local');
      final events = List.generate(
        101,
        (index) => message(
          room,
          '\$batch$index',
          content: {
            'msgtype': mx.MessageTypes.Text,
            'body': 'secret',
            readAfterKey: 5,
          },
        ),
      );
      await ReadAfterState.of(client).syncRoom(room, events, read: true);
      expect(client.statusSizes, [100, 1]);
      expect(client.starts, 101);
    },
  );
  test('Offline read is durable and is never redisplayed on restart', () async {
    final db = OutboxDatabase();
    final client = ReadClient(db)..offline = true;
    final room = mx.Room(client: client, id: '!read:local');
    final event = message(
      room,
      r'$burn',
      content: {
        'msgtype': mx.MessageTypes.Text,
        'body': 'secret',
        readAfterKey: 5,
      },
    );
    final state = ReadAfterState.of(client);
    await expectLater(
      state.syncRoom(room, [event], read: true),
      throwsStateError,
    );
    expect(state.failedRooms, contains(room.id));
    final reloaded = ReadAfterState.of(ReadClient(db));
    await reloaded.load();
    expect(reloaded.expired(event.eventId), true);
    client.offline = false;
    await state.syncRoom(room, [event], read: true);
    expect(state.failedRooms, isEmpty);
    expect(client.starts, 1);
  });
  test(
    'Pin permission is checked, expired messages cannot be pinned',
    () async {
      final room = PinRoom(TestClient());
      final event = message(room, r'$normal');
      await togglePinnedMessage(event);
      expect(room.pins, [event.eventId]);
      await togglePinnedMessage(event);
      expect(room.pins, isEmpty);
      room.rights = false;
      await expectLater(togglePinnedMessage(event), throwsStateError);
      room.rights = true;
      final expired = message(
        room,
        r'$old',
        content: {
          'msgtype': mx.MessageTypes.Text,
          'body': 'old',
          'dev.voicechat.ttl_seconds': 1,
        },
      );
      expired.originServerTs = DateTime.now().subtract(
        const Duration(seconds: 10),
      );
      await expectLater(togglePinnedMessage(expired), throwsStateError);
      expect(room.pins, isEmpty);
    },
  );
  testWidgets(
    'Expired pin is hidden and removed on opening; readonly account never mutates state',
    (tester) async {
      final room = PinRoom(TestClient());
      final old = message(
        room,
        r'$old',
        content: {
          'msgtype': mx.MessageTypes.Text,
          'body': 'expired secret',
          'dev.voicechat.ttl_seconds': 1,
        },
      );
      old.originServerTs = DateTime.now().subtract(const Duration(seconds: 10));
      final timeline = OutboxTimeline([old]);
      for (final rights in [true, false]) {
        room.rights = rights;
        room.pins = [old.eventId];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PinnedMessageBar(
                key: ValueKey(rights),
                room: room,
                timeline: timeline,
                onJump: (_) {},
                onError: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('expired secret'), findsNothing);
        expect(find.byIcon(Icons.push_pin), findsNothing);
        expect(room.pins, rights ? isEmpty : [old.eventId]);
      }
      final fresh = message(room, r'$fresh');
      timeline.events.add(fresh);
      room.pins = [fresh.eventId];
      String? jumped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PinnedMessageBar(
              key: const ValueKey('fresh'),
              room: room,
              timeline: timeline,
              onJump: (id) {
                jumped = id;
              },
              onError: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Закреплённое сообщение'));
      expect(jumped, fresh.eventId);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Desktop restores composer, respects other fields and modal; phone does not autofocus',
    (tester) async {
      final original = debugDefaultTargetPlatformOverride;
      addTearDown(() => debugDefaultTargetPlatformOverride = original);
      final focus = FocusNode(), search = FocusNode(), button = FocusNode();
      final controller = TextEditingController();
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ComposerFocusRegion(
              focus: focus,
              controller: controller,
              child: Scaffold(
                body: Column(
                  children: [
                    TextField(focusNode: focus, controller: controller),
                    TextField(focusNode: search),
                    TextButton(
                      focusNode: button,
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const AlertDialog(content: TextField()),
                      ),
                      child: const Text('modal'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(focus.hasFocus, true);
      search.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(search.hasFocus, true);
      button.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(focus.hasFocus, true);
      await tester.tap(find.text('modal'));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, false);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'x');
      expect(controller.text, isEmpty);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(
        MaterialApp(
          home: ComposerFocusRegion(
            focus: focus,
            controller: controller,
            child: Scaffold(
              body: TextField(focusNode: focus, controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(focus.hasFocus, false);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY, character: 'y');
      await tester.pump();
      expect(controller.text, 'y');
      expect(focus.hasFocus, true);
      await tester.pumpWidget(const SizedBox());
      focus.dispose();
      search.dispose();
      button.dispose();
      controller.dispose();
      debugDefaultTargetPlatformOverride = original;
    },
  );
}
