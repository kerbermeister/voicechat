import 'dart:math' as math;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

enum AudioBitrate {
  // Android's SDK ignores null when updating maxBitrate. The Opus ceiling
  // removes our voice preset cap while retaining WebRTC congestion control.
  auto('Авто', 510000),
  low('Экономный · 16 кбит/с', 16000),
  medium('Обычный · 32 кбит/с', 32000),
  high('Высокий · 64 кбит/с', 64000);

  final String label;
  final int bitsPerSecond;
  const AudioBitrate(this.label, this.bitsPerSecond);
}

Future<void> applyAudioBitrate(
  rtc.RTCRtpSender sender,
  AudioBitrate value,
) async {
  final parameters = sender.parameters;
  final encodings = parameters.encodings;
  if (encodings == null || encodings.isEmpty) {
    throw StateError('Audio sender is not ready');
  }
  for (final encoding in encodings) {
    encoding.maxBitrate = value.bitsPerSecond;
  }
  if (!await sender.setParameters(parameters)) {
    throw StateError('Audio bitrate was not applied');
  }
}

enum VideoQuality {
  auto('Авто', 1280, 720, 30, 1500000),
  low('Низкое', 320, 180, 15, 150000),
  medium('Среднее', 640, 360, 24, 500000),
  high('Высокое', 1280, 720, 30, 1500000);

  final String label;
  final int width, height, fps, bitrate;
  const VideoQuality(
    this.label,
    this.width,
    this.height,
    this.fps,
    this.bitrate,
  );
}

Future<void> applyVideoEncoding(
  rtc.RTCRtpSender sender,
  VideoQuality quality,
) async {
  final parameters = sender.parameters;
  final encodings = parameters.encodings;
  if (encodings == null || encodings.isEmpty) {
    throw StateError('Video sender is not ready');
  }
  final settings = sender.track?.getSettings();
  final width = settings?['width'] as num? ?? 1280;
  final height = settings?['height'] as num? ?? 720;
  for (final encoding in encodings) {
    encoding.maxBitrate = quality.bitrate;
    encoding.maxFramerate = quality.fps;
    encoding.scaleResolutionDownBy = math
        .max(1, math.max(width / quality.width, height / quality.height))
        .toDouble();
  }
  if (!await sender.setParameters(parameters)) {
    throw StateError('Video quality was not applied');
  }
}

enum CallQuality {
  unknown('Оцениваем связь'),
  excellent('Отличная связь'),
  good('Хорошая связь'),
  poor('Слабая связь'),
  lost('Связь потеряна');

  final String label;
  const CallQuality(this.label);
}

