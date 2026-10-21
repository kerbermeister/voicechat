import 'dart:typed_data';

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
