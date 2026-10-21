// SPDX-FileCopyrightText: 2019-Present Famedly GmbH
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart';

import '../../matrix_api_lite/utils/logs.dart';
import 'zone_transaction_mixin.dart';
import 'database_codec.dart';

/// Key-Value store abstraction over IndexedDB so that the sdk database can use
/// a single interface for all platforms. API is inspired by Hive.
class BoxCollection with ZoneTransactionMixin {
  final IDBDatabase _db;
  final Set<String> boxNames;
  final String name;

  final DatabaseCodec? codec;

  BoxCollection(this._db, this.boxNames, this.name, this.codec);

  static Future<BoxCollection> open(
    String name,
    Set<String> boxNames, {
    Object? sqfliteDatabase,
    DatabaseCodec? codec,
    Object? sqfliteFactory,
    IDBFactory? idbFactory,
    int version = 1,
  }) async {
    idbFactory ??= window.indexedDB;
    final dbOpenCompleter = Completer<BoxCollection>();
    final request = idbFactory.open(name, version);

    request.onerror = (Event event) {
      Logs().e('[IndexedDBBox] Error loading database - ${request.error}');
      dbOpenCompleter.completeError(
        'Error loading database - ${request.error}',
      );
    }.toJS;

    request.onupgradeneeded = (IDBVersionChangeEvent event) {
      final db = (event.target! as IDBOpenDBRequest).result as IDBDatabase;

      db.onerror = (Event event) {
        Logs().e('[IndexedDBBox] [onupgradeneeded] Error loading database');
        dbOpenCompleter.completeError(
          'Error loading database onupgradeneeded.',
        );
      }.toJS;

      for (final name in boxNames) {
        if (db.objectStoreNames.contains(name)) continue;
        db.createObjectStore(
          name,
          IDBObjectStoreParameters(autoIncrement: true),
        );
      }
    }.toJS;

    request.onsuccess = (Event event) {
      final db = request.result as IDBDatabase;
      dbOpenCompleter.complete(BoxCollection(db, boxNames, name, codec));
    }.toJS;
    return dbOpenCompleter.future;
  }

  Box<V> openBox<V>(String name) {
    if (!boxNames.contains(name)) {
      throw ('Box with name $name is not in the known box names of this collection.');
    }
    final box = Box<V>(name, this);
    _invalidateCaches.add(box.clearQuickAccessCache);
    return box;
  }

  final _invalidateCaches = <void Function()>[];
  List<Future<void> Function(IDBTransaction txn)>? _txnCache;

  Future<void> transaction(
    Future<void> Function() action, {
    List<String>? boxNames,
  }) => zoneTransaction(() async {
    if (_txnCache != null) return action();
    final cache = _txnCache = [];
    try {
      await action();
      _txnCache = null;
      if (cache.isEmpty) return;
      final done = Completer<void>();
      final txn = _db.transaction(
        boxNames?.jsify() ?? _db.objectStoreNames,
        'readwrite',
      );
      txn.oncomplete = (Event _) {
        if (!done.isCompleted) done.complete();
      }.toJS;
      txn.onabort = txn.onerror = (Event _) {
        if (!done.isCompleted)
          done.completeError(StateError('IndexedDB transaction aborted'));
      }.toJS;
      // Queue all requests synchronously; crypto has already completed.
      await Future.wait([done.future, ...cache.map((action) => action(txn))]);
    } catch (_) {
      for (final invalidate in _invalidateCaches) {
        invalidate();
      }
      rethrow;
    } finally {
      _txnCache = null;
    }
  });

  Future<void> clear() async {
    final transactionCompleter = Completer();
    final txn = _db.transaction(boxNames.toList().jsify()!, 'readwrite');
    for (final name in boxNames) {
      final objStoreClearCompleter = Completer();
      final request = txn.objectStore(name).clear();
      request.onerror = (Event event) {
        Logs().e(
          '[IndexedDBBox] [clear] Object store clear error - ${request.error}',
        );
        objStoreClearCompleter.completeError(
          'Object store clear not completed due to an error - ${request.error}'
              .toJS,
        );
      }.toJS;
      request.onsuccess = (Event event) {
        objStoreClearCompleter.complete();
      }.toJS;
      unawaited(objStoreClearCompleter.future);
    }
    txn.onerror = (Event event) {
      Logs().e('[IndexedDBBox] [clear] Error - ${txn.error}');
      transactionCompleter.completeError(
        'DB clear transaction not completed due to an error - ${txn.error}'
            .toJS,
      );
    }.toJS;
    txn.oncomplete = (Event event) {
      transactionCompleter.complete();
    }.toJS;
    return transactionCompleter.future;
  }

