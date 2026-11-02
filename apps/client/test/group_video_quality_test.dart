import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:voicechat_probe/call_probe.dart';
import 'package:voicechat_probe/call_quality.dart';
import 'call_bitrate_test.dart' show Sender;
import 'direct_call_media_test.dart' show MediaTrack;
import 'chat_actions_test.dart' show OutboxRoom;
import 'conversation_list_test.dart' show ListClient;

class Camera extends MediaTrack {
  Camera() : super('camera', 'video');
  @override
  Map<String, dynamic> getSettings() => {'width': 1280, 'height': 720};
}

class VideoSender extends Sender {
  @override
  final Camera track = Camera();
}

class VideoTrack extends Fake implements lk.LocalVideoTrack {
  @override
  final VideoSender sender = VideoSender();
  @override
  rtc.MediaStreamTrack get mediaStreamTrack => sender.track;
}

class Publication extends Fake
    implements lk.LocalTrackPublication<lk.LocalVideoTrack> {
  @override
  final VideoTrack track = VideoTrack();
}

class Participant extends Fake implements lk.LocalParticipant {
  final publication = Publication();
  @override
  List<lk.LocalTrackPublication<lk.LocalVideoTrack>>
  get videoTrackPublications => [publication];
}

class Media extends Fake implements lk.Room {
  @override
  final Participant localParticipant = Participant();
}

void main() {
  for (final rejected in [false, true]) {
    test(
      'Group manual quality preserves capture and publication; rejected=$rejected',
      () async {
        final media = Media();
        final sender = media.localParticipant.publication.track.sender
          ..accepted = !rejected;
        final call =
            CallProbe(
                chat: OutboxRoom(ListClient()),
                session: 'quality',
                tokenUrl: 'http://localhost:8090',
                livekitUrl: 'ws://localhost:7880',
                status: (_) {},
                video: true,
              )
              ..media = media
              ..cameraEnabled = true
              ..videoQuality = VideoQuality.high;
        if (rejected) {
          await expectLater(
            call.setVideoQuality(VideoQuality.medium),
            throwsStateError,
          );
          expect(call.videoQuality, VideoQuality.high);
        } else {
          await call.setVideoQuality(VideoQuality.medium);
          expect(call.videoQuality, VideoQuality.medium);
          expect(sender.parameters.encodings!.single.scaleResolutionDownBy, 2);
          await call.setVideoQuality(VideoQuality.high);
          expect(sender.parameters.encodings!.single.scaleResolutionDownBy, 1);
        }
        expect(call.cameraEnabled, true);
        expect(sender.track.stopped, false);
        expect(media.localParticipant.publication.track.sender, same(sender));
        // Any unpublish/republish would fail through Fake's unimplemented methods.
      },
    );
  }
}
