import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:voicechat_probe/call_quality.dart';
import 'package:voicechat_probe/call_probe.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

void main() {
  test(
    'Media admission rejects clear tracks, unsupported cryptors and unsolicited camera',
    () {
      bool allowed(
        lk.EncryptionType encryption,
        lk.TrackSource source,
        String mime,
        bool video,
      ) => allowsCallMedia(encryption, source, mime, video: video);
      expect(
        allowed(
          lk.EncryptionType.kGcm,
          lk.TrackSource.microphone,
          'audio/opus',
          false,
        ),
        true,
      );
      expect(
        allowed(
          lk.EncryptionType.kNone,
          lk.TrackSource.microphone,
          'audio/opus',
          false,
        ),
        false,
      );
      expect(
        allowed(
          lk.EncryptionType.kGcm,
          lk.TrackSource.camera,
          'video/VP8',
          false,
        ),
        false,
      );
      expect(
        allowed(
          lk.EncryptionType.kGcm,
          lk.TrackSource.camera,
          'video/VP8',
          true,
        ),
        true,
      );
      expect(
        allowed(
          lk.EncryptionType.kGcm,
          lk.TrackSource.camera,
          'video/AV1',
          true,
        ),
        false,
      );
      expect(
        allowed(
          lk.EncryptionType.kGcm,
          lk.TrackSource.screenShareVideo,
          'video/VP8',
          true,
        ),
        false,
      );
    },
  );
  StatsReport report(int received, int lost, {double jitter = .01}) =>
      StatsReport('audio', 'inbound-rtp', 0, {
        'packetsReceived': received,
        'packetsLost': lost,
        'jitter': jitter,
      });
  test(
    'Quality uses interval loss, recovers, and never invents missing statistics',
    () {
      final stats = CallStatistics();
      expect(stats.read([]), CallQuality.unknown);
      expect(stats.read([report(100, 10)]), CallQuality.unknown);
      expect(stats.read([report(200, 10)]), CallQuality.excellent);
      expect(stats.read([report(290, 20)]), CallQuality.poor);
      expect(stats.read([report(390, 20)]), CallQuality.excellent);
      expect(stats.read([report(390, 20)]), CallQuality.unknown);
      expect(stats.read([report(490, 20, jitter: .1)]), CallQuality.poor);
      expect(stats.read([report(1, 0)]), CallQuality.unknown);
    },
  );
  test(
    'Video caps increase predictably and Auto uses the adaptive 720p ceiling',
    () {
      expect(VideoQuality.low.bitrate, lessThan(VideoQuality.medium.bitrate));
      expect(VideoQuality.medium.bitrate, lessThan(VideoQuality.high.bitrate));
      expect(VideoQuality.auto.height, 720);
      expect(VideoQuality.low.fps, 15);
    },
  );
}
