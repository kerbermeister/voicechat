import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'local_store.dart';

/// Only disposable timeline copies are removed; keys, state and outbox stay intact.
class StoragePolicy extends ChangeNotifier {
  final Client client;
  final String? Function() activeRoom;
  int limitMiB = 1024;
  int? usedBytes;
  String? warning;
  bool busy = false;
  bool _closed = false;
  Timer? _timer;
  Future<void>? _running;
  static const _key = 'dev.voicechat.local.storagePolicy';
  StoragePolicy(this.client, this.activeRoom);

  Future<int> measure() => storeUsage(client.clientName);
  Future<void> compact() => compactStore(client.clientName);
  Future<void> open() async {
    final saved =
        (await client.database.getAccountData())[_key]?.content['limit_mib'];
    if (saved is int && saved >= 16 && saved <= 4096) limitMiB = saved;
    _timer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(check()),
    );
    unawaited(check());
  }

  Future<void> setLimit(int mib) async {
    if (mib < 16 || mib > 4096) throw RangeError('Invalid storage limit');
    await client.database.storeAccountData(_key, {'limit_mib': mib});
    limitMiB = mib;
    await _running;
    await check();
  }

  Future<void> check() =>
      _running ??= _check().whenComplete(() => _running = null);
  Future<void> _check() async {
    if (_closed) return;
    busy = true;
    warning = null;
    notifyListeners();
    try {
      // Temporary transfers may be much larger than the chat cache budget.
      final temporary =
          (await client.database
                  .getAccountData())['dev.voicechat.local.p2p.temporary']
              ?.content['ids'];
      if (temporary is List && temporary.isNotEmpty) {
        warning = 'Очистка кеша отложена, пока сохранены временные P2P-файлы.';
        return;
      }
      usedBytes = await measure();
      final target = (limitMiB * 1048576 * .9).floor();
      if (usedBytes! >= target) {
        final rooms = <({Room room, DateTime oldest})>[];
        for (final room in client.rooms) {
          if (_closed) return;
          if (room.membership != Membership.join || room.id == activeRoom()) {
            continue;
          }
          final ids = await client.database.getEventIdList(room);
          if (ids.length <= 30) continue;
          final oldest = await client.database.getEventById(ids.last, room);
          if (oldest != null) {
            rooms.add((room: room, oldest: oldest.originServerTs));
          }
        }
        rooms.sort((a, b) => a.oldest.compareTo(b.oldest));
        for (final candidate in rooms) {
          if (_closed || usedBytes! < target) break;
          final removed = await trimHistory(candidate.room);
          if (_closed) break;
          if (removed > 0) {
            await compact();
            usedBytes = await measure();
          }
        }
        if (usedBytes! >= target) {
          warning =
              'Остались ключи, неотправленные данные и открытая переписка. Они не удаляются автоматически. Увеличьте лимит или завершите отправку; для очистки истории нужна сеть.';
        }
      }
    } catch (_) {
      warning =
          'Не удалось проверить или очистить хранилище. Данные сохранены; повторите при подключении к сети.';
    } finally {
      busy = false;
      if (!_closed) notifyListeners();
    }
  }

  Future<int> trimHistory(Room room) async {
    final database = client.database;
    final ids = await database.getEventIdList(room);
    if (_closed || room.id == activeRoom() || ids.length <= 30) return 0;
    // Obtain the exact back-pagination token before discarding any local events.
    final context = await client
        .getEventContext(room.id, ids[29], limit: 0)
        .timeout(const Duration(seconds: 10));
    if (_closed ||
        room.id == activeRoom() ||
        context.event?.eventId != ids[29] ||
        context.start == null) {
      return 0;
    }
    var removed = 0;
    await database.transaction(() async {
      for (final id in ids.skip(30)) {
        final event = await database.getEventById(id, room);
        if (event == null || !event.status.isSynced) continue;
        await database.removeEvent(id, room.id);
        removed++;
      }
      await database.setRoomPrevBatch(context.start, room.id, client);
    });
    room.prev_batch = context.start;
    return removed;
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _running;
    dispose();
  }
}
