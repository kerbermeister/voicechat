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
}