  Future<void> close() async {
    assert(_txnCache == null, 'Database closed while in transaction!');
    // Note, zoneTransaction and txnCache are different kinds of transactions.
    return zoneTransaction(() async => _db.close());
  }

  Future<void> deleteDatabase(String name, [dynamic factory]) async {
    await close();
    final deleteDatabaseCompleter = Completer();
    final request = ((factory ?? window.indexedDB) as IDBFactory)
        .deleteDatabase(name);
    request.onerror = (Event event) {
      Logs().e('[IndexedDBBox] [deleteDatabase] Error - ${request.error}');
      deleteDatabaseCompleter.completeError(
        'Error deleting database - ${request.error}'.toJS,
      );
    }.toJS;
    request.onsuccess = (Event event) {
      Logs().i('[IndexedDBBox] [deleteDatabase] Database deleted.');
      deleteDatabaseCompleter.complete();
    }.toJS;
    return deleteDatabaseCompleter.future;
  }
}

class Box<V> {
  final String name;
  final BoxCollection boxCollection;
  final Map<String, V?> _quickAccessCache = {};
  int _revision = 0;

  /// _quickAccessCachedKeys is only used to make sure that if you fetch all keys from a
  /// box, you do not need to have an expensive read operation twice. There is
  /// no other usage for this at the moment. So the cache is never partial.
  /// Once the keys are cached, they need to be updated when changed in put and
  /// delete* so that the cache does not become outdated.
  Set<String>? _quickAccessCachedKeys;

  Box(this.name, this.boxCollection);

  Future<List<String>> getAllKeys([IDBTransaction? txn]) async {
    if (_quickAccessCachedKeys != null) return _quickAccessCachedKeys!.toList();
    txn ??= boxCollection._db.transaction(name.toJS, 'readonly');
    final revision = _revision;
    final keys = await _getAllKeysFromStore(txn);
    if (revision == _revision) _quickAccessCachedKeys = keys.toSet();
    return keys;
  }

  /// Reads the keys from the object store, bypassing [_quickAccessCachedKeys].
  ///
  /// [put] and [delete] keep the cached key set complete, but in their own
  /// mutation order rather than in the store's key order, while
  /// [IDBObjectStore.getAll] always returns the values in key order. So only
  /// freshly read keys may be zipped against those values.
  Future<List<String>> _getAllKeysFromStore(IDBTransaction txn) async {
    final store = txn.objectStore(name);
    final getAllKeysCompleter = Completer();
    final request = store.getAllKeys();
    request.onerror = (Event event) {
      Logs().e('[IndexedDBBox] [getAllKeys] Error - ${request.error}');
      getAllKeysCompleter.completeError(
        '[IndexedDBBox] [getAllKeys] Error - ${request.error}'.toJS,
      );
    }.toJS;
    request.onsuccess = (Event event) {
      getAllKeysCompleter.complete();
    }.toJS;
    await getAllKeysCompleter.future;
    return (request.result?.dartify() as List?)?.cast<String>() ?? [];
  }

  Future<Map<String, V>> getAllValues([IDBTransaction? txn]) async {
    txn ??= boxCollection._db.transaction(name.toJS, 'readonly');
    final store = txn.objectStore(name);
    final map = <String, V>{};
    List values = [];

    /// NOTE: This is a workaround to get the keys as [IDBObjectStore.getAll()]
    /// only returns the values as a list.
    /// And using the [IDBObjectStore.openCursor()] method is not working as expected.
    final revision = _revision;
    final keys = await _getAllKeysFromStore(txn);
    if (revision == _revision) _quickAccessCachedKeys = keys.toSet();

    final getAllValuesCompleter = Completer();
    final getAllValuesRequest = store.getAll();
    getAllValuesRequest.onerror = (Event event) {
      Logs().e(
        '[IndexedDBBox] [getAllValues] Error - ${getAllValuesRequest.error}',
      );
      getAllValuesCompleter.completeError(
        '[IndexedDBBox] [getAllValues] Error - ${getAllValuesRequest.error}'
            .toJS,
      );
    }.toJS;
    getAllValuesRequest.onsuccess = (Event event) {
      values = getAllValuesRequest.result.dartify() as List;
      getAllValuesCompleter.complete();
    }.toJS;
    await getAllValuesCompleter.future;
    for (var i = 0; i < values.length; i++) {
      map[keys[i]] = _fromValue(await _decode(keys[i], values[i])) as V;
    }
    return map;
  }

