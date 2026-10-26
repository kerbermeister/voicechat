import 'dart:async';
import 'package:matrix/matrix.dart';
import 'matrix_probe.dart';
import 'voice_call.dart';

/// Encrypted, expiring presence for this account only. Never captures media.
class CallDevices {
  final Client client;
  final void Function() changed;
  final remote = <String, ({Room room, String device, DateTime expires})>{};
  final handled = <String, DateTime>{};
  late final StreamSubscription<ToDeviceEvent> _events;
  VoiceCall? _local;
  VoiceCall? _accepted;
  bool _closed = false;
  Future<void>? _writes;
  DateTime? _lastSent;
  CallDevices(this.client, this.changed) {
    _events = client.onToDeviceEvent.stream.listen(receive);
  }

  String key(String room, String session) => '$room/$session';
  bool answered(String room, String session) =>
      handled.containsKey(key(room, session));

  void receive(ToDeviceEvent event) {
    if (_closed ||
        event.type != 'dev.voicechat.call_device' ||
        event.sender != client.userID ||
        event.encryptedContent == null) {
      return;
    }
    final data = event.content;
    final curve = event.encryptedContent!['sender_key'];
    if (curve is! String) return;
    final device = client.getUserDeviceKeysByCurve25519Key(curve);
    if (device == null ||
        device.blocked ||
        !device.encryptToDevice ||
        device.userId != client.userID ||
        device.deviceId == client.deviceID ||
        device.deviceId != data['device']) {
      return;
    }
    final roomId = data['room_id'],
        session = data['session'],
        sent = data['sent_at'];
    if (roomId is! String ||
        session is! String ||
        session.isEmpty ||
        session.length > 128 ||
        sent is! int ||
        data['active'] is! bool) {
      return;
    }
    final room = client.getRoomById(roomId);
    if (room == null || !room.encrypted || room.membership != Membership.join) {
      return;
    }
    final age = DateTime.now().millisecondsSinceEpoch - sent;
    if (age < -30000 || age > 60000) return;
    final time = DateTime.fromMillisecondsSinceEpoch(sent);
    final id = key(roomId, session);
    final previous = handled[id];
    if (previous != null && !time.isAfter(previous)) return;
    if (data['active'] == false &&
        remote[id] != null &&
        remote[id]!.device != device.deviceId) {
      return;
    }
    handled[id] = time;
    if (handled.length > 128) {
      final oldest = handled.keys.first;
      handled.remove(oldest);
      remote.remove(oldest);
    }
    if (data['active'] == true) {
      remote[id] = (
        room: room,
        device: device.deviceId!,
        expires: time.add(const Duration(seconds: 60)),
      );
    } else {
      remote.remove(id);
    }
    changed();
  }

  bool isAccepted(VoiceCall call) => _accepted == call;

  void accept(VoiceCall call) {
    _accepted = call;
    update(call);
  }

  void update(VoiceCall? call) {
    if (_closed) return;
    final now = DateTime.now();
    remote.removeWhere((_, state) => !state.expires.isAfter(now));
    handled.removeWhere(
      (_, time) => now.difference(time) > const Duration(minutes: 10),
    );
    // An incoming call becomes local only after successful acceptance.
    final next =
        call != null &&
            !call.isClosed &&
            (_accepted == call || call.duration > Duration.zero)
        ? call
        : null;
    if (_local != next) {
      final previous = _local;
      _local = next;
      if (previous != null) _queue(previous, false);
      _lastSent = null;
    }
    if (next != null &&
        (_lastSent == null ||
            now.difference(_lastSent!) >= const Duration(seconds: 20))) {
      _lastSent = now;
      _queue(next, true);
    }
  }

  void _queue(VoiceCall call, bool active) {
    if (client.accessToken == null) return;
    _writes = (_writes ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) async {
          if (active && (_closed || call.isClosed || _local != call)) return;
          final devices =
              (await authorizedDevices(
                    call.chat,
                  ).timeout(const Duration(seconds: 8)))
                  .where(
                    (d) =>
                        d.userId == client.userID &&
                        d.deviceId != client.deviceID,
                  )
                  .toList();
          if (active && (_closed || call.isClosed || _local != call)) return;
          await client
              .sendToDeviceEncrypted(devices, 'dev.voicechat.call_device', {
                'room_id': call.chat.id,
                'session': call.session,
                'device': client.deviceID,
                'active': active,
                'sent_at': DateTime.now().millisecondsSinceEpoch,
              })
              .timeout(const Duration(seconds: 8));
        })
        .catchError((Object _) {
          // A later heartbeat retries; expiry prevents a permanent remote-call badge.
        });
  }

  Future<void> close() async {
    if (_closed) return;
    final call = _local;
    _closed = true;
    if (call != null) _queue(call, false);
    await _events.cancel();
    await _writes;
  }
}
