import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/p2p/archive.dart';

void main() {
  test(
    'Seekable ZIP64 keeps bytes, Unicode, empty files and duplicate names',
    () async {
      final contents = [
        Uint8List.fromList([1, 2, 255]),
        Uint8List(0),
        Uint8List.fromList([9]),
      ];
      final zip = await P2pArchive.create([
        for (var i = 0; i < contents.length; i++)
          (
            name: i == 2 ? '../фото.jpg' : 'фото.jpg',
            size: contents[i].length,
            read: (int from, int to) =>
                Stream.value(Uint8List.sublistView(contents[i], from, to)),
          ),
      ], () => false);
      final output = BytesBuilder(copy: false);
      // Deliberately cross headers, file data and central-directory boundaries.
      for (var from = 0; from < zip.size; from += 7) {
        await for (final bytes in zip.range(
          from,
          (from + 7).clamp(0, zip.size),
        )) {
          output.add(bytes);
        }
      }
      final bytes = output.takeBytes();
      final decoded = ZipDecoder().decodeBytes(bytes, verify: true);
      expect(decoded.length, 3);
      expect(decoded.files.map((f) => f.name).toSet().length, 3);
      for (var i = 0; i < contents.length; i++) {
        expect(decoded.files[i].content, contents[i]);
      }
      expect(decoded.files.last.name, '.._фото.jpg');
      final tail = BytesBuilder();
      await for (final block in zip.range(zip.size - 22, zip.size)) {
        tail.add(block);
      }
      expect(tail.takeBytes(), bytes.sublist(bytes.length - 22));
    },
  );
  test('ZIP rejects truncated sources and cancellation', () async {
    final files = [
      (name: 'x', size: 2, read: (int a, int b) => Stream.value(Uint8List(1))),
    ];
    await expectLater(
      P2pArchive.create(files, () => false),
      throwsFormatException,
    );
    await expectLater(P2pArchive.create(files, () => true), throwsStateError);
  });
}
