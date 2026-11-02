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
  final _packets = <String, ({num received, num lost})>{};
  CallQuality read(List<rtc.StatsReport> reports) {
    double loss = 0, jitter = 0, rtt = 0;
    var measured = false;
    for (final report in reports) {
      final values = report.values;
      if (report.type == 'candidate-pair' && values['state'] == 'succeeded') {
        rtt = (values['currentRoundTripTime'] as num? ?? 0).toDouble();
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
      final fraction = missing / (delivered + missing);
      if (fraction > loss) loss = fraction;
      final current = (values['jitter'] as num? ?? 0).toDouble();
      if (current > jitter) jitter = current;
    }
    if (!measured) return CallQuality.unknown;
    if (loss >= .08 || jitter >= .08 || rtt >= .6) return CallQuality.poor;
    if (loss >= .02 || jitter >= .03 || rtt >= .25) return CallQuality.good;
    return CallQuality.excellent;
  }
}
