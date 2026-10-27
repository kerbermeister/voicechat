// Isolated real-transport checks. Not the production entry point.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:http/http.dart' as http;
import 'p2p/protocol.dart';
import 'lab_p2p_cross.dart';
import 'p2p/wire.dart';
import 'p2p/panel.dart';
import 'p2p/flow.dart';
import 'picked_file.dart';
import 'local_store.dart';
import 'p2p/temp_store.dart';
import 'package:matrix/matrix.dart' as mx;

SemanticsHandle? semantics;
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  semantics = SemanticsBinding.instance.ensureSemantics();
  runApp(
    MaterialApp(
      theme: ThemeData(colorSchemeSeed: const Color(0xff7854cd)),
      home: const Probe(),
    ),
  );
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _Probe();
}

class _Probe extends State<Probe> {
  String state = 'ready';
  bool running = false;
  final counts = List.filled(4, 0);
  final routes = List.filled(4, P2pRoute.unknown);
  final speeds = List.generate(4, (_) => P2pSpeed());
  final wires = <P2pWire>[];
  int size = 0;
  final stores =
      <
        ({String name, String id, P2pTempStore store, mx.MatrixSdkDatabase db})
      >[];
  void status(String value) {
    if (mounted) setState(() => state = value);
  }

  Future<void> run() async {
    setState(() => running = true);
    try {
      final query = Uri.base.queryParameters;
      if (query.containsKey('cross')) {
        await runP2pCross(Uri.base, int.parse(query['cross']!), 'web');
        status('PASS');
        return;
      }
      size = int.tryParse(query['bytes'] ?? '') ?? p2pBlockBytes * 2 + 999;
      final count = int.tryParse(query['peers'] ?? '') ?? 4;
      final cancel = query['cancel'] == '1',
          corrupt = query['corrupt'] == '1',
          relay = query['relay'] == '1';
      check(
        size >= 0 && size <= 5000000000 && count >= 1 && count <= 4,
        'test parameters',
      );
      List<Map<String, dynamic>> ice = [];
      if (relay) {
        final response = await http.get(
          Uri.base.resolve('/p2p-test-config.json'),
        );
        ice = (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
      }
      Uint8List data(int from, int to) {
        check(to - from <= p2pBlockBytes, 'unbounded read');
        return Uint8List(to - from)..fillRange(0, to - from, 42);
      }

      status('hashing');
      final hash = P2pHash();
      for (var at = 0; at < size; at += p2pBlockBytes) {
        hash.input.add(data(at, (at + p2pBlockBytes).clamp(0, size)));
        if (at % (32 * p2pBlockBytes) == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      final files = [
        P2pFile('probe.bin', 'application/octet-stream', size, hash.finish()),
        P2pFile('empty.bin', 'application/octet-stream', 0, P2pHash().finish()),
      ];
      if (size == 5000000000) {
        check(
          files.first.hash ==
              '7baffa7fb181e464ebc2fa2e8862b020779b77fdfe9b2083744a315ef9d255a7',
          'independent Python SHA-256 reference',
        );
      }
      final finished = <Future<void>>[];
      for (var i = 0; i < count; i++) {
        final done = Completer<void>();
        finished.add(done.future);
        unawaited(done.future.catchError((Object _) {}));
        P2pTempStore? temporary;
        final transferId = p2pId();
        if (query['storage'] == '1') {
          final name = 'p2p-lab-${p2pId()}';
          final db = await openStore(
            name,
            passphrase: 'disposable test profile',
          );
          temporary = P2pTempStore(mx.Client(name, database: db));
          await temporary.open();
          await temporary.register(transferId);
          stores.add((name: name, id: transferId, store: temporary, db: db));
        }
        late P2pWire sender, receiver;
        var stored = 0, maxBlock = 0, verifiedEmpty = false;
        void fail(String reason) {
          if (done.isCompleted) return;
          if (i == 0 && (cancel || corrupt)) {
            done.complete();
          } else {
            done.completeError(StateError('peer $i: $reason'));
          }
        }

        receiver = P2pWire(
          files: files,
          signal: (v) => sender.receiveSignal(v),
          store: (file, block, bytes) async {
            check(
              file == 0 && block * p2pBlockBytes == stored,
              'store sequence',
            );
            await temporary?.put(transferId, file, block, bytes);
            stored += bytes.length;
            maxBlock = bytes.length > maxBlock ? bytes.length : maxBlock;
            if (cancel && i == 0) {
              await receiver.close();
              if (!done.isCompleted) done.complete();
            }
            if (i == count - 1) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          },
          progress: (file, bytes, verified) {
            if (file == 1) verifiedEmpty = verified;
          },
          route: (_) {},
          complete: () {},
          failed: fail,
        );
        sender = P2pWire(
          files: files,
          sources: [
            PickedFile(
              name: 'probe.bin',
              mime: 'application/octet-stream',
              size: size,
              read: (from, to) async {
                final bytes = data(from, to);
                if (corrupt && i == 0 && from == 0 && bytes.isNotEmpty) {
                  bytes[0] = 7;
                }
                return bytes;
              },
              release: () async {},
            ),
            PickedFile(
              name: 'empty.bin',
              mime: 'application/octet-stream',
              size: 0,
              read: (_, __) async => Uint8List(0),
              release: () async {},
            ),
          ],
          signal: (v) => receiver.receiveSignal(v),
          store: (_, __, ___) async => throw StateError('sender store'),
          progress: (file, bytes, verified) {
            if (file == 0) {
              check(bytes >= counts[i], 'backwards ACK');
              counts[i] = bytes;
              speeds[i].record(bytes, DateTime.now().millisecondsSinceEpoch);
              status('transferring');
            }
          },
          route: (route) {
            routes[i] = route;
            status(state);
          },
          complete: () {
            if (done.isCompleted) return;
            try {
              check(
                !(i == 0 && (cancel || corrupt)),
                'invalid transfer completed',
              );
              check(
                stored == size && counts[i] == size && verifiedEmpty,
                'missing data or empty ACK',
              );
              check(maxBlock <= p2pBlockBytes, 'unbounded storage');
              check(
                routes[i] == (relay ? P2pRoute.relay : P2pRoute.direct),
                'wrong route',
              );
              done.complete();
            } catch (e, stack) {
              done.completeError(e, stack);
            }
          },
          failed: fail,
        );
        wires.addAll([sender, receiver]);
        await receiver.open(ice, relayOnly: relay);
        await sender.open(ice, relayOnly: relay);
      }
      await Future.wait(
        finished,
        eagerError: true,
      ).timeout(const Duration(minutes: 20));
      if (!cancel && !corrupt) {
        status('verifying storage');
        for (final entry in stores) {
          final storedHash = P2pHash();
          await for (final bytes in entry.store.range(
            entry.id,
            0,
            size,
            0,
            size,
          )) {
            storedHash.input.add(bytes);
          }
          check(
            storedHash.finish() == files.first.hash,
            'stored file checksum',
          );
        }
      }
      status('PASS');
    } catch (e) {
      status('FAIL: $e');
    } finally {
      for (final wire in wires) {
        await wire.drain();
      }
      for (final entry in stores) {
        await entry.store.close();
        await entry.db.close();
        await closeStore(entry.name);
        await eraseStore(entry.name);
      }
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('P2P transport lab')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(state),
        ElevatedButton(
          onPressed: running ? null : run,
          child: const Text('Run'),
        ),
        for (var i = 0; i < 4; i++)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text('Получатель ${i + 1}'),
                  P2pFlow(
                    outgoing: true,
                    moving: running && counts[i] > 0 && counts[i] < size,
                    complete: counts[i] == size && size > 0,
                  ),
                  P2pRouteWarning(route: routes[i], outgoing: true),
                  Text(
                    'Скорость: ${p2pSize(speeds[i].perSecond(DateTime.now().millisecondsSinceEpoch))}/с',
                  ),
                  P2pFileProgress(
                    file: P2pFile(
                      'probe.bin',
                      'application/octet-stream',
                      size,
                      '',
                    ),
                    bytes: counts[i],
                    verified: counts[i] == size && size > 0,
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
