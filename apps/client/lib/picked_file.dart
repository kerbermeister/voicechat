import 'dart:typed_data';

const fileChunkBytes = 4 * 1024 * 1024;

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
