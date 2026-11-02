import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Cumulative counters only. The caller computes interval deltas; missing is not zero.
List<Map<String, Object>> mediaCounters(List<rtc.StatsReport> reports) => [
  for (final report
      in reports
          .where(
            (r) => const {
              'inbound-rtp',
              'outbound-rtp',
              'remote-inbound-rtp',
            }.contains(r.type),
          )
          .take(64))
    if (const {
      'audio',
      'video',
    }.contains(report.values['kind'] ?? report.values['mediaType']))
      {
        'direction': report.type,
        'kind': (report.values['kind'] ?? report.values['mediaType']) as String,
        if (report.type == 'outbound-rtp' &&
            const {
              'none',
              'cpu',
              'bandwidth',
              'other',
            }.contains(report.values['qualityLimitationReason']))
          'encoder_limit': report.values['qualityLimitationReason'] as String,
        for (final field in const [
          'packetsReceived',
          'packetsSent',
          'packetsLost',
          'bytesReceived',
          'bytesSent',
          'jitter',
          'roundTripTime',
          'fractionLost',
          'jitterBufferDelay',
          'jitterBufferEmittedCount',
          'jitterBufferTargetDelay',
          'jitterBufferMinimumDelay',
          'concealedSamples',
          'silentConcealedSamples',
          'concealmentEvents',
          'totalSamplesReceived',
          'framesDecoded',
          'framesEncoded',
          'framesDropped',
          'freezeCount',
          'totalFreezesDuration',
          'totalDecodeTime',
          'totalEncodeTime',
          'totalPacketSendDelay',
          'frameWidth',
          'frameHeight',
          'framesPerSecond',
          'nackCount',
          'pliCount',
        ])
          if (report.values[field] is num &&
              (report.values[field] as num).isFinite)
            field: report.values[field] as num,
      },
];

/// Identifiers stay in memory; indices are unique only within this sampler.
class MediaStatistics {
  final _previous =
      <String, ({double at, Map<String, num> counters, int index})>{};
  int _nextIndex = 0;

  void reset() => _previous.clear();

  List<Map<String, Object>> read(List<rtc.StatsReport> reports) {
    final result = <Map<String, Object>>[];
    final seen = <String>{};
    final byId = {for (final report in reports) report.id: report};
    for (final report in reports) {
      if (result.length == 64) break;
      final raw = mediaCounters([report]).firstOrNull;
      if (raw == null) continue;
      final key = '${report.type}/${report.id}';
      if (!seen.add(key)) continue;
      final previous = _previous[key];
      final index = previous?.index ?? _nextIndex++;
      final values = {
        for (final entry in raw.entries)
          if (entry.value is num) entry.key: entry.value as num,
      };
      final at = report.timestamp;
      final row = <String, Object>{...raw, 'stream_index': index};
      void metric(String name, num value) {
        if (value.isFinite && value >= 0) row[name] = value;
      }

      final transport = byId[report.values['transportId']];
      final pair = byId[transport?.values['selectedCandidatePairId']];
      if (pair?.type == 'candidate-pair' &&
          pair?.values['state'] == 'succeeded') {
        final rtt = pair?.values['currentRoundTripTime'];
        if (rtt is num) metric('rtt_ms', rtt * 1000);
        final available = pair?.values['availableOutgoingBitrate'];
        if (available is num) metric('available_outgoing_bps', available);
        final candidate = byId[pair?.values['localCandidateId']];
        for (final field in ['protocol', 'relayProtocol', 'candidateType']) {
          final value = candidate?.values[field];
          final allowed = field == 'candidateType'
              ? const {'host', 'srflx', 'prflx', 'relay'}
              : const {'udp', 'tcp', 'tls'};
          if (allowed.contains(value)) row[field] = value as String;
        }
      }
      final reset =
          previous != null &&
          const [
            'bytesReceived',
            'bytesSent',
            'packetsReceived',
            'packetsSent',
            'jitterBufferEmittedCount',
            'totalSamplesReceived',
            'framesDecoded',
            'framesEncoded',
          ].any(
            (field) =>
                values[field] != null &&
                previous.counters[field] != null &&
                values[field]! < previous.counters[field]!,
          );
      if (reset) row['counter_reset'] = true;
      if (previous != null &&
          !reset &&
          at.isFinite &&
          (at - previous.at).isFinite &&
          at > previous.at) {
        final milliseconds = at - previous.at;
        row['interval_ms'] = milliseconds;
        num? delta(String name) {
          final current = values[name], old = previous.counters[name];
          if (current == null || old == null || current < old) return null;
          final difference = current - old;
          return difference.isFinite ? difference : null;
        }

        final bytes = delta(
          report.type == 'outbound-rtp' ? 'bytesSent' : 'bytesReceived',
        );
        if (bytes != null) metric('bitrate_bps', bytes * 8000 / milliseconds);
        final sent = delta('packetsSent'),
            queued = delta('totalPacketSendDelay');
        if (sent != null && sent > 0 && queued != null) {
          metric('send_queue_ms_per_packet', queued * 1000 / sent);
        }
        final emitted = delta('jitterBufferEmittedCount');
        final delay = delta('jitterBufferDelay');
        if (emitted != null && emitted > 0 && delay != null) {
          metric('buffer_delay_ms', delay * 1000 / emitted);
        }
        final samples = delta('totalSamplesReceived'),
            concealed = delta('concealedSamples');
        if (samples != null &&
            samples > 0 &&
            concealed != null &&
            concealed <= samples) {
          metric('concealed_percent', concealed * 100 / samples);
        }
        for (final operation in ['Decode', 'Encode']) {
          final frames = delta('frames${operation}d'),
              time = delta('total${operation}Time');
          if (frames != null && frames > 0 && time != null) {
            metric(
              '${operation.toLowerCase()}d_fps',
              frames * 1000 / milliseconds,
            );
            metric(
              '${operation.toLowerCase()}_ms_per_frame',
              time * 1000 / frames,
            );
          }
        }
      }
      if (at.isFinite) {
        _previous[key] = (at: at, counters: values, index: index);
      }
      result.add(row);
    }
    _previous.removeWhere((key, _) => !seen.contains(key));
    return result;
  }
}
