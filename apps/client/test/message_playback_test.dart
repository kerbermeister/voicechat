import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/message_playback.dart';

void main() {
  test('A new player waits for the old audio to pause', () async {
    final lane = MessagePlayback(), first = Object(), second = Object();
    final stopped = Completer<void>();
    final events = <String>[];
    await lane.start(
      first,
      lane.request(first),
      () async {
        events.add('first');
      },
      () async {
        events.add('pausing');
        await stopped.future;
        events.add('paused');
      },
    );
    final switching = lane.start(second, lane.request(second), () async {
      events.add('second');
    }, () async {});
    await Future<void>.delayed(Duration.zero);
    expect(events, ['first', 'pausing']);
    stopped.complete();
    await switching;
    expect(events, ['first', 'pausing', 'paused', 'second']);
  });
  test('Slow download cannot start over the most recent selection', () async {
    final lane = MessagePlayback(), slow = Object(), latest = Object();
    final ticket = lane.request(slow);
    var slowPlays = 0;
    await lane.start(latest, lane.request(latest), () async {}, () async {});
    expect(
      await lane.start(slow, ticket, () async {
        slowPlays++;
      }, () async {}),
      false,
    );
    expect(slowPlays, 0);
  });
  test('Failed pause prevents overlap and can be retried', () async {
    final lane = MessagePlayback(), first = Object(), second = Object();
    var fail = true, plays = 0;
    await lane.start(first, lane.request(first), () async {}, () async {
      if (fail) throw StateError('device');
    });
    await expectLater(
      lane.start(second, lane.request(second), () async {
        plays++;
      }, () async {}),
      throwsStateError,
    );
    expect(plays, 0);
    fail = false;
    await lane.start(second, lane.request(second), () async {
      plays++;
    }, () async {});
    expect(plays, 1);
  });
  test('Dispose while native play is pending leaves no audio behind', () async {
    final lane = MessagePlayback(), owner = Object();
    final playing = Completer<void>();
    var pauses = 0;
    final result = lane.start(
      owner,
      lane.request(owner),
      () => playing.future,
      () async {
        pauses++;
      },
    );
    await Future<void>.delayed(Duration.zero);
    final disposed = lane.pause(owner);
    playing.complete();
    expect(await result, false);
    await disposed;
    expect(pauses, 1);
  });
}
