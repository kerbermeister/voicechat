// UA-82: query refresh after local visibility changes; no server, accounts or real content.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/history_search.dart';
import 'package:voicechat_probe/hidden_messages.dart';

import 'conversation_list_test.dart' show ListClient;
import 'mobile_layout_test.dart' show EmptyTimeline;

class SearchTimeline extends EmptyTimeline {
  SearchTimeline(super.room);
  @override
  void cancelSubscriptions() {}
}

class SearchRoom extends Room {
  SearchRoom(Client client)
    : super(client: client, id: '!qa:local', membership: Membership.join);
  late final timeline = SearchTimeline(this);
  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
    int? limit = Room.defaultHistoryCount,
  }) async => timeline;
}

void main() {
  for (final action in ['hide', 'leave', 'redact']) {
    testWidgets(
      'UA-82 query refresh after $action must remove unavailable text',
      (tester) async {
        final client = ListClient();
        final room = SearchRoom(client);
        client.rooms.add(room);
        room.states[EventTypes.RoomMember] = {
          for (final id in [client.userID, '@peer:local'])
            id: StrippedStateEvent(
              type: EventTypes.RoomMember,
              senderId: id,
              stateKey: id,
              content: {'membership': 'join', 'displayname': 'QA'},
            ),
        };
        final event = Event.fromJson({
          'type': EventTypes.Message,
          'event_id': r'$qa',
          'sender': '@peer:local',
          'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
          'content': {
            'msgtype': MessageTypes.Text,
            'body': 'QA synthetic needle',
          },
        }, room);
        room.timeline.events.add(event);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => searchHistory(context, client),
                  child: const Text('Open search'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open search'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'needle');
        await tester.pump();
        expect(find.text('QA synthetic needle'), findsOneWidget);
        if (action == 'hide') {
          room.roomAccountData[hiddenMessagesType] = BasicEvent(
            type: hiddenMessagesType,
            content: {
              'event_ids': [event.eventId],
            },
          );
        } else if (action == 'leave') {
          room.membership = Membership.leave;
        } else {
          event.setRedactionEvent(
            Event(
              type: EventTypes.Redaction,
              room: room,
              eventId: r'$redaction',
              originServerTs: DateTime.now(),
              senderId: '@peer:local',
              content: {},
            ),
          );
        }
        await tester.enterText(find.byType(TextField), 'needl');
        await tester.pump();
        final visible = find.text('QA synthetic needle').evaluate().length;
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(
          visible,
          0,
          reason:
              'Changing the query must recheck current visibility, even for a snapshot search',
        );
      },
    );
  }
}
