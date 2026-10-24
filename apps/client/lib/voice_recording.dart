import 'dart:typed_data';
import 'dart:math';

/// Consecutive 50 ms RMS windows of PCM16 mono at 16 kHz, independent of chunks.
class PcmLevelMeter {
  static const interval = Duration(milliseconds: 50);
  static const historySize = 56;
  final levels = <int>[];
  double _squares = 0;
  int _samples = 0;
  int? _lowByte;

  void add(Uint8List chunk) {
    for (final byte in chunk) {
      if (_lowByte == null) {
        _lowByte = byte;
        continue;
      }
      final word = _lowByte! | (byte << 8);
      _lowByte = null;
      final sample = (word >= 32768 ? word - 65536 : word) / 32768;
      _squares += sample * sample;
      if (++_samples == 800) {
        levels.add((sqrt(_squares / _samples) * 1024).round().clamp(0, 1024));
        if (levels.length > historySize) levels.removeAt(0);
        _samples = 0;
        _squares = 0;
      }
    }
  }
}

/// PCM16 mono, 16 kHz; the recorder streams into memory, never a plaintext file.
Uint8List voiceWav(Uint8List pcm) {
  if (pcm.isEmpty || pcm.length.isOdd || pcm.length > 16000 * 2 * 180) {
    throw ArgumentError('Voice recording must contain 1 sample to 3 minutes');
  }
  final bytes = Uint8List(44 + pcm.length);
  final header = ByteData.sublistView(bytes);
  void label(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  label(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  label(8, 'WAVE');
  label(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  label(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  bytes.setRange(44, bytes.length, pcm);
  return bytes;
}

/// Quantized RMS of real PCM16 samples; zeros represent silence, not decorative noise.
List<int> pcmWaveform(Uint8List pcm, {int bins = 64}) {
  if (pcm.length.isOdd || bins < 1 || bins > 128) {
    throw ArgumentError('Invalid PCM waveform');
  }
  final samples = pcm.length ~/ 2;
  if (samples == 0) return List.filled(bins, 0);
  final data = ByteData.sublistView(pcm);
  return List.generate(bins, (bin) {
    final start = bin * samples ~/ bins;
    final end = ((bin + 1) * samples ~/ bins).clamp(start + 1, samples);
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      final sample = data.getInt16(i * 2, Endian.little) / 32768;
      sum += sample * sample;
    }
    return (sqrt(sum / (end - start)) * 1024).round().clamp(0, 1024);
  });
}
