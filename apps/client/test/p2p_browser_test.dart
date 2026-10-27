@TestOn('browser')
library;

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:voicechat_probe/picked_file.dart';
import 'package:voicechat_probe/p2p/protocol.dart';
import 'package:voicechat_probe/p2p/wire.dart';

void main() {
  testWidgets(
    'real WebRTC delivers verified bytes, empty files, route and useful ACKs',
    (tester) async {
      await tester.runAsync(() async {
        // Multi-block and 5 GB checks run in the release transport harness.
        final size = 65537;
        final bytes = Uint8List.fromList(
          List.generate(size, (i) => (i * 31 + 17) % 251),
        );
        final files = [
          P2pFile(
            'large.bin',
            'application/octet-stream',
            size,
            sha256.convert(bytes).toString(),
          ),
          P2pFile(
            'empty.bin',
            'application/octet-stream',
            0,
            sha256.convert([]).toString(),
          ),
        ];
        final source = [
          PickedFile(
            name: 'large.bin',
            mime: 'application/octet-stream',
            size: size,
            read: (a, b) async => Uint8List.sublistView(bytes, a, b),
            release: () async {},
          ),
          PickedFile(
            name: 'empty.bin',
            mime: 'application/octet-stream',
            size: 0,
            read: (a, b) async => Uint8List(0),
            release: () async {},
          ),
        ];
        final stored = <int, Uint8List>{};
        final sent = Completer<void>(), received = Completer<void>();
        final errors = <String>[];
        final acked = <int>[];
        final routes = <P2pRoute>[];
        late P2pWire sender, receiver;
        receiver = P2pWire(
          files: files,
          signal: (v) => sender.receiveSignal(v),
          store: (file, block, data) async {
            if (file != 0) throw StateError('Unexpected stored file');
            stored[block] = data;
          },
          progress: (file, count, verified) {},
          route: routes.add,
          complete: () => received.complete(),
          failed: (reason) {
            errors.add(reason);
            if (!sent.isCompleted) sent.completeError(StateError(reason));
          },
        );
        sender = P2pWire(
          files: files,
          sources: source,
          signal: (v) => receiver.receiveSignal(v),
          store: (_, __, ___) async {
            throw StateError('Sender must not receive a file');
          },
          progress: (file, count, verified) {
            if (file == 0) acked.add(count);
          },
          route: routes.add,
          complete: () => sent.complete(),
          failed: (reason) {
            errors.add(reason);
            if (!sent.isCompleted) sent.completeError(StateError(reason));
          },
        );
        try {
          await receiver.open([]);
          await sender.open([]);
          await Future.wait([
            sent.future,
            received.future,
          ], eagerError: true).timeout(const Duration(seconds: 60));
          expect(errors, isEmpty);
          expect(acked.last, size);
          expect(acked, orderedEquals(acked.toList()..sort()));
          expect(acked.first, lessThan(size));
          expect(stored.length, 1);
          final hash = P2pHash();
          for (final data in stored.values) {
            hash.input.add(data);
          }
          expect(hash.finish(), files.first.hash);
          expect(routes, contains(P2pRoute.direct));
        } finally {
          await sender.drain();
          await receiver.drain();
        }
      });
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
