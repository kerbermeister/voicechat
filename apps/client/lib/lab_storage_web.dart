// Test-only entrypoint helper. All records are disposable test strings.
import 'dart:async';
import 'package:matrix/matrix.dart';
// Regression check for the pinned SDK storage patch.
// ignore: implementation_imports
import 'package:matrix/src/database/indexeddb_box.dart';

class DelayedCodec implements DatabaseCodec {
  Completer<void>? started;
  Completer<void>? release;
  @override
  Future<Object?> encode(String store, String key, Object? value) async =>
      value;
  @override
  Future<Object?> decode(String store, String key, Object? value) async {
    if (release != null) {
      if (!started!.isCompleted) started!.complete();
      await release!.future;
    }
    return value;
  }
}

Future<void> checkStorageCache(String run) async {
  final name = 'disposable-cache-test-$run';
  final codec = DelayedCodec();
  final collection = await BoxCollection.open(name, {'test'}, codec: codec);
  final box = collection.openBox<String>('test');
  try {
    for (final bulk in [false, true]) {
      await box.put('record', 'old-test-value');
      box.clearQuickAccessCache();
      codec.started = Completer<void>();
      codec.release = Completer<void>();
      final pending = bulk ? box.getAll(['record']) : box.get('record');
      await codec.started!.future;
      await box.put('record', 'new-test-value');
      codec.release!.complete();
      await pending;
      codec.release = null;
      if (await box.get('record') != 'new-test-value') {
        throw StateError('Slow decrypt overwrote a newer cache value');
      }
    }
    for (final clear in [false, true]) {
      await collection.transaction(() async {
        if (clear) {
          await box.clear();
        } else {
          await box.delete('record');
        }
        await box.put('record', 'after-transaction');
      });
      if (await box.get('record') != 'after-transaction') {
        throw StateError('Queued deletion hid a later committed write');
      }
    }
    try {
      await collection.transaction(() async {
        await box.put('record', 'must-rollback');
        throw StateError('deliberate rollback');
      });
    } catch (_) {}
    if (await box.get('record') != 'after-transaction') {
      throw StateError('Aborted transaction changed the cache');
    }
  } finally {
    await collection.deleteDatabase(name);
  }
}
