import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/local_store.dart';
import 'package:voicechat_probe/p2p/protocol.dart';
import 'package:voicechat_probe/p2p/temp_store.dart';
import 'package:voicechat_probe/p2p/wire.dart';
import 'package:voicechat_probe/picked_file.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native DataChannel, verified encrypted blocks, ranges and abandoned-session cleanup',
    (tester) async {
      final ice =
          (jsonDecode(
                    const String.fromEnvironment(
                      'P2P_TEST_ICE',
                      defaultValue: '[]',
                    ),
                  )
                  as List)
              .cast<Map<String, dynamic>>();
      final name = 'p2p_native_${p2pId()}', id = p2pId();
      final db = await openStore(
        name,
        passphrase: 'disposable integration test',
      );
      final client = Client(name, database: db);
      final temp = P2pTempStore(client);
      await temp.open();
      await temp.register(id);
      final bytes = Uint8List.fromList(
        List.generate(p2pBlockBytes + 17, (i) => i % 251),
      );
      final file = P2pFile(
        'native.bin',
        'application/octet-stream',
        bytes.length,
        sha256.convert(bytes).toString(),
      );
      final done = Completer<void>();
      final routes = <P2pRoute>[];
      late P2pWire sender, receiver;
      void fail(String reason) {
        if (!done.isCompleted) done.completeError(StateError(reason));
      }

      receiver = P2pWire(
        files: [file],
        signal: (v) => sender.receiveSignal(v),
        store: (file, block, data) => temp.put(id, file, block, data),
        progress: (_, __, ___) {},
        route: routes.add,
        complete: () {},
        failed: fail,
      );
      sender = P2pWire(
        files: [file],
        sources: [
          PickedFile(
            name: file.name,
            mime: file.mime,
            size: file.size,
            read: (a, b) async => Uint8List.sublistView(bytes, a, b),
            release: () async {},
          ),
        ],
        signal: (v) => receiver.receiveSignal(v),
        store: (_, __, ___) async {
          throw StateError('Unexpected sender storage');
        },
        progress: (_, __, ___) {},
        route: routes.add,
        complete: () => done.complete(),
        failed: fail,
      );
      try {
        await receiver.open(ice, relayOnly: ice.isNotEmpty);
        await sender.open(ice, relayOnly: ice.isNotEmpty);
        await done.future.timeout(const Duration(seconds: 120));
        expect(
          routes,
          contains(ice.isEmpty ? P2pRoute.direct : P2pRoute.relay),
        );
        final stored = P2pHash();
        await for (final part in temp.range(id, 0, file.size, 0, file.size)) {
          stored.input.add(part);
        }
        expect(stored.finish(), file.hash);
        final range = BytesBuilder();
        await for (final part in temp.range(
          id,
          0,
          file.size,
          p2pBlockBytes - 8,
          file.size,
        )) {
          range.add(part);
        }
        expect(range.takeBytes(), bytes.sublist(p2pBlockBytes - 8));
        await sender.drain();
        await receiver.drain();
        final next = P2pTempStore(client);
        await next.open();
        expect(await readBlob(name, 'p2p/$id/0/0'), isNull);
        expect(
          (await db.getAccountData())['dev.voicechat.local.p2p.temporary']!
              .content['ids'],
          isEmpty,
        );
        await next.close();
      } finally {
        await sender.drain();
        await receiver.drain();
        await temp.close();
        await db.close();
        await closeStore(name);
        await eraseStore(name);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
