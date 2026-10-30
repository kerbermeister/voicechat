import 'dart:typed_data';

const fileChunkBytes = 4 * 1024 * 1024;

String attachmentMime(String name, String supplied) {
  if (supplied.isNotEmpty && supplied != 'application/octet-stream') {
    return supplied;
  }
  return switch (name.contains('.') ? name.split('.').last.toLowerCase() : '') {
    'heic' => 'image/heic',
    'heif' => 'image/heif',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'gif' => 'image/gif',
    'mp4' || 'm4v' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'm4a' => 'audio/mp4',
    'pdf' => 'application/pdf',
    _ => 'application/octet-stream',
  };
}

class PickedFile {
  final String name;
  final String mime;
  final int size;
  final Future<Uint8List> Function(int start, int end) read;
  final Future<void> Function() release;
  PickedFile({
    required this.name,
    required this.mime,
    required this.size,
    required this.read,
    required this.release,
  });

  Stream<Uint8List> range(int start, int end) async* {
    if (start < 0 || end < start || end > size) {
      throw RangeError('Invalid file range');
    }
    for (var offset = start; offset < end;) {
      final next = (offset + fileChunkBytes).clamp(offset, end);
      final bytes = await read(offset, next);
      if (bytes.length != next - offset) {
        throw StateError('Incomplete file read');
      }
      yield bytes;
      offset = next;
    }
  }
}
