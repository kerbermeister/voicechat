import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:voicechat_probe/call_probe.dart';
import 'call_key_sharing_test.dart' show SharingClient, SharingRoom;

class CameraPublication extends Fake
    implements lk.LocalTrackPublication<lk.LocalVideoTrack> {
  @override
  final lk.LocalVideoTrack track;
  @override
  String get sid => track.mediaStreamTrack.id!;
  CameraPublication(this.track);
}

class CameraParticipant extends Fake implements lk.LocalParticipant {
  final tracks = <CameraPublication>[];
  final operations = <String>[];
  bool failPublish = false;
  @override
  List<lk.LocalTrackPublication<lk.LocalVideoTrack>>
  get videoTrackPublications => tracks;
  @override
  Future<lk.LocalTrackPublication<lk.LocalVideoTrack>> publishVideoTrack(
    lk.LocalVideoTrack track, {
    lk.VideoPublishOptions? publishOptions,
  }) async {
    operations.add('publish');
    if (failPublish) {
      failPublish = false;
      throw StateError('publication failed');
    }
    tracks.add(CameraPublication(track));
    return FakeVideoPublication();
  }

  @override
  Future<void> removePublishedTrack(String sid, {bool notify = true}) async {
    operations.add('remove');
    final publication = tracks.singleWhere((p) => p.sid == sid);
    tracks.remove(publication);
    await publication.track.dispose();
  }
}

class FakeVideoPublication extends Fake
    implements lk.LocalTrackPublication<lk.LocalVideoTrack> {}

class CameraRoom extends Fake implements lk.Room {
  @override
  final CameraParticipant localParticipant = CameraParticipant();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Group switch releases old capture, keeps microphone and restores camera after failure',
    () async {
      final captures = <String>[];
      final stops = <String>[];
      var rearDenied = false;
      const channel = MethodChannel('FlutterWebRTC.Method');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (method) async {
        if (method.method == 'getUserMedia') {
          final constraints = method.arguments['constraints'] as Map;
          expect(constraints['audio'], false);
          final facing = constraints['video']['facingMode'] as String;
          captures.add(facing);
          if (facing == 'environment') {
            expect(
              stops,
              contains('video-1'),
              reason: 'Release before rear capture',
            );
            if (rearDenied) throw PlatformException(code: 'denied');
          }
          return {
            'streamId': 'stream-${captures.length}',
            'audioTracks': [],
            'videoTracks': [
              {
                'id': 'video-${captures.length}',
                'label': 'camera',
                'kind': 'video',
                'enabled': true,
                'settings': {'facingMode': facing},
              },
            ],
          };
        }
        if (method.method == 'trackDispose') {
          stops.add(method.arguments['trackId']);
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final media = CameraRoom();
      final call = CallProbe(
        chat: SharingRoom(SharingClient()),
        session: 'camera',
        tokenUrl: 'http://localhost:8090',
        livekitUrl: 'ws://localhost:7880',
        status: (_) {},
        video: true,
      )..media = media;
      await call.camera(true);
      await Future.wait([call.switchCamera(), call.switchCamera()]);
      expect(captures, ['user', 'environment']);
      expect(call.cameraEnabled, isTrue);
      await call.switchCamera();
      expect(captures.last, 'user');
      rearDenied = true;
      await expectLater(call.switchCamera(), throwsA(anything));
      expect(captures.sublist(captures.length - 2), ['environment', 'user']);
      expect(call.cameraEnabled, isTrue);
      expect(media.localParticipant.tracks, hasLength(1));
      rearDenied = false;
      media.localParticipant.failPublish = true;
      await expectLater(call.switchCamera(), throwsStateError);
      expect(captures.sublist(captures.length - 2), ['environment', 'user']);
      expect(call.cameraEnabled, isTrue);
      expect(media.localParticipant.tracks, hasLength(1));
      // Any attempted microphone operation would throw on the Fake participant.
      await call.camera(false);
      expect(call.cameraEnabled, isFalse);
      expect(media.localParticipant.tracks, isEmpty);
    },
  );
}
