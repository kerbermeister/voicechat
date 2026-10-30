import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/direct_call.dart';
import 'package:voicechat_probe/camera_capture.dart';
import 'package:voicechat_probe/call_quality.dart';
import 'chat_actions_test.dart' show VideoSession, OutboxRoom, OutboxDatabase;

class MediaTrack implements rtc.MediaStreamTrack {
  @override
  final String id;
  @override
  final String kind;
  bool stopped = false;
  @override
  bool enabled = true;
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
  final tracks = <rtc.MediaStreamTrack>[MediaTrack('camera', 'video')];
  @override
  List<rtc.MediaStreamTrack> getTracks() => tracks;
  @override
  List<rtc.MediaStreamTrack> getVideoTracks() =>
      tracks.where((t) => t.kind == 'video').toList();
  @override
  List<rtc.MediaStreamTrack> getAudioTracks() =>
      tracks.where((t) => t.kind == 'audio').toList();
  @override
  Future<void> addTrack(
    rtc.MediaStreamTrack track, {
    bool addToNative = true,
  }) async {
    tracks.add(track);
  }

  @override
  Future<void> removeTrack(
    rtc.MediaStreamTrack track, {
    bool removeFromNative = true,
  }) async {
    tracks.remove(track);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class Feed implements mx.WrappedMediaStream {
  final bool local;
  Feed({this.local = true});
  @override
  bool videoMuted = false;
  @override
  final MediaStream stream = MediaStream();
  @override
  bool isLocal() => local;
  @override
  void setVideoMuted(bool value) {
    videoMuted = value;
  }

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

class UpgradeSession extends MediaSession {
  UpgradeSession(super.room);
  @override
  mx.CallType get type => mx.CallType.kVoice;
  @override
  final Feed remoteUserMediaStream = Feed(local: false);
  @override
  List<mx.WrappedMediaStream> get getRemoteStreams => [remoteUserMediaStream];
}

class CameraSender implements rtc.RTCRtpSender {
  @override
  rtc.MediaStreamTrack? track;
  @override
  Future<void> replaceTrack(rtc.MediaStreamTrack? value) async {
    track = value;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class CameraPeer implements rtc.RTCPeerConnection {
  final sender = CameraSender();
  final attached = Completer<void>();
  Completer<rtc.RTCRtpSender>? gate;
  @override
  Future<List<rtc.RTCRtpSender>> getSenders() async => [];
  @override
  Future<rtc.RTCRtpSender> addTrack(
    rtc.MediaStreamTrack track, [
    rtc.MediaStream? stream,
  ]) async {
    sender.track = track;
    if (!attached.isCompleted) attached.complete();
    return gate == null ? sender : await gate!.future;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class CameraSession extends VideoSession {
  CameraSession(this.room);
  @override
  final mx.Room room;
  final feed = Feed()..videoMuted = true;
  bool cleared = false, failMute = false;
  mx.CallState current = mx.CallState.kRinging;
  final CameraPeer peer = CameraPeer();
  @override
  CameraPeer get pc => peer;
  @override
  mx.CallType get type => mx.CallType.kVoice;
  @override
  mx.CallState get state => current;
  @override
  mx.WrappedMediaStream? get localUserMediaStream => cleared ? null : feed;
  @override
  List<mx.WrappedMediaStream> get getLocalStreams => cleared ? [] : [feed];
  @override
  bool get isLocalVideoMuted => feed.videoMuted;
  @override
  Future<void> updateMuteStatus() async {
    if (failMute) throw StateError('signalling offline');
  }
}

class AuthorizedCameraCall extends DirectCall {
  AuthorizedCameraCall(super.call, super.changed, super.report);
  @override
  Future<void> authorize() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Late remote video upgrades an audio call on feed events without a call state change',
    () async {
      var texture = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (method) async {
          if (method.method == 'createVideoRenderer') {
            return {'textureId': ++texture};
          }
          return null;
        },
      );
      final client = mx.Client('upgrade', database: OutboxDatabase());
      final session = UpgradeSession(OutboxRoom(client));
      session.localUserMediaStream.stream.tracks.clear();
      session.remoteUserMediaStream.stream.tracks.clear();
      final call = DirectCall(session, () {}, (_) {});
      expect(call.video, false);
      session.remoteUserMediaStream.stream.tracks.add(
        MediaTrack('late-video', 'video'),
      );
      session.onCallStreamsChanged.add(session);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(call.video, true);
      expect(call.remoteVideo, isNotNull);
      expect(call.cameraEnabled, false);
      session.remoteUserMediaStream.videoMuted = true;
      session.onCallStreamsChanged.add(session);
      await Future<void>.delayed(Duration.zero);
      expect(call.video, false);
      await call.close();
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        null,
      );
    },
  );
  test(
    'Rear selection is strict, front permits desktop cameras without facingMode, audio is untouched',
    () {
      for (final quality in VideoQuality.values) {
        final rear = cameraConstraints('environment', quality);
        final front = cameraConstraints('user', quality);
        expect(rear['audio'], false);
        expect((rear['video'] as Map)['facingMode'], {'exact': 'environment'});
        expect((front['video'] as Map)['facingMode'], {'ideal': 'user'});
        expect((rear['video'] as Map)['width'], {'ideal': quality.width});
      }
    },
  );
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
  test(
    'Camera off during ringing stops capture before failed signalling and preserves audio',
    () async {
      final session = CameraSession(
        OutboxRoom(mx.Client('camera-off', database: OutboxDatabase())),
      )..failMute = true;
      final camera = MediaTrack('added-camera', 'video'),
          audio = MediaTrack('mic', 'audio');
      session.feed.stream.tracks
        ..clear()
        ..addAll([camera, audio]);
      session.feed.videoMuted = false;
      final reports = <String>[];
      final call = AuthorizedCameraCall(session, () {}, reports.add);
      await call.camera(false);
      expect(camera.stopped, true);
      expect(audio.stopped, false);
      expect(call.cameraEnabled, false);
      expect(reports.single, contains('Камера выключена'));
      expect(
        session.pc.attached.isCompleted,
        false,
        reason: 'Disabling never needs a usable peer connection',
      );
      session.current = mx.CallState.kEnded;
      await call.close();
      expect(audio.stopped, true);
    },
  );
  test(
    'Late camera permission and sender completion cannot keep capture alive after timeout',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final stage in [
        'permission',
        'sender',
        'attached',
        'attached-with-feed',
      ]) {
        final gate = Completer<Map<String, dynamic>>(),
            requested = Completer<void>();
        final disposed = <String>[];
        final lifecycle = <String>[];
        messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Method'),
          (method) async {
            lifecycle.add(method.method);
            if (method.method == 'getUserMedia') {
              requested.complete();
              return await gate.future;
            }
            if (method.method == 'trackDispose') {
              disposed.add(method.arguments['trackId'] as String);
            }
            if (method.method == 'createVideoRenderer') {
              return {'textureId': 42};
            }
            return null;
          },
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC/Texture42'),
          (_) async => null,
        );
        final session = CameraSession(
          OutboxRoom(mx.Client('camera-$stage', database: OutboxDatabase())),
        );
        final audio = MediaTrack('mic', 'audio');
        session.feed.stream.tracks
          ..clear()
          ..add(audio);
        if (stage == 'sender') session.pc.gate = Completer<rtc.RTCRtpSender>();
        final call = AuthorizedCameraCall(session, () {}, (_) {});
        final enabling = call.camera(true);
        await requested.future;
        Future<void> timeout() async {
          session.current = mx.CallState.kEnded;
          await call.close();
        }

        if (stage == 'permission') await timeout();
        gate.complete({
          'streamId': 'new-camera',
          'audioTracks': [],
          'videoTracks': [
            {
              'id': 'late-video',
              'label': 'fixture',
              'kind': 'video',
              'enabled': true,
            },
          ],
        });
        if (stage == 'sender') {
          await session.pc.attached.future;
          await timeout();
          session.pc.gate!.complete(session.pc.sender);
        }
        if (stage.startsWith('attached')) {
          await enabling;
          // SDK can clear its feed before the application receives the ended callback.
          session.cleared = stage == 'attached';
          await timeout();
          expect(
            call.video,
            true,
            reason: 'Keep final call type after releasing the camera',
          );
        } else {
          await expectLater(enabling, throwsStateError);
        }
        expect(disposed, contains('late-video'), reason: stage);
        expect(
          lifecycle.indexOf('trackDispose'),
          lessThan(lifecycle.indexOf('streamDispose')),
          reason: 'Release hardware before disposing its native stream',
        );
        expect(call.cameraEnabled, false);
        if (stage != 'attached') expect(audio.stopped, true);
        await call.close();
        messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Method'),
          null,
        );
        messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC/Texture42'),
          null,
        );
      }
    },
  );
}
