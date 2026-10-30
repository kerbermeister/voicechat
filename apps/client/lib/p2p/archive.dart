import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive.dart' show getCrc32;

/// Stored ZIP64: source data stays in the encrypted P2P store, not a second
/// plaintext temporary file. Only headers and checksums are held in memory.
class P2pArchive {
  final _parts =
      <({int start, int size, Stream<Uint8List> Function(int, int) read})>[];
  int size = 0;

  void _bytes(Uint8List bytes) => _part(
    bytes.length,
    (from, to) => Stream.value(Uint8List.sublistView(bytes, from, to)),
  );
  void _part(int length, Stream<Uint8List> Function(int, int) read) {
    _parts.add((start: size, size: length, read: read));
    size += length;
  }

  static Future<P2pArchive> create(
    List<({String name, int size, Stream<Uint8List> Function(int, int) read})>
    files,
    bool Function() cancelled,
  ) async {
    final zip = P2pArchive();
    final directory = <Uint8List>[];
    final names = <String>{};
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      if (file.size < 0 || file.size > 100000000000) {
        throw const FormatException('Invalid ZIP size');
      }
      var name = file.name.replaceAll(RegExp(r'[/\\:\x00-\x1f\x7f]'), '_');
      if (name.isEmpty || name == '.' || name == '..') name = 'file';
      final base = name;
      for (var suffix = 2; !names.add(name.toLowerCase()); suffix++) {
        name = '$suffix-$base';
      }
      final encoded = utf8.encode(name);
      if (encoded.length > 65535) {
        throw const FormatException('ZIP name too long');
      }
      var crc = 0, count = 0;
      // A bounded local verification pass makes the resulting archive seekable:
      // Safari and the download worker can request any byte range.
      await for (final bytes in file.read(0, file.size)) {
        if (cancelled()) throw StateError('Cancelled ZIP preparation');
        count += bytes.length;
        if (count > file.size) {
          throw const FormatException('Oversized ZIP source');
        }
        crc = getCrc32(bytes, crc);
      }
      if (count != file.size || cancelled()) {
        throw const FormatException('Incomplete ZIP source');
      }
      final offset = zip.size;
      final local = _Header(30 + encoded.length + 20)
        ..u32(0x04034b50)
        ..u16(45)
        ..u16(0x800)
        ..u16(0)
        ..u16(0)
        ..u16(33)
        ..u32(crc)
        ..u32(0xffffffff)
        ..u32(0xffffffff)
        ..u16(encoded.length)
        ..u16(20)
        ..bytes(encoded)
        ..u16(1)
        ..u16(16)
        ..u64(file.size)
        ..u64(file.size);
      zip._bytes(local.data);
      zip._part(file.size, file.read);
      directory.add(
        (_Header(46 + encoded.length + 28)
              ..u32(0x02014b50)
              ..u16(45)
              ..u16(45)
              ..u16(0x800)
              ..u16(0)
              ..u16(0)
              ..u16(33)
              ..u32(crc)
              ..u32(0xffffffff)
              ..u32(0xffffffff)
              ..u16(encoded.length)
              ..u16(28)
              ..u16(0)
              ..u16(0)
              ..u16(0)
              ..u32(0)
              ..u32(0xffffffff)
              ..bytes(encoded)
              ..u16(1)
              ..u16(24)
              ..u64(file.size)
              ..u64(file.size)
              ..u64(offset))
            .data,
      );
    }
    final start = zip.size;
    for (final header in directory) {
      zip._bytes(header);
    }
    final directorySize = zip.size - start;
    final end = zip.size;
    zip._bytes(
      (_Header(56)
            ..u32(0x06064b50)
            ..u64(44)
            ..u16(45)
            ..u16(45)
            ..u32(0)
            ..u32(0)
            ..u64(files.length)
            ..u64(files.length)
            ..u64(directorySize)
            ..u64(start))
          .data,
    );
    zip._bytes(
      (_Header(20)
            ..u32(0x07064b50)
            ..u32(0)
            ..u64(end)
            ..u32(1))
          .data,
    );
    zip._bytes(
      (_Header(22)
            ..u32(0x06054b50)
            ..u16(0)
            ..u16(0)
            ..u16(0xffff)
            ..u16(0xffff)
            ..u32(0xffffffff)
            ..u32(0xffffffff)
            ..u16(0))
          .data,
    );
    return zip;
  }

  Stream<Uint8List> range(int from, int to) async* {
    if (from < 0 || to < from || to > size) throw RangeError('ZIP range');
    for (final part in _parts) {
      final start = max(from, part.start),
          end = min(to, part.start + part.size);
      if (start < end) yield* part.read(start - part.start, end - part.start);
    }
  }
}

class _Header {
  final Uint8List data;
  late final ByteData view = ByteData.sublistView(data);
  int offset = 0;
  _Header(int size) : data = Uint8List(size);
  void u16(int value) {
    view.setUint16(offset, value, Endian.little);
    offset += 2;
  }

  void u32(int value) {
    view.setUint32(offset, value, Endian.little);
    offset += 4;
  }

  void u64(int value) {
    // Works in dart2js too, without BigInt or 32-bit bitwise truncation.
    u32(value % 4294967296);
    u32(value ~/ 4294967296);
  }

  void bytes(List<int> value) {
    data.setRange(offset, offset + value.length, value);
    offset += value.length;
  }
}
