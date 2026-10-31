@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:voicechat_probe/screen_capture.dart';
import 'package:voicechat_probe/camera_capture.dart';
import 'package:voicechat_probe/call_quality.dart';

void main() {
  test('Screen sharing depends on the actual browser API', () {
    final devices = web.window.navigator.mediaDevices;
    final original = devices.getProperty<JSAny?>('getDisplayMedia'.toJS);
    addTearDown(() => devices.setProperty('getDisplayMedia'.toJS, original));
    devices.setProperty('getDisplayMedia'.toJS, null);
    expect(ScreenCapture.supported, isFalse);
    devices.setProperty('getDisplayMedia'.toJS, (() {}).toJS);
    expect(ScreenCapture.supported, isTrue);
  });

  test(
    'Web capture preserves exact rear facingMode and never requests audio',
    () async {
      final devices = web.window.navigator.mediaDevices;
      final original = devices.getProperty<JSAny?>('getUserMedia'.toJS);
      addTearDown(() => devices.setProperty('getUserMedia'.toJS, original));
      Map? requested;
      devices.setProperty(
        'getUserMedia'.toJS,
        ((JSAny constraints) {
          requested = constraints.dartify() as Map;
          return Future<web.MediaStream>.value(web.MediaStream()).toJS;
        }).toJS,
      );
      await captureCamera('environment', VideoQuality.auto);
      expect(requested!['audio'], false);
      expect((requested!['video'] as Map)['facingMode'], {
        'exact': 'environment',
      });
    },
  );
}
