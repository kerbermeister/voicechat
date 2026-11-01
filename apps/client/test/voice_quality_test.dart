import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/voice_recording.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Voice quality defaults to 24 kHz and accepts only supported saved rates',
    () async {
      for (final saved in [null, '48000', 0, 44100, 16000, 24000, 48000]) {
        SharedPreferences.setMockInitialValues({
          if (saved != null) voiceSampleRateKey: saved,
        });
        final prefs = await SharedPreferences.getInstance();
        expect(
          preferredVoiceSampleRate(prefs),
          saved is int && voiceSampleRates.contains(saved) ? saved : 24000,
        );
      }
    },
  );
  test(
    'Every quality keeps its actual sample rate, duration and 50 ms meter window',
    () {
      for (final rate in voiceSampleRates) {
        final pcm = ByteData(rate ~/ 20 * 2);
        for (var offset = 0; offset < pcm.lengthInBytes; offset += 2) {
          pcm.setInt16(offset, 16384, Endian.little);
        }
        final bytes = pcm.buffer.asUint8List();
        final meter = PcmLevelMeter(sampleRate: rate);
        meter.add(Uint8List.sublistView(bytes, 0, 1));
        meter.add(Uint8List.sublistView(bytes, 1));
        expect(meter.levels, [512], reason: '$rate Hz');
        final wav = voiceWav(bytes, sampleRate: rate);
        final header = ByteData.sublistView(wav);
        expect(header.getUint32(24, Endian.little), rate);
        expect(
          header.getUint32(40, Endian.little) *
              1000 ~/
              header.getUint32(28, Endian.little),
          50,
        );
        expect(wav.sublist(44), bytes);
      }
      expect(
        () => voiceWav(Uint8List(2), sampleRate: 44100),
        throwsArgumentError,
      );
      expect(() => PcmLevelMeter(sampleRate: 0), throwsArgumentError);
    },
  );
  test(
    '48 kHz permits three minutes while overlong and malformed PCM stays rejected',
    () {
      final maximum = voiceWav(Uint8List(48000 * 2 * 180), sampleRate: 48000);
      expect(maximum.length, maxVoiceRecordingBytes);
      expect(maximum.length, greaterThan(10 * 1024 * 1024));
      for (final rate in voiceSampleRates) {
        expect(
          () => voiceWav(Uint8List(rate * 2 * 180 + 2), sampleRate: rate),
          throwsArgumentError,
        );
        expect(
          () => voiceWav(Uint8List(3), sampleRate: rate),
          throwsArgumentError,
        );
      }
    },
  );
}
