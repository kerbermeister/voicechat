@TestOn('browser')
library;

import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
// ignore: depend_on_referenced_packages
import 'package:dart_webrtc/dart_webrtc.dart' as rtc;
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:dart_webrtc/src/rtc_rtp_sender_impl.dart';
import 'package:voicechat_probe/video_note.dart';
import 'package:voicechat_probe/camera_capture.dart';
import 'package:voicechat_probe/call_quality.dart';

void main() {
  test(
    'Camera capture uses exact direction and awaited sender replacement',
    () async {
      final stream = await captureCamera('user', VideoQuality.auto);
      final pc = web.RTCPeerConnection();
      final native = stream as rtc.MediaStreamWeb;
      final track = native.jsStream.getVideoTracks().toDart.first;
      final sender = pc.addTrack(track, native.jsStream);
      final wrapped = RTCRtpSenderWeb.fromJsSender(sender);
      await replaceCameraTrack(wrapped, null);
      expect(sender.track, isNull);
      await replaceCameraTrack(wrapped, stream.getVideoTracks().first);
      expect(sender.track?.id, track.id);
      pc.close();
      await expectLater(
        replaceCameraTrack(wrapped, stream.getVideoTracks().first),
        throwsA(anything),
      );
      for (final track in stream.getTracks()) {
        await track.stop();
      }
    },
  );
  for (final cancel in [false, true]) {
    testWidgets(
      'Browser canvas recorder ${cancel ? 'discards' : 'records playable video on release'}',
      (tester) async {
        final held = ValueNotifier(true);
        final cancelled = ValueNotifier(false);
        VideoNoteResult? result;
        var done = false;
        var recording = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await recordVideoNote(
                      context,
                      5,
                      held: held,
                      cancelled: cancelled,
                      onRecording: (value) => recording = value,
                    );
                    done = true;
                  },
                  child: const Text('Record'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Record'));
        for (var i = 0; i < 100 && !recording; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
        }
        await tester.pump();
        expect(recording, true);
        expect(find.byType(AlertDialog), findsNothing);
        if (!cancel) {
          // The desktop fake device has no rear lens: failed switching must restore recording.
          await tester.tap(find.byTooltip('Переключить камеру'));
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
          expect(recording, true);
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)),
        );
        cancelled.value = cancel;
        held.value = false;
        for (var i = 0; i < 100 && !done; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
        }
        await tester.pump();
        expect(done, true);
        if (cancel) {
          expect(result, isNull);
        } else {
          expect(result, isNotNull);
          expect(result!.file.size, greaterThan(0));
          final bytes = (await tester.runAsync(
            () => result!.file.read(0, result!.file.size),
          ))!;
          final blob = web.Blob(
            [bytes.toJS].toJS,
            web.BlobPropertyBag(type: result!.file.mime),
          );
          final url = web.URL.createObjectURL(blob);
          final video = web.HTMLVideoElement()
            ..muted = true
            ..src = url;
          await tester.runAsync(() async {
            await video.play().toDart;
            expect(video.videoWidth, 480);
            expect(video.videoHeight, 480);
            await Future<void>.delayed(const Duration(milliseconds: 100));
            final frame = web.HTMLCanvasElement()
              ..width = 480
              ..height = 480;
            frame.context2D.drawImage(video, 0, 0);
            final pixels = frame.context2D
                .getImageData(0, 0, 480, 480)
                .data
                .toDart;
            expect(
              [
                for (var i = 0; i < pixels.length; i++)
                  if (i % 4 != 3) pixels[i],
              ].any((value) => value > 20),
              true,
            );
            video.pause();
          });
          web.URL.revokeObjectURL(url);
        }
        await tester.pumpWidget(const SizedBox());
        held.dispose();
        cancelled.dispose();
      },
    );
  }
}
