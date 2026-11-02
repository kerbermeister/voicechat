import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:voicechat_probe/call_quality.dart';

class Sender extends Fake implements rtc.RTCRtpSender {
  @override
  rtc.RTCRtpParameters parameters = rtc.RTCRtpParameters(
    encodings: [rtc.RTCRtpEncoding()],
  );
  bool accepted = true;
  final applied = <int?>[];
  @override
  Future<bool> setParameters(rtc.RTCRtpParameters value) async {
    applied.add(value.encodings!.single.maxBitrate);
    return accepted;
  }
}

void main() {
  test(
    'Live bitrate changes apply all presets and restore automatic encoding',
    () async {
      final sender = Sender();
      for (final value in [
        AudioBitrate.low,
        AudioBitrate.high,
        AudioBitrate.medium,
        AudioBitrate.auto,
      ]) {
        await applyAudioBitrate(sender, value);
      }
      expect(sender.applied, [16000, 64000, 32000, 510000]);
    },
  );
  test(
    'Unavailable or rejected sender never reports a successful bitrate change',
    () async {
      final sender = Sender()..accepted = false;
      await expectLater(
        applyAudioBitrate(sender, AudioBitrate.high),
        throwsStateError,
      );
      sender.parameters = rtc.RTCRtpParameters(encodings: []);
      await expectLater(
        applyAudioBitrate(sender, AudioBitrate.low),
        throwsStateError,
      );
      expect(sender.applied, [64000]);
    },
  );
}
