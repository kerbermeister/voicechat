import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:voicechat_probe/call_probe.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:voicechat_probe/call_audio.dart';
import 'package:voicechat_probe/direct_call.dart';
import 'chat_actions_test.dart' show VideoSession, OutboxRoom;
import 'conversation_list_test.dart' show ListClient;
import 'direct_call_media_test.dart' show MediaTrack;

class AudioStream extends Fake implements rtc.MediaStream {
  final tracks = <rtc.MediaStreamTrack>[];
  @override
  List<rtc.MediaStreamTrack> getAudioTracks() => tracks;
}

class AudioFeed extends Fake implements mx.WrappedMediaStream {
  @override
  final AudioStream stream = AudioStream();
}

class AudioSession extends VideoSession {
  @override
  mx.CallType get type => mx.CallType.kVoice;
  @override
  bool get isLocalVideoMuted => true;
  @override
  final mx.Room room;
  AudioSession(this.room);
  @override
  String get remoteUserId => '@friend:local';
  final feed = AudioFeed();
  @override
  List<mx.WrappedMediaStream> get getRemoteStreams => [feed];
}

class GroupAudioCall extends Fake implements CallProbe {
  @override
  bool get video => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Android group speaker starts from the LiveKit route on the first tap',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final manager = lk.AudioManager.instance;
      manager.resetForTest();
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        manager.resetForTest();
      });
      final call = GroupAudioCall();
      final audio = CallAudio();
      expect(manager.isSpeakerOutputPreferred, true);
      await audio.toggleSpeaker(call);
      expect(audio.speakerEnabled, false);
      await audio.toggleSpeaker(call);
      expect(audio.speakerEnabled, true);
      expect(manager.isSpeakerOutputPreferred, true);
      audio.reset(GroupAudioCall());
      expect(audio.speakerEnabled, true);
    },
  );
  test('Desktop group speaker state keeps its existing behavior', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final audio = CallAudio()..reset(GroupAudioCall());
    expect(audio.speakerEnabled, false);
  });
  test(
    'Direct speakerphone toggles the WebRTC route and preserves state on failure',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final writes = <bool>[];
      var fail = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (call) async {
          if (call.method == 'enableSpeakerphone') {
            if (fail) throw PlatformException(code: 'route_unavailable');
            writes.add((call.arguments as Map)['enable'] as bool);
          }
          return null;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Method'),
          null,
        ),
      );
      final call = DirectCall(
        AudioSession(OutboxRoom(ListClient())),
        () {},
        (_) {},
      );
      final audio = CallAudio();
      await audio.toggleSpeaker(call);
      expect(audio.speakerEnabled, true);
      await audio.toggleSpeaker(call);
      expect(audio.speakerEnabled, false);
      expect(writes, [true, false]);
      fail = true;
      await expectLater(
        audio.toggleSpeaker(call),
        throwsA(isA<PlatformException>()),
      );
      expect(audio.speakerEnabled, false);
      await call.close();
    },
  );
  test(
    'Android direct audio acquires and releases the LiveKit session once',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final writes = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('livekit_client'),
        (call) async {
          writes.add(call.method);
          return null;
        },
      );
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(
          const MethodChannel('livekit_client'),
          null,
        );
      });
      final audio = CallAudio();
      await audio.stopDirectAudio();
      expect(writes, isEmpty);
      await audio.startDirectAudio();
      await audio.stopDirectAudio();
      await audio.stopDirectAudio();
      expect(writes, [
        'configureAndroidAudioSession',
        'stopAndroidAudioSession',
      ]);
    },
  );
  test(
    'Receiver volume clamps inputs, follows a replacement track and resets for a new call',
    () async {
      final writes = <Map<dynamic, dynamic>>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (call) async {
          if (call.method == 'setVolume') writes.add(call.arguments as Map);
          return null;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Method'),
          null,
        ),
      );
      final session = AudioSession(OutboxRoom(ListClient()));
      final call = DirectCall(session, () {}, (_) {});
      final track = MediaTrack('first', 'audio');
      session.feed.stream.tracks.add(track);
      final audio = CallAudio();
      await audio.sync(call);
      expect(writes.last['volume'], 1);
      await audio.set(call, '@friend:local', 3);
      expect(writes.last['volume'], 3);
      await audio.set(call, '@friend:local', 0);
      expect(writes.last['volume'], 0);
      expect(track.enabled, true);
      session.feed.stream.tracks[0] = MediaTrack('replacement', 'audio');
      await audio.sync(call);
      expect(writes.last['trackId'], 'replacement');
      expect(writes.last['volume'], 0);
      for (final value in [-1.0, 3.1, double.nan]) {
        await expectLater(
          audio.set(call, '@friend:local', value),
          throwsArgumentError,
        );
      }
      await expectLater(
        audio.set(call, '@stranger:local', 1),
        throwsArgumentError,
      );
      audio.reset(null);
      expect(audio.level('@friend:local'), 1);
      await call.close();
    },
  );
}
