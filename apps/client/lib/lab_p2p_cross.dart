// Disposable local interop fixture. Never imported by the production entry point.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'p2p/protocol.dart';
import 'p2p/wire.dart';
import 'picked_file.dart';

Future<void> runP2pCross(Uri base, int scenario, String side) async {
  final httpClient = http.Client();
  Future<Map<String, dynamic>> get(String path) async =>
      jsonDecode(
            (await httpClient
                    .get(base.resolve(path))
                    .timeout(const Duration(seconds: 5)))
                .body,
          )
          as Map<String, dynamic>;
  Future<void> post(String path, Object data) async {
    final response = await httpClient
        .post(
          base.resolve(path),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(data),
        )
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw StateError('Interop signaling failed');
    }
  }

  final data = await get('/cross/$scenario/config');
  final files = parseP2pFiles(data['files']);
  final sender = (scenario == 0) == (side == 'native');
  final done = Completer<void>();
  unawaited(done.future.catchError((Object _) {}));
  final stored = List.filled(files.length, 0);
  P2pRoute route = P2pRoute.unknown;
  final wire = P2pWire(
    files: files,
    sources: sender
        ? [
            for (final f in files)
              PickedFile(
                name: f.name,
                mime: f.mime,
                size: f.size,
                read: (a, b) async {
                  if (b - a > p2pBlockBytes) {
                    throw StateError('Unbounded source');
                  }
                  return Uint8List(b - a)..fillRange(0, b - a, 42);
                },
                release: () async {},
              ),
          ]
        : null,
    signal: (value) => post('/cross/$scenario/$side', value),
    store: (file, block, bytes) async {
      if (sender ||
          block * p2pBlockBytes != stored[file] ||
          bytes.any((b) => b != 42)) {
        throw StateError('Interop bytes mismatch');
      }
      stored[file] += bytes.length;
    },
    progress: (_, __, ___) {},
    route: (value) => route = value,
    complete: () {
      if (!done.isCompleted) done.complete();
    },
    failed: (reason) {
      if (!done.isCompleted) done.completeError(StateError(reason));
    },
  );
  var stopped = false;
  Future<void>? polling;
  try {
    await wire.open(
      (data['ice'] as List).cast<Map<String, dynamic>>(),
      relayOnly: true,
    );
    polling = () async {
      while (!stopped) {
        final messages = await get('/cross/$scenario/$side');
        for (final message in messages['messages'] as List) {
          await wire.receiveSignal(Map<String, dynamic>.from(message as Map));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }();
    unawaited(
      polling.catchError((Object error) {
        if (!done.isCompleted) done.completeError(error);
      }),
    );
    await done.future.timeout(const Duration(seconds: 120));
    if (!sender &&
        List.generate(
          files.length,
          (i) => stored[i] == files[i].size,
        ).contains(false)) {
      throw StateError('Incomplete interop file');
    }
    if (sender && route != P2pRoute.relay) {
      throw StateError('Relay route not detected');
    }
    await post('/cross/$scenario/$side/done', {
      'passed': true,
      'files': files.length,
      'bytes': files.fold<int>(0, (n, f) => n + f.size),
      'route': route.name,
    });
  } finally {
    stopped = true;
    await wire.drain();
    await polling?.catchError((Object _) {});
    httpClient.close();
  }
}
