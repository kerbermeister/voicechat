import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/active_capture.dart';

void main() {
  test(
    'a failed release remains retryable and never silently grants the microphone',
    () async {
      var failed = true;
      var attempts = 0;
      Future<void> cleanup() async {
        attempts++;
        if (failed) throw StateError('Device busy');
      }

      registerCapture(cleanup);
      await expectLater(stopActiveCapture(), throwsStateError);
      failed = false;
      await stopActiveCapture();
      await stopActiveCapture();
      expect(attempts, 2);
    },
  );
  test(
    'calls wait for capture release; an old cleanup cannot clear a new owner',
    () async {
      final released = Completer<void>();
      var stops = 0;
      Future<void> first() {
        stops++;
        return released.future;
      }

      Future<void> second() async {
        stops++;
      }

      registerCapture(first);
      var finished = false;
      final one = stopActiveCapture().then((_) => finished = true);
      final two = stopActiveCapture();
      await Future<void>.delayed(Duration.zero);
      expect(finished, false);
      expect(stops, 1);
      registerCapture(second);
      released.complete();
      await Future.wait([one, two]);
      await stopActiveCapture();
      expect(stops, 2);
      await stopActiveCapture();
      expect(stops, 2);
    },
  );
}
