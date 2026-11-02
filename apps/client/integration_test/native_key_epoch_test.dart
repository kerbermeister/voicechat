// Native SDK probe; Android uses a disposable camera-emulated test profile.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';
import 'key_epoch_probe.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native sender key epochs recover without a new receiver',
    (tester) async {
      await tester.runAsync(() async {
        final proof = await runKeyEpochProbe(
          capture: () => rtc.navigator.mediaDevices.getUserMedia({
            'audio': false,
            'video': {
              'width': {'ideal': 320},
              'height': {'ideal': 180},
              'frameRate': {'ideal': 15},
            },
          }),
        );
        // ignore: avoid_print
        print('KEY_EPOCH_PROOF ${jsonEncode(proof)}');
      });
    },
    skip:
        (!Platform.isMacOS && !Platform.isAndroid) ||
        !const bool.fromEnvironment('HARDWARE_CALL_TEST'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
