import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

const readAfterKey = 'dev.voicechat.read_after_seconds';
int? readAfterSeconds(Event event) {
  final value =
      event.originalSource?.content[readAfterKey] ??
      event.content[readAfterKey];
  return value is int && value >= 1 && value <= 86400 ? value : null;
}

/// Confirmed server deadlines and a monotonic local grace period survive wall-clock changes.
class ReadAfterState extends ChangeNotifier {
  ReadAfterState._(this.client);
  static final _accounts = Expando<ReadAfterState>();
  static ReadAfterState of(Client client) =>
      _accounts[client] ??= ReadAfterState._(client);
  final Client client;
  static const storageKey = 'dev.voicechat.local.read_after';
  final deadlines = <String, int>{};
  final _pending = <String, Map<String, dynamic>>{};
  final _grace = <String, (Stopwatch, int)>{};
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  final _busyRooms = <String>{};
  final failedRooms = <String>{};
  Stopwatch? _clock;
  int _serverAnchor = 0, _offset = 0;
  Future<void> load() =>
      _loading ??= _load().catchError((Object error, StackTrace stack) {
        _loading = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<void> _load() async {
    final content =
        (await client.database.getAccountData())[storageKey]?.content;
    final stored = content?['deadlines'];
    if (stored is Map) {
      for (final entry in stored.entries) {
        if (entry.key is String && entry.value is int) {
          deadlines[entry.key as String] = entry.value as int;
        }
      }
    }
    final pending = content?['pending'];
    if (pending is Map) {
      for (final entry in pending.entries) {
        final value = entry.value;
        if (entry.key is String &&
            value is Map &&
            value['room'] is String &&
            value['read_at'] is int &&
            value['delay'] is int) {
          _pending[entry.key as String] = Map<String, dynamic>.from(value);
        }
      }
    }
  }

  int? get serverNow =>
      _clock == null ? null : _serverAnchor + _clock!.elapsedMilliseconds;
  void observe(int now) {
    final previous = serverNow;
    _serverAnchor = previous != null && previous > now ? previous : now;
    _offset = _serverAnchor - DateTime.now().millisecondsSinceEpoch;
    _clock = Stopwatch()..start();
  }

  bool expired(String id) {
    final grace = _grace[id];
    if (grace != null && grace.$1.elapsedMilliseconds >= grace.$2 * 1000) {
      return true;
    }
    final end = deadlines[id];
    if (end != null) return serverNow == null || serverNow! >= end;
    // After restart, never reveal a previously-read offline copy while waiting for confirmation.
    return _pending.containsKey(id) && grace == null;
  }

  DateTime? expiry(String id) {
    final end = deadlines[id];
    if (end != null) {
      return _clock == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.fromMillisecondsSinceEpoch(end - _offset);
    }
    final grace = _grace[id];
    final pending = _pending[id];
    return grace == null || pending == null
        ? (pending == null ? null : DateTime.fromMillisecondsSinceEpoch(0))
        : DateTime.fromMillisecondsSinceEpoch(pending['local_until'] as int);
  }

  Future<void> _save() =>
      _writes = _writes.catchError((Object _) {}).then((_) async {
        await client.database.storeAccountData(storageKey, {
          'deadlines': Map.of(deadlines),
          'pending': Map.of(_pending),
        });
      });
  Future<Map<String, dynamic>> request(Map<String, dynamic> content) async {
    final endpoint = client.homeserver!.resolve(
      '/_synapse/client/voicechat-read-after',
    );
    if (endpoint.scheme != 'https' &&
        endpoint.host != 'localhost' &&
        endpoint.host != '127.0.0.1') {
      throw StateError('Secure homeserver required');
    }
    final response = await client.httpClient
        .post(
          endpoint,
          headers: {
            'Authorization': 'Bearer ${client.accessToken}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(content),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200 || response.bodyBytes.length > 65536) {
      throw StateError('Read-after service unavailable');
    }
    final result = jsonDecode(response.body) as Map<String, dynamic>;
    if (result['server_time_ms'] is! int) {
      throw const FormatException('Missing server time');
    }
    observe(result['server_time_ms'] as int);
    return result;
  }

  Future<void> syncRoom(
    Room room,
    List<Event> events, {
    required bool read,
  }) async {
    if (!_busyRooms.add(room.id)) return;
    try {
      await load();
      final candidates = events
          .where(
            (event) =>
                readAfterSeconds(event) != null &&
                !event.redacted &&
                (_clock == null ||
                    _pending.containsKey(event.eventId) ||
                    !expired(event.eventId)),
          )
          .toList();
      if (candidates.isEmpty &&
          !_pending.values.any((item) => item['room'] == room.id)) {
        return;
      }
      if (read) {
        var added = false;
        for (final event in candidates) {
          if (event.senderId == client.userID ||
              event.type != EventTypes.Message ||
              event.messageType == MessageTypes.BadEncrypted ||
              deadlines.containsKey(event.eventId) ||
              _pending.containsKey(event.eventId)) {
            continue;
          }
          final delay = readAfterSeconds(event)!;
          _grace[event.eventId] = (Stopwatch()..start(), delay);
          _pending[event.eventId] = {
            'room': room.id,
            'read_at': serverNow ?? DateTime.now().millisecondsSinceEpoch,
            'delay': delay,
            'local_until': DateTime.now().millisecondsSinceEpoch + delay * 1000,
          };
          added = true;
        }
        if (added) {
          await _save();
          notifyListeners();
        }
      }
      for (var offset = 0; offset < candidates.length; offset += 100) {
        final status = await request({
          'room_id': room.id,
          'event_ids': candidates
              .skip(offset)
              .take(100)
              .map((event) => event.eventId)
              .toList(),
        });
        final found = status['deadlines'];
        if (found is Map) {
          for (final entry in found.entries) {
            if (entry.key is String && entry.value is int) {
              deadlines[entry.key as String] = entry.value as int;
            }
          }
        }
        for (final id
            in (status['unavailable'] as List? ?? []).whereType<String>()) {
          deadlines[id] = serverNow!;
        }
      }
      for (final entry in _pending.entries.toList()) {
        if (entry.value['room'] != room.id) continue;
        if (!deadlines.containsKey(entry.key)) {
          final result = await request({
            'room_id': room.id,
            'event_id': entry.key,
            'read_at': entry.value['read_at'],
          });
          final end = result['expires_at'];
          if (end is! int) throw const FormatException('Missing read deadline');
          deadlines[entry.key] = end;
        }
        _pending.remove(entry.key);
      }
      await _save();
      failedRooms.remove(room.id);
      notifyListeners();
    } catch (_) {
      if (_pending.values.any((value) => value['room'] == room.id) &&
          failedRooms.add(room.id)) {
        notifyListeners();
      }
      rethrow;
    } finally {
      _busyRooms.remove(room.id);
    }
  }
}
