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
  test('Only the selected ICE pair contributes latency', () {
    final stats = CallStatistics();
    List<StatsReport> samples(int count) => [
      report(count, 0),
      StatsReport('transport', 'transport', 0, {
        'selectedCandidatePairId': 'live',
      }),
      StatsReport('live', 'candidate-pair', 0, {
        'state': 'succeeded',
        'currentRoundTripTime': .02,
      }),
      StatsReport('old', 'candidate-pair', 0, {
        'state': 'succeeded',
        'currentRoundTripTime': 5,
      }),
    ];
    stats.read(samples(100));
    expect(stats.read(samples(200)), CallQuality.excellent);
    expect(stats.samples.last['rtt_ms'], 20);
    expect(stats.samples.last['causes'], isEmpty);
  });
  test(
    'Quality evidence retains real spikes, bounds history and excludes private stats',
    () {
      final stats = CallStatistics();
      stats.read([report(100, 0)]);
      stats.read([report(180, 20, jitter: .1)]);
      expect(stats.samples.last['raw_quality'], 'poor');
      expect(stats.samples.last['loss_percent'], 20);
      expect(stats.samples.last['causes'], ['packet_loss', 'jitter']);
      for (var i = 0; i < 80; i++) {
        stats.read([
          report(280 + i * 100, 20),
          StatsReport('private-id', 'outbound-rtp', 0, {
            'qualityLimitationReason': i == 79 ? 'private-value' : 'cpu',
            'ip': 'private-address',
            'trackIdentifier': 'private-track',
          }),
        ]);
      }
      expect(stats.samples.length, 60);
      expect(stats.samples[58]['encoder_limits'], ['cpu']);
      expect(stats.samples.last.containsKey('encoder_limits'), false);
      expect(stats.samples.toString(), isNot(contains('private')));
      expect(stats.samples.last['raw_quality'], 'excellent');
      expect(() => stats.samples.clear(), throwsUnsupportedError);
    },
  );
  test(
    'Transient quality spikes do not oscillate encodings; stale measurements expire',
    () {
      final stable = StableCallQuality();
      expect(stable.update(CallQuality.excellent), CallQuality.excellent);
      expect(stable.update(CallQuality.poor), CallQuality.excellent);
      expect(stable.update(CallQuality.excellent), CallQuality.excellent);
      stable.update(CallQuality.poor);
      expect(stable.update(CallQuality.poor), CallQuality.poor);
      stable.update(CallQuality.excellent);
      expect(stable.update(CallQuality.excellent), CallQuality.poor);
      expect(stable.update(CallQuality.excellent), CallQuality.excellent);
      expect(stable.update(CallQuality.lost), CallQuality.lost);
      stable.update(CallQuality.unknown);
      stable.update(CallQuality.unknown);
      expect(stable.update(CallQuality.unknown), CallQuality.unknown);
      expect(
        adaptiveVideoQuality(VideoQuality.auto, CallQuality.poor),
        VideoQuality.low,
      );
      expect(
        adaptiveVideoQuality(VideoQuality.auto, CallQuality.good),
        VideoQuality.medium,
      );
      expect(
        adaptiveVideoQuality(VideoQuality.auto, CallQuality.excellent),
        VideoQuality.auto,
      );
      expect(
        adaptiveVideoQuality(VideoQuality.high, CallQuality.poor),
        VideoQuality.high,
      );
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
