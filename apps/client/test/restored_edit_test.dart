import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'call_window_test.dart' show WindowDatabase;

class RestoredEvents extends WindowDatabase {
  final events = <Event>[];
  @override
  Future<User?> getUser(String id, Room room) async => null;
  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async => List.of(events);
  @override
  Future<void> transaction(Future<void> Function() action) => action();
}

class DecryptEdit implements Encryption {
  @override
  Future<Event> decryptRoomEvent(
    Event event, {
    bool store = false,
    EventUpdateType updateType = EventUpdateType.timeline,
  }) async => Event(
    room: event.room,
    eventId: event.eventId,
    senderId: event.senderId,
    originServerTs: event.originServerTs,
    type: EventTypes.Message,
    content: {
      'msgtype': MessageTypes.Text,
      'body': '* edited',
      'm.new_content': {'msgtype': MessageTypes.Text, 'body': 'edited'},
      'm.relates_to': {
        'rel_type': RelationshipTypes.edit,
        'event_id': r'$original',
      },
    },
  );
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RestoredClient extends Client {
  RestoredClient(RestoredEvents db) : super('restored-qa', database: db);
  @override
  bool get encryptionEnabled => true;
  @override
  final encryption = DecryptEdit();
}

void main() {
  for (final outerRelation in [false, true]) {
    test(
      'Initial history decryption aggregates edit without reload (outer relation: $outerRelation)',
      () async {
        final db = RestoredEvents();
        final client = RestoredClient(db);
        final room = Room(
          client: client,
          id: '!qa:local',
          membership: Membership.join,
        )..partial = false;
        room.states[EventTypes.Encryption] = {
          '': StrippedStateEvent(
            senderId: '@qa:local',
            type: EventTypes.Encryption,
            content: {'algorithm': AlgorithmTypes.megolmV1AesSha2},
          ),
        };
        final original = Event(
          room: room,
          eventId: r'$original',
          senderId: '@qa:local',
          originServerTs: DateTime(2026),
          type: EventTypes.Message,
          content: {'msgtype': MessageTypes.Text, 'body': 'original'},
        );
        db.events.addAll([
          Event(
            room: room,
            eventId: r'$edit',
            senderId: original.senderId,
            originServerTs: original.originServerTs.add(
              const Duration(seconds: 1),
            ),
            type: EventTypes.Encrypted,
            content: {
              'can_request_session': true,
              if (outerRelation)
                'm.relates_to': {
                  'rel_type': RelationshipTypes.edit,
                  'event_id': original.eventId,
                },
            },
          ),
          original,
        ]);
        final timeline = await room.getTimeline();
        expect(timeline.events.first.type, EventTypes.Message);
        final shown = original.getDisplayEvent(timeline).body;
        timeline.cancelSubscriptions();
        await client.dispose();
        expect(shown, 'edited');
      },
    );
  }
}
