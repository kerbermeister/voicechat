// Real local display capture only: no account, upload, server, saved frames or audio.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';
import 'package:voicechat_probe/screen_capture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Mac captures actual screen frames and root survives publication disposal',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Text('Изолированная проверка демонстрации экрана'),
            ),
          ),
        ),
      );
      expect(ScreenCapture.supported, true);
      final renderer = rtc.RTCVideoRenderer();
      ScreenCapture? capture;
      final frame = Completer<void>();
      try {
        await renderer.initialize();
        renderer.onFirstFrameRendered = () {
          if (!frame.isCompleted) frame.complete();
        };
        capture = await ScreenCapture.start();
        expect(capture.source.mediaStream.getAudioTracks(), isEmpty);
        renderer.srcObject = capture.source.mediaStream;
        await frame.future.timeout(const Duration(seconds: 30));
        expect(renderer.videoWidth, greaterThan(0));
        expect(renderer.videoHeight, greaterThan(0));
        final publication = await capture.publication();
        await publication.dispose();
        const native = MethodChannel('FlutterWebRTC.Method');
        final retained = await native.invokeMapMethod<String, dynamic>(
          'mediaStreamGetTracks',
          {'streamId': capture.source.mediaStream.id},
        );
        expect(
          retained?['videoTracks'],
          isNotEmpty,
          reason:
              'A new SFU generation must not stop the owned display capture',
        );
        final id = capture.source.mediaStream.id;
        await capture.close();
        renderer.srcObject = null;
        final released = await native.invokeMapMethod<String, dynamic>(
          'mediaStreamGetTracks',
          {'streamId': id},
        );
        expect(released?['videoTracks'] ?? [], isEmpty);
        debugPrint(
          'PASS: native macOS screen frames received; audio excluded; publication ownership and stop verified',
        );
      } finally {
        renderer.srcObject = null;
        await capture?.close();
        await renderer.dispose();
      }
    },
    skip:
        !Platform.isMacOS ||
        !const bool.fromEnvironment('HARDWARE_SCREEN_TEST'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
