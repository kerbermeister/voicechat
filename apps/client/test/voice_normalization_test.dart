import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/voice_recording.dart';

void main() {
  Uint8List wav(List<int> samples) {
    final pcm = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      pcm.setInt16(i * 2, samples[i], Endian.little);
    }
    return voiceWav(pcm.buffer.asUint8List());
  }

  test(
    'Quiet PCM is amplified with a bounded gain without changing stored bytes',
    () {
      final source = wav([1000, -2000, 0]);
      final original = Uint8List.fromList(source);
      final result = normalizedVoice(source);
      final data = ByteData.sublistView(result);
      expect(data.getInt16(44, Endian.little), 4000);
      expect(data.getInt16(46, Endian.little), -8000);
      expect(source, original);
      expect(result.sublist(0, 44), source.sublist(0, 44));
      final limited = ByteData.sublistView(
        normalizedVoice(wav([-10000, 5000])),
      );
      expect(limited.getInt16(44, Endian.little), -27524);
    },
  );
  test(
    'Silence, loud audio, unknown formats and malformed headers pass through',
    () {
      for (final bytes in [
        wav([0, 0]),
        wav([1, -31]),
        wav([-32768, 32767]),
        Uint8List(2),
      ]) {
        expect(identical(normalizedVoice(bytes), bytes), true);
      }
      for (final offset in [0, 4, 8, 12, 16, 20, 22, 24, 28, 32, 34, 36, 40]) {
        final bytes = wav([1000, -1000]);
        bytes[offset] ^= 1;
        expect(
          identical(normalizedVoice(bytes), bytes),
          true,
          reason: 'header $offset',
        );
      }
      final truncated = Uint8List.sublistView(wav([1000, -1000]), 0, 46);
      expect(identical(normalizedVoice(truncated), truncated), true);
    },
  );
}
