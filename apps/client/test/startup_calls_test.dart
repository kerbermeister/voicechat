import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/startup_calls.dart';

void main() {
  test(
    'startup call events are drained once and the temporary listener detaches',
    () async {
      final stream = StreamController<List<BasicEventWithSender>>.broadcast();
      final pending = StartupCalls(stream.stream);
      final event = ToDeviceEvent.fromJson({
        'type': 'm.call.invite',
        'sender': '@alice:local',
        'content': {'call_id': 'current-call'},
      });
      stream.add([event]);
      await Future<void>.delayed(Duration.zero);
      expect(pending.take(), [event]);
      stream.add([event]);
      await Future<void>.delayed(Duration.zero);
      expect(pending.take(), isEmpty);
      await pending.close();
      await stream.close();
    },
  );

  test('a large sync retains the most recent 256 events', () async {
    final stream = StreamController<List<BasicEventWithSender>>.broadcast();
    final pending = StartupCalls(stream.stream);
    final events = List.generate(
      300,
      (index) => ToDeviceEvent.fromJson({
        'type': 'm.call.invite',
        'sender': '@alice:local',
        'content': {'call_id': '$index'},
      }),
    );
    stream.add(events);
    await Future<void>.delayed(Duration.zero);
    final retained = pending.take();
    expect(retained.length, 256);
    expect(retained.first.content['call_id'], '44');
    expect(retained.last.content['call_id'], '299');
    await pending.close();
    await stream.close();
  });
}
