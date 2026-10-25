import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/direct_call.dart';
import 'chat_actions_test.dart' show VideoSession, OutboxRoom, OutboxDatabase;

class MediaTrack implements rtc.MediaStreamTrack {
  @override
  final String id;
  @override
  final String kind;
  bool stopped = false;
  MediaTrack(this.id, this.kind);
  @override
  Map<String, dynamic> getSettings() => {'facingMode': 'front'};
  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class MediaStream implements rtc.MediaStream {
  @override
  String get id => 'stream';
  @override
  String get ownerTag => 'local';
  final tracks = <MediaTrack>[MediaTrack('camera', 'video')];
  @override
  List<rtc.MediaStreamTrack> getTracks() => tracks;
  @override
  List<rtc.MediaStreamTrack> getVideoTracks() =>
      tracks.where((t) => t.kind == 'video').toList();
  @override
  List<rtc.MediaStreamTrack> getAudioTracks() =>
      tracks.where((t) => t.kind == 'audio').toList();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Feed implements mx.WrappedMediaStream {
  @override
  final MediaStream stream = MediaStream();
  @override
  bool isLocal() => true;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class MediaSession extends VideoSession {
  @override
  final mx.Room room;
  @override
  final Feed localUserMediaStream = Feed();
  MediaSession(this.room);
  @override
  bool get isLocalVideoMuted => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Switch camera toggles preview mirroring twice without touching audio',
    () async {
      var switches = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (call) async {
          if (call.method == 'mediaStreamTrackSwitchCamera') {
            switches++;
            return true;
          }
          return null;
        },
      );
      final session = MediaSession(
        OutboxRoom(mx.Client('camera-test', database: OutboxDatabase())),
      );
      final audio = MediaTrack('microphone', 'audio');
      session.localUserMediaStream.stream.tracks.add(audio);
      final call = DirectCall(session, () {}, (_) {});
      expect(call.mirrorLocalVideo, true);
      await call.switchCamera();
      expect(call.mirrorLocalVideo, false);
      await call.switchCamera();
      expect(call.mirrorLocalVideo, true);
      expect(switches, 2);
      expect(audio.stopped, false);
      await call.close();
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        null,
      );
    },
  );
  test(
    'Late audio track refreshes an existing renderer once; other state updates preserve playback',
    () async {
      var attachments = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (call) async {
          if (call.method == 'createVideoRenderer') return {'textureId': 42};
          if (call.method == 'videoRendererSetSrcObject') attachments++;
          return null;
        },
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC/Texture42'),
        (_) async => null,
      );
      final session = MediaSession(
        OutboxRoom(mx.Client('stream-test', database: OutboxDatabase())),
      );
      final call = DirectCall(session, () {}, (_) {});
      session.onStreamAdd.add(session.localUserMediaStream);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(attachments, 1);
      session.localUserMediaStream.stream.tracks.add(
        MediaTrack('late-audio', 'audio'),
      );
      session.onCallStateChanged.add(mx.CallState.kInviteSent);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(attachments, 2);
      session.onCallStateChanged.add(mx.CallState.kRinging);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(attachments, 2);
      await call.close();
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC/Texture42'),
        null,
      );
    },
  );
}