  Future<V?> get(String key, [IDBTransaction? txn]) async {
    if (_quickAccessCache.containsKey(key)) return _quickAccessCache[key];
    final revision = _revision;
    txn ??= boxCollection._db.transaction(name.toJS, 'readonly');
    final store = txn.objectStore(name);
    final getObjectRequest = store.get(key.toJS);
    final getObjectCompleter = Completer();
    getObjectRequest.onerror = (Event event) {
      Logs().e('[IndexedDBBox] [get] Error - ${getObjectRequest.error}');
      getObjectCompleter.completeError(
        '[IndexedDBBox] [get] Error - ${getObjectRequest.error}'.toJS,
      );
    }.toJS;
    getObjectRequest.onsuccess = (Event event) {
      getObjectCompleter.complete();
    }.toJS;
    await getObjectCompleter.future;
    final value = _fromValue(
      await _decode(key, getObjectRequest.result?.dartify()),
    );
    // An asynchronous decode must not replace a newer cached write.
    if (revision == _revision) _quickAccessCache[key] = value;
    return value;
  }

  Future<List<V?>> getAll(List<String> keys, [IDBTransaction? txn]) async {
    if (keys.every(_quickAccessCache.containsKey)) {
      return keys.map((key) => _quickAccessCache[key]).toList();
    }
    final revision = _revision;
    txn ??= boxCollection._db.transaction(name.toJS, 'readonly');
    final store = txn.objectStore(name);
    final list = await Future.wait(
      keys.map((key) async {
        final getObjectRequest = store.get(key.toJS);
        final getObjectCompleter = Completer();
        getObjectRequest.onerror = (Event event) {
          Logs().e(
            '[IndexedDBBox] [getAll] Error at key $key - ${getObjectRequest.error}',
          );
          getObjectCompleter.completeError(
            '[IndexedDBBox] [getAll] Error at key $key - ${getObjectRequest.error}'
                .toJS,
          );
        }.toJS;
        getObjectRequest.onsuccess = (Event event) {
          getObjectCompleter.complete();
        }.toJS;
        await getObjectCompleter.future;
        return _fromValue(
          await _decode(key, getObjectRequest.result?.dartify()),
        );
      }),
    );
    if (revision == _revision) {
      for (var i = 0; i < keys.length; i++) {
        _quickAccessCache[keys[i]] = list[i];
      }
    }
    return list;
  }

  Future<Object?> _decode(String key, Object? value) async {
    if (value == null || boxCollection.codec == null) return value;
    return boxCollection.codec!.decode(name, key, value);
  }

  Future<void> put(String key, V val, [IDBTransaction? txn]) async {
    final encoded = boxCollection.codec == null
        ? val
        : await boxCollection.codec!.encode(name, key, val);
    if (boxCollection._txnCache != null) {
      boxCollection._txnCache!.add((txn) => _put(key, val, encoded, txn));
      _cacheValue(key, val);
    } else {
      await _put(key, val, encoded, txn);
    }
  }

  void _cacheValue(String key, V val) {
    _revision++;
    _quickAccessCache[key] = val;
    _quickAccessCachedKeys?.add(key);
  }

  Future<void> _put(
    String key,
    V val,
    Object? encoded,
    IDBTransaction? txn,
  ) async {
    final ownsTransaction = txn == null;
    txn ??= boxCollection._db.transaction(name.toJS, 'readwrite');
    final request = txn.objectStore(name).put(encoded.jsify(), key.toJS);
    final completer = Completer<void>();
    request.onerror = (Event _) {
      if (!completer.isCompleted)
        completer.completeError(StateError('IndexedDB write failed'));
    }.toJS;
    // A successful request is not a committed transaction.
    if (ownsTransaction) {
      txn.oncomplete = (Event _) {
        completer.complete();
      }.toJS;
      txn.onabort = (Event _) {
        if (!completer.isCompleted)
          completer.completeError(StateError('IndexedDB write aborted'));
      }.toJS;
    } else {
      request.onsuccess = (Event _) {
        completer.complete();
      }.toJS;
    }
    await completer.future;
    _cacheValue(key, val);
  }

