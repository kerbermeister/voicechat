import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:voicechat_probe/media_statistics.dart';

StatsReport report(String id, double at, Map<String, dynamic> values) =>
    StatsReport(id, 'inbound-rtp', at, {'kind': 'audio', ...values});

void main() {
  test(
    'Sender queue and encode metrics represent only the latest interval',
    () {
      final stats = MediaStatistics();
      StatsReport sent(
        double at,
        int packets,
        double delay,
        int frames,
        double encode,
      ) => StatsReport('sender', 'outbound-rtp', at, {
        'kind': 'video',
        'packetsSent': packets,
        'totalPacketSendDelay': delay,
        'framesEncoded': frames,
        'totalEncodeTime': encode,
        'qualityLimitationReason': 'cpu',
      });
      stats.read([sent(1000, 100, 1, 10, .1)]);
      final row = stats.read([sent(2000, 200, 3, 30, .5)]).single;
      expect(row['send_queue_ms_per_packet'], 20);
      expect(row['encoded_fps'], 20);
      expect(row['encode_ms_per_frame'], 20);
      expect(row['encoder_limit'], 'cpu');
    },
  );
  test(
    'Transport evidence uses only the RTP stream selected pair and never exports addresses',
    () {
      final stats = MediaStatistics();
      final row = stats.read([
        report('rtp', 1000, {'transportId': 'transport'}),
        StatsReport('transport', 'transport', 1000, {
          'selectedCandidatePairId': 'selected',
        }),
        StatsReport('selected', 'candidate-pair', 1000, {
          'state': 'succeeded',
          'currentRoundTripTime': .025,
          'availableOutgoingBitrate': 500000,
          'localCandidateId': 'candidate',
        }),
        StatsReport('obsolete', 'candidate-pair', 1000, {
          'state': 'succeeded',
          'currentRoundTripTime': 10,
        }),
        StatsReport('candidate', 'local-candidate', 1000, {
          'protocol': 'udp',
          'relayProtocol': 'tcp',
          'candidateType': 'relay',
          'address': 'private-ip',
        }),
      ]).single;
      expect(row['rtt_ms'], 25);
      expect(row['available_outgoing_bps'], 500000);
      expect(row['protocol'], 'udp');
      expect(row['relayProtocol'], 'tcp');
      expect(row['candidateType'], 'relay');
      expect(jsonEncode(row), isNot(contains('private')));
      expect(jsonEncode(row), isNot(contains('candidateId')));
    },
  );
  test(
    'Interval bitrate, buffer delay and concealment use deltas, not lifetime averages',
    () {
      final stats = MediaStatistics();
      final first = stats.read([
        report('private-source', 1000, {
          'bytesReceived': 1000,
          'jitterBufferDelay': 1.0,
          'jitterBufferEmittedCount': 100,
          'totalSamplesReceived': 1000,
          'concealedSamples': 10,
          'framesDecoded': 10,
          'totalDecodeTime': .25,
        }),
      ]).single;
      expect(first.containsKey('bitrate_bps'), false);
      final next = stats.read([
        report('private-source', 2000, {
          'bytesReceived': 2000,
          'jitterBufferDelay': 5.0,
          'jitterBufferEmittedCount': 200,
          'totalSamplesReceived': 1200,
          'concealedSamples': 30,
          'framesDecoded': 20,
          'totalDecodeTime': .45,
          'ip': 'secret-ip',
          'trackIdentifier': 'secret-track',
        }),
      ]).single;
      expect(next['stream_index'], first['stream_index']);
      expect(next['bitrate_bps'], 8000);
      expect(next['buffer_delay_ms'], 40);
      expect(next['concealed_percent'], 10);
      expect(next['decode_ms_per_frame'], closeTo(20, .0001));
      expect(jsonEncode(next), isNot(contains('private')));
      expect(jsonEncode(next), isNot(contains('secret')));
    },
  );
  test(
    'Counter reset, missing streams and transport rebuild never join unrelated intervals',
    () {
      final stats = MediaStatistics();
      final first = stats.read([
        report('reused', 1000, {'bytesReceived': 1000}),
      ]).single;
      final reset = stats.read([
        report('reused', 2000, {'bytesReceived': 10}),
      ]).single;
      expect(reset['counter_reset'], true);
      expect(reset.containsKey('bitrate_bps'), false);
      stats.read([]);
      final returned = stats.read([
        report('reused', 3000, {'bytesReceived': 100}),
      ]).single;
      expect(returned['stream_index'], isNot(first['stream_index']));
      expect(returned.containsKey('bitrate_bps'), false);
      stats.reset();
      final rebuilt = stats.read([
        report('reused', 4000, {'bytesReceived': 200}),
      ]).single;
      expect(rebuilt['stream_index'], isNot(returned['stream_index']));
      expect(rebuilt.containsKey('bitrate_bps'), false);
    },
  );
  test('Overflowing derived values never enter the exported snapshot', () {
    final stats = MediaStatistics();
    stats.read([
      report('source', 1000, {'bytesReceived': 0}),
    ]);
    final row = stats.read([
      report('source', 1001, {'bytesReceived': 1e308}),
    ]).single;
    expect(row.containsKey('bitrate_bps'), false);
    expect(() => jsonEncode(row), returnsNormally);
  });
  test(
    'Absent counters, zero denominators and repeated timestamps remain unknown',
    () {
      final stats = MediaStatistics();
      stats.read([
        report('source', 1000, {
          'jitterBufferDelay': 1,
          'jitterBufferEmittedCount': 0,
        }),
      ]);
      final row = stats.read([
        report('source', 1000, {
          'jitterBufferDelay': 2,
          'jitterBufferEmittedCount': 0,
        }),
      ]).single;
      expect(row.containsKey('buffer_delay_ms'), false);
      expect(row.containsKey('concealed_percent'), false);
      expect(row.containsKey('bitrate_bps'), false);
      expect(row.containsKey('interval_ms'), false);
    },
  );
  test(
    'Repeated receiver reports are deduplicated and the stream state is bounded',
    () {
      final stats = MediaStatistics();
      final duplicate = report('duplicate', 1000, {'bytesReceived': 1});
      expect(stats.read([duplicate, duplicate]).length, 1);
      expect(
        stats.read([
          for (var i = 0; i < 100; i++)
            report('$i', 2000, {'bytesReceived': 1}),
        ]).length,
        64,
      );
    },
  );
}
