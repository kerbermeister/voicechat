import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:voicechat_probe/screen_capture.dart';

class CaptureTrack extends Fake implements rtc.MediaStreamTrack {
  int stops = 0;
  @override
  void Function()? onEnded;
  @override
  void Function()? onMute;
  @override
  void Function()? onUnMute;
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
  for (final scenario in ['denied', 'no-frames', 'frames']) {
    test('Mac capture $scenario fails closed before publishing', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final methods = <String>[];
      const channel = MethodChannel('FlutterWebRTC.Method');
      const texture = MethodChannel('FlutterWebRTC/Texture71');
      messenger.setMockMethodCallHandler(texture, (_) async => null);
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'requestCapturePermission') {
          return scenario != 'denied';
        }
        if (call.method == 'getDisplayMedia') {
          return {
            'streamId': 'display',
            'audioTracks': [],
            'videoTracks': [
              {
                'id': 'screen',
                'kind': 'video',
                'label': 'screen',
                'enabled': true,
                'remote': false,
              },
            ],
          };
        }
        if (call.method == 'createVideoRenderer') return {'textureId': 71};
        if (call.method == 'videoRendererSetSrcObject' &&
            scenario == 'frames') {
          await messenger.handlePlatformMessage(
            'FlutterWebRTC/Texture71',
            const StandardMethodCodec().encodeSuccessEnvelope({
              'event': 'didFirstFrameRendered',
            }),
            (_) {},
          );
        }
        return null;
      });
      try {
        ScreenCapture? capture;
        Object? error;
        final starting = ScreenCapture.start().then<void>(
          (value) {
            capture = value;
          },
          onError: (Object e) {
            error = e;
          },
        );
        await starting;
        if (scenario == 'frames') {
          expect(error, isNull);
          expect(capture, isNotNull);
          expect(methods, isNot(contains('trackDispose')));
          await capture!.close();
        } else {
          expect(error, isA<PlatformException>());
          expect(
            (error as PlatformException).code,
            scenario == 'denied' ? 'screenPermissionDenied' : 'screenNoFrames',
          );
          if (scenario == 'denied') {
            expect(methods, contains('requestCapturePermission'));
            expect(methods, isNot(contains('getDisplayMedia')));
          } else {
            expect(
              methods,
              containsAll([
                'videoRendererDispose',
                'trackDispose',
                'streamDispose',
              ]),
            );
          }
          expect(screenCaptureNotice(error!), contains('macOS'));
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(texture, null);
      }
    });
  }
  test(
    'Desktop capture support is not restricted to Android or determined by the viewer device',
    () {
      final original = debugDefaultTargetPlatformOverride;
      try {
        for (final platform in [
          TargetPlatform.android,
          TargetPlatform.macOS,
          TargetPlatform.windows,
          TargetPlatform.linux,
        ]) {
          debugDefaultTargetPlatformOverride = platform;
          expect(ScreenCapture.supported, true, reason: platform.name);
        }
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        expect(
          ScreenCapture.supported,
          false,
          reason:
              'Native iOS broadcast extension is not part of this client; web uses API detection',
        );
      } finally {
        debugDefaultTargetPlatformOverride = original;
      }
    },
  );
  test('Ошибки picker имеют понятные сообщения без вывода исходных данных', () {
    expect(
      screenCaptureNotice('Unable to getDisplayMedia: InvalidStateError'),
      contains('снова нажмите'),
    );
    expect(
      screenCaptureNotice('NotReadableError: private details'),
      contains('прежний показ'),
    );
    expect(
      screenCaptureNotice('NotAllowedError: private details'),
      contains('не разрешён'),
    );
    expect(
      screenCaptureNotice('NotSupportedError'),
      contains('не предоставляет'),
    );
    expect(
      screenCaptureNotice(StateError('private token')),
      isNot(contains('private')),
    );
  });
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