  Future<void> delete(String key, [IDBTransaction? txn]) async {
    if (boxCollection._txnCache != null) {
      boxCollection._txnCache!.add((txn) => delete(key, txn));
      _revision++;
      _quickAccessCache[key] = null;
      _quickAccessCachedKeys?.remove(key);
      return;
    }

    txn ??= boxCollection._db.transaction(name.toJS, 'readwrite');
    final store = txn.objectStore(name);
    final deleteRequest = store.delete(key.toJS);
    final deleteCompleter = Completer();
    deleteRequest.onerror = (Event event) {
      Logs().e('[IndexedDBBox] [delete] Error - ${deleteRequest.error}');
      deleteCompleter.completeError(
        '[IndexedDBBox] [delete] Error - ${deleteRequest.error}'.toJS,
      );
    }.toJS;
    deleteRequest.onsuccess = (Event event) {
      deleteCompleter.complete();
    }.toJS;
    await deleteCompleter.future;

    // Set to null instead remove() so that inside of transactions null is
    // returned.
    _revision++;
    _quickAccessCache[key] = null;
    _quickAccessCachedKeys?.remove(key);
    return;
  }

  Future<void> deleteAll(List<String> keys, [IDBTransaction? txn]) async {
    if (boxCollection._txnCache != null) {
      boxCollection._txnCache!.add((txn) => deleteAll(keys, txn));
      for (final key in keys) {
        _revision++;
        _quickAccessCache[key] = null;
      }
      _quickAccessCachedKeys?.removeAll(keys);
      return;
    }

    txn ??= boxCollection._db.transaction(name.toJS, 'readwrite');
    final store = txn.objectStore(name);
    for (final key in keys) {
      final deleteRequest = store.delete(key.toJS);
      final deleteCompleter = Completer();
      deleteRequest.onerror = (Event event) {
        Logs().e(
          '[IndexedDBBox] [deleteAll] Error at key $key - ${deleteRequest.error}',
        );
        deleteCompleter.completeError(
          '[IndexedDBBox] [deleteAll] Error at key $key - ${deleteRequest.error}'
              .toJS,
        );
      }.toJS;
      deleteRequest.onsuccess = (Event event) {
        deleteCompleter.complete();
      }.toJS;
      await deleteCompleter.future;
      _revision++;
      _quickAccessCache[key] = null;
      _quickAccessCachedKeys?.remove(key);
    }
    return;
  }

  void clearQuickAccessCache() {
    _revision++;
    _quickAccessCache.clear();
    _quickAccessCachedKeys = null;
  }

  Future<void> clear([IDBTransaction? txn]) async {
    if (boxCollection._txnCache != null) {
      boxCollection._txnCache!.add(clear);
    } else {
      txn ??= boxCollection._db.transaction(name.toJS, 'readwrite');
      final store = txn.objectStore(name);
      final clearRequest = store.clear();
      final clearCompleter = Completer();
      clearRequest.onerror = (Event event) {
        Logs().e('[IndexedDBBox] [clear] Error - ${clearRequest.error}');
        clearCompleter.completeError(
          '[IndexedDBBox] [clear] Error - ${clearRequest.error}'.toJS,
        );
      }.toJS;
      clearRequest.onsuccess = (Event event) {
        clearCompleter.complete();
      }.toJS;
      await clearCompleter.future;
    }
    clearQuickAccessCache();
  }

  V? _fromValue(Object? value) {
    if (value == null) return null;
    switch (V) {
      case const (List<dynamic>):
        return List.unmodifiable(value as List) as V;
      case const (Map<dynamic, dynamic>):
        return Map.unmodifiable(value as Map) as V;
      case const (int):
        // Workaround that [JSAny.dartify] on wasm could turn an int into double
        if (value is double) return value.round() as V;
        return value as V;
      case const (double):
      case const (bool):
      case const (String):
      default:
        return value as V;
    }
  }
}
