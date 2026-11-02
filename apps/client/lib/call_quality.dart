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
