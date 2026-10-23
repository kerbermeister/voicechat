import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:voicechat_probe/screen_capture.dart';

class CaptureTrack extends Fake implements rtc.MediaStreamTrack {
  int stops = 0;
  @override
  void Function()? onEnded;
  @override
  String get id => 'screen';
  @override
  String get kind => 'video';
  @override
  Future<void> stop() async {
    stops++;
  }
}

class CaptureStream extends Fake implements rtc.MediaStream {
  int disposals = 0;
  @override
  Future<void> dispose() async {
    disposals++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Disposal native-публикации не останавливает единственный root capture',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('voicechat/screen'),
            (_) async => null,
          );
      final stream = CaptureStream(), track = CaptureTrack();
      // ignore: invalid_use_of_internal_member
      final root = lk.LocalVideoTrack(
        lk.TrackSource.screenShareVideo,
        stream,
        track,
        const lk.ScreenShareCaptureOptions(captureScreenAudio: false),
      );
      final capture = ScreenCapture(root);
      var ended = false;
      track.onEnded = () {
        ended = true;
      };
      final publication = await capture.publication();
      await publication.dispose();
      expect(track.stops, 0);
      expect(stream.disposals, 0);
      track.onEnded!();
      expect(ended, isTrue);
      await capture.close();
      final stops = track.stops;
      expect(stops, greaterThan(0));
      expect(stream.disposals, 1);
      await capture.close();
      expect(track.stops, stops);
      await expectLater(capture.publication(), throwsStateError);
    },
  );
}
