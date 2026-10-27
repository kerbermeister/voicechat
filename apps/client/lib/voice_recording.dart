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

/// Normalize only our bounded PCM16 WAV format, in memory during playback.
/// Unknown formats and near-silence keep their original bytes.
Uint8List normalizedVoice(Uint8List bytes) {
  if (bytes.length < 46 ||
      bytes.length > 44 + 16000 * 2 * 180 ||
      bytes.length.isOdd) {
    return bytes;
  }
  final data = ByteData.sublistView(bytes);
  bool label(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      if (bytes[offset + i] != value.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (!label(0, 'RIFF') ||
      !label(8, 'WAVE') ||
      !label(12, 'fmt ') ||
      !label(36, 'data') ||
      data.getUint32(4, Endian.little) != bytes.length - 8 ||
      data.getUint32(16, Endian.little) != 16 ||
      data.getUint16(20, Endian.little) != 1 ||
      data.getUint16(22, Endian.little) != 1 ||
      data.getUint32(24, Endian.little) != 16000 ||
      data.getUint32(28, Endian.little) != 32000 ||
      data.getUint16(32, Endian.little) != 2 ||
      data.getUint16(34, Endian.little) != 16 ||
      data.getUint32(40, Endian.little) != bytes.length - 44) {
    return bytes;
  }
  var peak = 0;
  for (var i = 44; i < bytes.length; i += 2) {
    peak = max(peak, data.getInt16(i, Endian.little).abs());
  }
  if (peak < 32 || peak >= 31456) return bytes;
  final gain = min(12.0, 31456 / peak);
  final result = Uint8List.fromList(bytes);
  final output = ByteData.sublistView(result);
  for (var i = 44; i < bytes.length; i += 2) {
    output.setInt16(
      i,
      (data.getInt16(i, Endian.little) * gain).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return result;
}