/// Packet loss is measured between samples, not over the lifetime of the call.
class CallStatistics {
  final _clock = Stopwatch()..start();
  final _samples = <Map<String, Object>>[];
  List<Map<String, Object>> get samples => List.unmodifiable(_samples);
  final _packets = <String, ({num received, num lost})>{};
  CallQuality read(List<rtc.StatsReport> reports) {
    double loss = 0, jitter = 0, rtt = 0;
    var measured = false, measuredRtt = false;
    var receivedPackets = 0;
    final encoderLimits = <String>{};
    final selected = reports
        .where((r) => r.type == 'transport')
        .map((r) => r.values['selectedCandidatePairId'])
        .whereType<String>()
        .toSet();
    for (final report in reports) {
      final values = report.values;
      if (report.type == 'candidate-pair' &&
          values['state'] == 'succeeded' &&
          (selected.contains(report.id) ||
              (selected.isEmpty &&
                  (values['nominated'] == true ||
                      values['selected'] == true)))) {
        final latency = values['currentRoundTripTime'];
        if (latency is num && latency.isFinite && latency >= 0) {
          rtt = latency.toDouble();
          measuredRtt = true;
        }
      }
      if (report.type == 'outbound-rtp' &&
          const {
            'none',
            'cpu',
            'bandwidth',
            'other',
          }.contains(values['qualityLimitationReason'])) {
        encoderLimits.add(values['qualityLimitationReason'] as String);
      }
      if (report.type != 'inbound-rtp') continue;
      final received = values['packetsReceived'];
      final lost = values['packetsLost'];
      if (received is! num || lost is! num) continue;
      final previous = _packets[report.id];
      _packets[report.id] = (received: received, lost: lost);
      if (previous == null || received < previous.received) continue;
      final delivered = received - previous.received;
      final missing = (lost - previous.lost).clamp(0, double.infinity);
      if (delivered + missing == 0) continue;
      measured = true;
      receivedPackets += delivered.toInt();
      final fraction = missing / (delivered + missing);
      if (fraction > loss) loss = fraction;
      final current = (values['jitter'] as num? ?? 0).toDouble();
      if (current > jitter) jitter = current;
    }
    final quality = !measured
        ? CallQuality.unknown
        : loss >= .08 || jitter >= .08 || rtt >= .6
        ? CallQuality.poor
        : loss >= .02 || jitter >= .03 || rtt >= .25
        ? CallQuality.good
        : CallQuality.excellent;
    // Bounded local evidence for brief drops; never retain IDs, SDP or addresses.
    _samples.add(
      Map.unmodifiable({
        'elapsed_ms': _clock.elapsedMilliseconds,
        'raw_quality': quality.name,
        'received_packets': receivedPackets,
        'streams': mediaCounters(reports),
        if (measured) 'loss_percent': loss * 100,
        if (measured) 'jitter_ms': jitter * 1000,
        if (measuredRtt) 'rtt_ms': rtt * 1000,
        'causes': [
          if (measured && loss >= .02) 'packet_loss',
          if (measured && jitter >= .03) 'jitter',
          if (measured && rtt >= .25) 'round_trip_time',
        ],
        if (encoderLimits.isNotEmpty) 'encoder_limits': encoderLimits.toList(),
      }),
    );
    if (_samples.length > 60) _samples.removeAt(0);
    return quality;
  }
}

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
          'nackCount',
          'pliCount',
        ])
          if (report.values[field] is num &&
              (report.values[field] as num).isFinite)
            field: report.values[field] as num,
      },
];

/// Receiver reports describe our outgoing path; inbound loss belongs to the peer.
CallQuality outgoingVideoQuality(List<rtc.StatsReport> reports) {
  var measured = false;
  double loss = 0;
  for (final sender in reports) {
    if (sender.type != 'outbound-rtp' ||
        (sender.values['kind'] ?? sender.values['mediaType']) != 'video' ||
        sender.values['active'] == false) {
      continue;
    }
    if (sender.values['qualityLimitationReason'] == 'cpu') {
      return CallQuality.poor;
    }
    for (final remote in reports) {
      if (remote.type != 'remote-inbound-rtp' ||
          remote.id != sender.values['remoteId']) {
        continue;
      }
      final fraction = remote.values['fractionLost'];
      if (fraction is! num ||
          !fraction.isFinite ||
          fraction < 0 ||
          fraction > 1) {
        continue;
      }
      measured = true;
      if (fraction > loss) loss = fraction.toDouble();
    }
  }
  return !measured
      ? CallQuality.unknown
      : loss >= .08
      ? CallQuality.poor
      : loss >= .02
      ? CallQuality.good
      : CallQuality.excellent;
}

/// Brief spikes must not repeatedly switch video encodings. Recovery needs
/// three good samples; sustained degradation takes two. Loss of ICE is immediate.
class StableCallQuality {
  CallQuality value = CallQuality.unknown;
  CallQuality? _candidate;
  int _samples = 0;
  int _missing = 0;

  CallQuality update(CallQuality next) {
    if (next == CallQuality.unknown) {
      _candidate = null;
      _samples = 0;
      if (++_missing >= 3) value = CallQuality.unknown;
      return value;
    }
    _missing = 0;
    if (value == CallQuality.unknown ||
        next == CallQuality.lost ||
        next == value) {
      value = next;
      _candidate = null;
      _samples = 0;
      return value;
    }
    _samples = _candidate == next ? _samples + 1 : 1;
    _candidate = next;
    final recovering = next.index < value.index;
    if (_samples >= (recovering ? 3 : 2)) {
      value = next;
      _candidate = null;
      _samples = 0;
    }
    return value;
  }
}

VideoQuality adaptiveVideoQuality(VideoQuality selected, CallQuality quality) =>
    selected != VideoQuality.auto
    ? selected
    : switch (quality) {
        CallQuality.poor || CallQuality.lost => VideoQuality.low,
        CallQuality.good => VideoQuality.medium,
        _ => VideoQuality.auto,
      };
