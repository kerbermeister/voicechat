import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'first_keys.dart';
import 'matrix_probe.dart';
import 'user_action_error.dart';

class HistoryRecovery extends ChangeNotifier {
  final Client client;
  final void Function() incoming;
  final _requests =
      <RoomKeyRequest, ({DateTime received, String signing, String curve})>{};
  final _sending = <RoomKeyRequest>{};
  late final StreamSubscription<RoomKeyRequest> _subscription;
  bool _closed = false;

  HistoryRecovery(this.client, this.incoming) {
    _subscription = client.onRoomKeyRequest.stream.listen(_receive);
    final manager = client.encryption!.keyManager;
    for (final request in manager.incomingShareRequests.values.toList()) {
      if (request.devices.length != 1) continue;
      _receive(
        RoomKeyRequest.fromToDeviceEvent(
          ToDeviceEvent(
            sender: request.devices.single.userId,
            type: EventTypes.RoomKeyRequest,
            content: {},
          ),
          manager,
          request,
        ),
      );
    }
  }

  void _receive(RoomKeyRequest request) {
    if (_closed ||
        request.request.devices.length != 1 ||
        request.keyManager.client != client ||
        request.request.canceled ||
        _requests.keys.any(
          (r) => r.request.requestId == request.request.requestId,
        )) {
      return;
    }
    final device = request.requestingDevice;
    if (request.sender != device.userId ||
        device.ed25519Key == null ||
        device.curve25519Key == null) {
      return;
    }
    for (final expired in _requests.keys.where((r) => !_active(r)).toList()) {
      dismiss(expired);
    }
    if (_requests.length >= 32) return;
    final first = _requests.isEmpty;
    _requests[request] = (
      received: DateTime.now(),
      signing: device.ed25519Key!,
      curve: device.curve25519Key!,
    );
    notifyListeners();
    if (first) incoming();
  }

  bool _active(RoomKeyRequest request) =>
      !_closed &&
      !request.request.canceled &&
      (_requests[request]?.received
              .add(const Duration(minutes: 10))
              .isAfter(DateTime.now()) ??
          false);

  List<RoomKeyRequest> get pending => _requests.keys.where(_active).toList();

  void dismiss(RoomKeyRequest request) {
    _requests.remove(request);
    request.request.canceled = true;
    request.keyManager.incomingShareRequests.remove(request.request.requestId);
    notifyListeners();
  }

  Future<void> approve(RoomKeyRequest request) async {
    if (!_requests.containsKey(request) ||
        !_active(request) ||
        !_sending.add(request)) {
      throw UserActionError('Запрос истории истёк или уже обрабатывается.');
    }
    try {
      final original = _requests[request]!;
      final device = request.requestingDevice;
      await refreshDevices(client, {device.userId});
      final current =
          client.userDeviceKeys[device.userId]?.deviceKeys[device.deviceId];
      final members = await client.getJoinedMembersByRoom(request.room.id);
      if (!_active(request) ||
          request.room.membership != Membership.join ||
          members?.containsKey(client.userID) != true ||
          members?.containsKey(device.userId) != true ||
          current == null ||
          !current.isValid ||
          current.blocked ||
          !current.directVerified ||
          current.ed25519Key != original.signing ||
          current.curve25519Key != original.curve ||
          !(await independentlyVerifiedDevices(client, [
            current,
          ])).contains(current)) {
        throw UserActionError(
          'Передача не выполнена. Сначала независимо сверьте устройство; оба участника должны оставаться в чате.',
        );
      }
      final session = await request.keyManager.loadInboundGroupSession(
        request.room.id,
        request.request.sessionId,
      );
      if (!_active(request) || session?.isValid != true) {
        throw UserActionError('Запрос отменён или ключ больше недоступен.');
      }
      request.request.devices[0] = current;
      await request.forwardKey();
      _requests.remove(request);
      if (!_closed) notifyListeners();
    } finally {
      _sending.remove(request);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    _requests.clear();
    dispose();
  }
}

Future<int> requestMissingHistory(Timeline timeline) async {
  final sessions = <String>{};
  for (final event in timeline.events.toList()) {
    if (event.type != EventTypes.Encrypted ||
        event.messageType != MessageTypes.BadEncrypted ||
        event.content['can_request_session'] != true) {
      continue;
    }
    final session = event.content['session_id'];
    if (session is! String || !sessions.add(session)) continue;
    await event.requestKey();
  }
  return sessions.length;
}
