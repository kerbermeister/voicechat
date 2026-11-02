// Intended assertions for novel capture ownership races; failures reproduce UA-13.
// No microphone, camera, OS permissions, accounts or network are used.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/active_capture.dart';

void main() {
  test(
    'A new capture owner registered during stop must also be released before success',
    () async {
      final gate = Completer<void>();
      Future<void> first() => gate.future;
      var secondStops = 0;
      Future<void> second() async {
        secondStops++;
      }

      registerCapture(first);
      final stopping = stopActiveCapture();
      await Future<void>.delayed(Duration.zero);
      registerCapture(second);
      gate.complete();
      await stopping;
      final activeAfterSuccess = hasActiveCapture;
      final stoppedBeforeSuccess = secondStops;
      await stopActiveCapture();
      expect(
        stoppedBeforeSuccess,
        1,
        reason:
            'A caller must not receive a false promise of exclusive capture',
      );
      expect(activeAfterSuccess, false);
    },
  );
  test(
    'Releasing the callback during disposal must not skip an in-progress stop',
    () async {
      final gate = Completer<void>();
      Future<void> owner() => gate.future;
      registerCapture(owner);
      final first = stopActiveCapture();
      await Future<void>.delayed(Duration.zero);
      releaseCapture(owner);
      var secondReturned = false;
      final second = stopActiveCapture().then((_) => secondReturned = true);
      await Future<void>.delayed(Duration.zero);
      final returnedBeforeNativeRelease = secondReturned;
      gate.complete();
      await Future.wait([first, second]);
      expect(
        returnedBeforeNativeRelease,
        false,
        reason: 'Native disposal is still pending',
      );
      expect(hasActiveCapture, false);
    },
  );
}
