// A late discovery response and same-instance membership changes after leaving.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/group_calls.dart';

import 'call_window_test.dart' show WindowDatabase;

class JoinedRoom extends Room {
  JoinedRoom(Client client)
    : super(client: client, id: '!qa:local', membership: Membership.join);
  @override
  bool get encrypted => true;
}

void main() {
  for (final membership in [Membership.leave, Membership.ban]) {
    test(
      'Late discovery must not advertise a call after ${membership.name}',
      () async {
        final client = Client('qa-discovery', database: WindowDatabase());
        final room = JoinedRoom(client);
        client.rooms.add(room);
        final response = Completer<http.Response>();
        final finished = Completer<void>();
        final calls = GroupCalls(client, 'http://localhost:9', () {
          if (!finished.isCompleted) finished.complete();
        }, network: MockClient((_) => response.future));
        calls.watch(room);
        room.membership = membership;
        response.complete(
          http.Response(
            '{"calls":[{"session":"qa","video":false,"participants":2}]}',
            200,
          ),
        );
        await finished.future;
        final actual = calls.current;
        calls.close();
        await client.dispose();
        expect(
          actual,
          isNull,
          reason:
              'Eligibility must be rechecked after the awaited server response',
        );
      },
    );
  }
}
