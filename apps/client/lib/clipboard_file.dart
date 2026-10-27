import 'dart:typed_data';

class ClipboardFile {
  final String name, mime;
  final int size;
  final Stream<Uint8List> Function() read;
  ClipboardFile({
    required this.name,
    required this.mime,
    required this.size,
    required this.read,
  });
}
