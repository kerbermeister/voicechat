import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../../../vendor/livekit_client/web/e2ee.audio_frame_queue.dart';

void main() {
  test(
    'a slow audio packet does not hold later packets or emit out of order',
    () async {
      final first = Completer<void>();
      final output = <int>[];
      final errors = <Object>[];
      final queue = AudioFrameQueue<int>(
        emit: output.add,
        onError: (error, _) => errors.add(error),
      );
      queue.add((emit) async {
        await first.future;
        emit(1);
      });
      queue.add((emit) async => emit(2));
      await Future<void>.delayed(Duration.zero);
      expect(output, [2]);
      var closed = false;
      final closing = queue.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      first.complete();
      await closing;
      expect(output, [2]);
      expect(errors, isEmpty);
      expect(() => queue.add((_) async {}), throwsStateError);
    },
  );

  test('normal consecutive audio packets are all retained', () async {
    final output = <int>[];
    final queue = AudioFrameQueue<int>(
      emit: output.add,
      onError: (error, stack) => fail('$error'),
    );
    for (var i = 0; i < 10; i++) {
      queue.add((emit) async => emit(i));
    }
    await queue.close();
    expect(output, List.generate(10, (i) => i));
  });

  test('stalled crypto is bounded before starting another job', () async {
    final release = Completer<void>();
    var started = 0;
    final output = <int>[];
    final queue = AudioFrameQueue<int>(
      emit: output.add,
      onError: (error, stack) => fail('$error'),
    );
    for (var i = 0; i < 33; i++) {
      queue.add((emit) async {
        started++;
        await release.future;
        emit(i);
      });
    }
    expect(started, 32);
    release.complete();
    await queue.close();
    expect(output, List.generate(32, (i) => i));
  });

  test('a failed crypto job reports its error and releases its slot', () async {
    final errors = <Object>[];
    final output = <int>[];
    final queue = AudioFrameQueue<int>(
      emit: output.add,
      onError: (error, _) => errors.add(error),
    );
    queue.add((_) => throw StateError('crypto failed'));
    await Future<void>.delayed(Duration.zero);
    queue.add((emit) async => emit(2));
    await queue.close();
    expect(errors.single, isA<StateError>());
    expect(output, [2]);
  });
}
