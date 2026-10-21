import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/file_io_native.dart';
import 'package:voicechat_probe/picked_file.dart';

void main() {
  test(
    'Draft video ranges are bounded and closing preview keeps the draft',
    () async {
      var released = false;
      final reads = <(int, int)>[];
      final file = PickedFile(
        name: 'large.mp4',
        mime: 'video/mp4',
        size: 300 * 1024 * 1024,
        read: (start, end) async {
          reads.add((start, end));
          expect(end - start, lessThanOrEqualTo(fileChunkBytes));
          return Uint8List(end - start)..fillRange(0, end - start, 42);
        },
        release: () async => released = true,
      );
      final source = await draftVideoSource(file);
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(source.url));
        request.headers.set('Range', 'bytes=5000000-5000007');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(response.headers.value('Cache-Control'), 'no-store');
        expect(
          await response.expand((bytes) => bytes).toList(),
          List.filled(8, 42),
        );
        expect(reads, [(5000000, 5000008)]);
        final denied = await (await client.getUrl(
          Uri.parse('${source.url}wrong'),
        )).close();
        expect(denied.statusCode, 404);
        await denied.drain<void>();
        await expectLater(file.range(-1, 10).drain<void>(), throwsRangeError);
        final interrupted = await client.getUrl(Uri.parse(source.url));
        interrupted.headers.set('Range', 'bytes=0-12582911');
        await (await interrupted.close()).first;
        client.close(force: true);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final retry = HttpClient();
        try {
          final request = await retry.getUrl(Uri.parse(source.url));
          request.headers.set('Range', 'bytes=0-7');
          final response = await request.close();
          expect(
            await response.expand((bytes) => bytes).toList(),
            List.filled(8, 42),
          );
        } finally {
          retry.close(force: true);
        }
      } finally {
        client.close(force: true);
        await source.close();
      }
      expect(released, false);
      expect(await file.range(0, 3).first, [42, 42, 42]);
      final truncated = PickedFile(
        name: 'bad',
        mime: 'video/mp4',
        size: 10,
        read: (_, _) async => Uint8List(1),
        release: () async {},
      );
      await expectLater(truncated.range(0, 10).drain<void>(), throwsStateError);
    },
  );
}
