import 'dart:async';
import 'package:matrix/matrix.dart';
import 'matrix_probe.dart';

const _eventType = 'dev.voicechat.recording';
final _trackers = Expando<RecordingActivity>();

class RecordingActivity {
  final Client client;
  final void Function() changed;
  final _remote =
      <String, Map<String, ({String user, String kind, int expires})>>{};
  final _own = <String, String>{};
  final _queued = <Room, String>{};
  StreamSubscription<ToDeviceEvent>? _events;
  Timer? _expiry, _heartbeat;
  bool _closed = false, _sending = false;
  RecordingActivity(this.client, this.changed);
  static RecordingActivity? of(Client client) => _trackers[client];
  void notify() => scheduleMicrotask(() {
    if (!_closed) changed();
  });
  String? own(Room room) => _own[room.id];
  Map<String, String> users(Room room) => {
    for (final entry in (_remote[room.id] ?? {}).entries)
      if (entry.value.kind != 'stop' &&
          entry.value.expires > DateTime.now().millisecondsSinceEpoch)
        entry.value.user: entry.value.kind,
    if (_own[room.id] != null) client.userID!: _own[room.id]!,
  };

  void start() {
    _trackers[client] = this;
    _events = client.onToDeviceEvent.stream.listen(receive);
    _expiry = Timer.periodic(const Duration(seconds: 1), (_) {
      var expired = false;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final entries in _remote.values) {
        entries.removeWhere((_, value) {
          if (value.expires > now) return false;
          expired = true;
          return true;
        });
      }
      if (expired && !_closed) notify();
    });
    _heartbeat = Timer.periodic(const Duration(seconds: 4), (_) {
      for (final roomId in _own.keys.toList()) {
        final room = client.getRoomById(roomId);
        if (room != null) unawaited(broadcast(room, _own[roomId]!));
      }
    });
  }

  void set(Room room, String? kind) {
    if (_closed || (kind != null && !['audio', 'video'].contains(kind))) return;
    if (_own[room.id] == kind) return;
    final first = !_own.containsKey(room.id);
    if (kind == null) {
      _own.remove(room.id);
    } else {
      _own[room.id] = kind;
    }
    notify();
    unawaited(() async {
      if (first && kind != null) {
        try {
          await authorizedDevices(room);
        } catch (_) {
          return;
        }
      }
      if (_closed || _own[room.id] != kind) return;
      await broadcast(room, kind ?? 'stop');
    }());
  }

  Future<void> broadcast(Room room, String kind) async {
    if (_closed || room.membership != Membership.join) return;
    _queued[room] = kind;
    if (_sending) return;
    _sending = true;
    try {
      while (!_closed && _queued.isNotEmpty) {
        final next = _queued.entries.first;
        _queued.remove(next.key);
        await _send(next.key, next.value);
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> _send(Room room, String kind) async {
    try {
      final users = room
          .getParticipants()
          .where((u) => u.membership == Membership.join)
          .map((u) => u.id);
      final devices = [
        for (final user in users)
          ...?client.userDeviceKeys[user]?.deviceKeys.values.where(
            (d) =>
                d.directVerified &&
                d.isValid &&
                !d.blocked &&
                d.encryptToDevice,
          ),
      ];
      if (devices.isNotEmpty) {
        await client.sendToDeviceEncrypted(devices, _eventType, {
          'room_id': room.id,
          'kind': kind,
          'expires_at': DateTime.now()
              .add(const Duration(seconds: 10))
              .millisecondsSinceEpoch,
        }, onlyVerified: true);
      }
    } catch (_) {
      // Recording must remain usable offline; remote activity expires by itself.
    }
  }

  void receive(ToDeviceEvent event) {
    if (_closed || event.type != _eventType || event.encryptedContent == null) {
      return;
    }
    final data = event.content;
    final roomId = data['room_id'],
        kind = data['kind'],
        expires = data['expires_at'];
    final now = DateTime.now().millisecondsSinceEpoch;
    if (roomId is! String ||
        !['audio', 'video', 'stop'].contains(kind) ||
        expires is! int ||
        expires <= now ||
        expires > now + 15000) {
      return;
    }
    final room = client.getRoomById(roomId);
    if (room?.membership != Membership.join ||
        room!
                .getState(EventTypes.RoomMember, event.sender)
                ?.content['membership'] !=
            'join') {
      return;
    }
    final senderKey = event.encryptedContent!['sender_key'];
    if (senderKey is! String) return;
    final device = client.getUserDeviceKeysByCurve25519Key(senderKey);
    if (device == null ||
        device.userId != event.sender ||
        !device.directVerified ||
        device.blocked ||
        !device.isValid) {
      return;
    }
    final users = _remote.putIfAbsent(roomId, () => {});
    final identity = '${event.sender}/${device.deviceId}';
    if ((users[identity]?.expires ?? 0) > expires) return;
    users[identity] = (
      user: event.sender,
      kind: kind as String,
      expires: expires,
    );
    notify();
  }

  Future<void> close() async {
    _closed = true;
    _expiry?.cancel();
    _heartbeat?.cancel();
    await _events?.cancel();
    _trackers[client] = null;
    _own.clear();
    _remote.clear();
    _queued.clear();
  }
}
