// Real loopback HTTP only. Do not initialize TestWidgetsFlutterBinding here.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/file_io_native.dart';
import 'package:voicechat_probe/picked_file.dart';

import 'novel_boundaries_probe.dart' show collect;

void main() {
  test('UA-63.C06 actual loopback media server isolates concurrent seek, HEAD and invalid secret', () async {
    final payload = Uint8List.fromList(List.generate(257, (i) => i % 251));
    final source = PickedFile(
      name: 'qa.mp4',
      mime: 'video/mp4',
      size: payload.length,
      read: (from, to) async => Uint8List.sublistView(payload, from, to),
      release: () async {},
    );
    final resource = await draftVideoSource(source);
    final client = HttpClient();
    try {
      Future<void> range(int start, int end) async {
        final request = await client.getUrl(Uri.parse(resource.url));
        request.headers.set('Range', 'bytes=$start-$end');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(
          await collect(response.map(Uint8List.fromList)),
          payload.sublist(start, end + 1),
        );
      }

      await Future.wait([range(0, 0), range(100, 128), range(200, 256)]);
      final head = await client.openUrl('HEAD', Uri.parse(resource.url));
      final result = await head.close();
      expect(result.statusCode, 200);
      expect(result.contentLength, payload.length);
      expect(await collect(result.map(Uint8List.fromList)), isEmpty);
      final invalid = await client.getUrl(
        Uri.parse(resource.url).replace(path: '/wrong'),
      );
      final denied = await invalid.close();
      expect(denied.statusCode, 404);
      await denied.drain<void>();
    } finally {
      client.close(force: true);
      await resource.close();
    }
  });
}
