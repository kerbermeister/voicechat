import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/storage_policy.dart';
import 'package:voicechat_probe/storage_dialog.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class CacheDatabase extends OutboxDatabase {
  final events = <String, Event>{};
  final removed = <String>[];
  String? token;
  @override
  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    bool includeSending = false,
    int? limit,
  }) async => events.values
      .where((e) => e.room.id == room.id)
      .map((e) => e.eventId)
      .toList();
  @override
  Future<Event?> getEventById(String eventId, Room room) async =>
      events[eventId];
  @override
  Future<void> transaction(Future<void> Function() action) => action();
  @override
  Future<void> removeEvent(String eventId, String roomId) async {
    events.remove(eventId);
    removed.add(eventId);
  }

  @override
  Future<void> setRoomPrevBatch(
    String? prevBatch,
    String roomId,
    Client client,
  ) async => token = prevBatch;
}

class CacheClient extends Client {
  bool offline = false;
  CacheClient(CacheDatabase database) : super('cache-test', database: database);
  @override
  Future<EventContext> getEventContext(
    String roomId,
    String eventId, {
    int? limit,
    String? filter,
  }) async {
    if (offline) throw StateError('offline');
    return EventContext.fromJson({
      'start': 'before-retained-event',
      'event': {
        'type': EventTypes.Message,
        'event_id': eventId,
        'sender': '@peer:local',
        'origin_server_ts': 0,
        'content': {'body': 'kept'},
      },
    });
  }
}

class MeasuredPolicy extends StoragePolicy {
  final CacheDatabase database;
  MeasuredPolicy(CacheClient client, this.database) : super(client, () => null);
  @override
  Future<int> measure() async =>
      database.removed.isEmpty ? 20 * 1048576 : 1048576;
  @override
  Future<void> compact() async {}
}

void main() {
  test('Temporary P2P files never trigger history eviction', () async {
    final database = CacheDatabase();
    final client = CacheClient(database);
    database.values['dev.voicechat.local.p2p.temporary'] = {
      'ids': ['active'],
    };
    final policy = MeasuredPolicy(client, database)..limitMiB = 16;
    await policy.check();
    expect(database.removed, isEmpty);
    expect(policy.usedBytes, isNull);
    expect(policy.warning, contains('P2P'));
    database.values['dev.voicechat.local.p2p.temporary'] = {'ids': []};
    await policy.check();
    expect(policy.usedBytes, 20 * 1048576);
    await policy.close();
  });
  test(
    'Automatic cleanup starts with the oldest cached history, not the most recent message',
    () async {
      final database = CacheDatabase();
      final client = CacheClient(database);
      for (var r = 0; r < 2; r++) {
        final room = Room(id: '!room$r:local', client: client);
        client.rooms.add(room);
        for (var i = 0; i < 40; i++) {
          final event = Event(
            eventId: '\$$r-$i',
            type: EventTypes.Message,
            room: room,
            senderId: '@peer:local',
            content: {},
            originServerTs: DateTime(
              i == 39 ? (r == 0 ? 2019 : 2010) : (r == 0 ? 2020 : 2025),
            ),
            status: EventStatus.synced,
          );
          database.events[event.eventId] = event;
          if (i == 0) room.lastEvent = event;
        }
      }
      final policy = MeasuredPolicy(client, database)..limitMiB = 16;
      await policy.check();
      expect(database.removed.first, '\$1-30');
      expect(database.removed.every((id) => id.startsWith('\$1-')), true);
      expect(policy.warning, isNull);
      await policy.close();
    },
  );
  test(
    'Only old synced timeline copies are trimmed, pagination and protected data survive',
    () async {
      final database = CacheDatabase();
      final client = CacheClient(database);
      final room = Room(id: '!room:local', client: client);
      final policy = StoragePolicy(client, () => null);
      for (var i = 0; i < 60; i++) {
        database.events['\$$i'] = Event(
          eventId: '\$$i',
          type: EventTypes.Message,
          room: room,
          senderId: '@peer:local',
          content: {'body': '$i'},
          originServerTs: DateTime(2026),
          status: i == 59 ? EventStatus.sending : EventStatus.synced,
        );
      }
      database.values['dev.voicechat.local.outbox'] = {'protected': true};
      database.values['dev.voicechat.local.first_keys'] = {'protected': true};
      expect(await policy.trimHistory(room), 29);
      expect(database.events.length, 31);
      expect(database.events.containsKey('\$59'), true);
      expect(database.token, 'before-retained-event');
      expect(room.prev_batch, database.token);
      expect(database.values.values.every((v) => v['protected'] == true), true);
      await policy.close();
    },
  );
  test('Active room and offline history are never discarded', () async {
    final database = CacheDatabase();
    final client = CacheClient(database)..offline = true;
    final room = Room(id: '!room:local', client: client);
    for (var i = 0; i < 60; i++) {
      database.events['\$$i'] = Event(
        eventId: '\$$i',
        type: EventTypes.Message,
        room: room,
        senderId: '@peer:local',
        content: {},
        originServerTs: DateTime(2026),
      );
    }
    final active = StoragePolicy(client, () => room.id);
    expect(await active.trimHistory(room), 0);
    await active.close();
    final policy = StoragePolicy(client, () => null);
    await expectLater(policy.trimHistory(room), throwsStateError);
    expect(database.removed, isEmpty);
    await policy.close();
  });
  testWidgets('Storage settings explain protected data and fit a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final policy = StoragePolicy(CacheClient(CacheDatabase()), () => null)
      ..usedBytes = 123456;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: StorageDialog(policy: policy)),
      ),
    );
    expect(find.text('Локальное хранилище'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await policy.close();
  });
}
