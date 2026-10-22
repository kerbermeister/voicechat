import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'first_keys.dart';
import 'user_action_error.dart';

Future<void> finishDeviceVerification(
  Client client,
  KeyVerification request,
  String user,
  String device,
  String signingKey,
  String curveKey,
) async {
  final current = client.userDeviceKeys[user]?.deviceKeys[device];
  if (request.canceled ||
      request.state != KeyVerificationState.done ||
      request.userId != user ||
      request.deviceId != device ||
      !request.createdAt
          .add(const Duration(minutes: 10))
          .isAfter(DateTime.now()) ||
      current == null ||
      !current.isValid ||
      current.blocked ||
      current.ed25519Key != signingKey ||
      current.curve25519Key != curveKey) {
    throw UserActionError(
      'Проверка не завершена или ключ устройства изменился. Доверие не изменено.',
    );
  }
  final proven = request.verifiedKeys.any(
    (key) =>
        key.userId == user &&
        !key.blocked &&
        (key is DeviceKeys &&
                key.isValid &&
                key.deviceId == device &&
                key.ed25519Key == signingKey &&
                key.curve25519Key == curveKey ||
            key is CrossSigningKey &&
                key.isValid &&
                key.usage.contains('master') &&
                key.publicKey ==
                    client.userDeviceKeys[user]?.masterKey?.publicKey &&
                current.hasValidSignatureChain(
                  onlyValidateUserIds: {user},
                  verifiedByTheirMasterKey: true,
                )),
  );
  if (!proven) {
    throw UserActionError(
      'Протокол не подтвердил ключ выбранного устройства. Повторите проверку.',
    );
  }
  final master = request.verifiedKeys
      .whereType<CrossSigningKey>()
      .where(
        (key) =>
            key.userId == user &&
            key.usage.contains('master') &&
            !key.blocked &&
            key.isValid &&
            key.publicKey == client.userDeviceKeys[user]?.masterKey?.publicKey,
      )
      .firstOrNull;
  await pinManuallyVerifiedDevice(client, current, master: master);
  if (master != null) await master.setVerified(true, false);
  await current.setVerified(true, false);
}

class DeviceVerifications extends ChangeNotifier {
  final Client client;
  final void Function() incoming;
  final requests =
      <
        KeyVerification,
        ({String user, String device, String signing, String curve})
      >{};
  final completed = <KeyVerification>{};
  final errors = <KeyVerification, String>{};
  final _finishing = <KeyVerification>{};
  final _deadlines = <KeyVerification, Timer>{};
  late final StreamSubscription<KeyVerification> _incoming;
  bool _closed = false;
  KeyVerification? viewing;
  DeviceVerifications(this.client, this.incoming) {
    client.verificationMethods = {
      KeyVerificationMethod.emoji,
      KeyVerificationMethod.numbers,
      KeyVerificationMethod.qrShow,
      KeyVerificationMethod.qrScan,
    };
    _incoming = client.onKeyVerificationRequest.stream.listen((request) {
      final known =
          request.userId == client.userID ||
          client.rooms.any(
            (room) =>
                room.membership == Membership.join &&
                room.getParticipants().any((u) => u.id == request.userId),
          );
      if (!known || requests.keys.where((r) => !r.isDone).length >= 3) {
        unawaited(request.cancel('m.user', true));
        return;
      }
      if (_attach(request)) incoming();
    });
  }
  List<KeyVerification> get pending =>
      requests.keys.where((r) => !r.isDone).toList();

  bool _attach(KeyVerification request) {
    final device =
        client.userDeviceKeys[request.userId]?.deviceKeys[request.deviceId];
    if (_closed ||
        device == null ||
        !device.isValid ||
        device.blocked ||
        request.createdAt
            .add(const Duration(minutes: 10))
            .isBefore(DateTime.now())) {
      unawaited(request.cancel('m.user', true));
      return false;
    }
    final duplicates = pending
        .where(
          (r) => r.userId == request.userId && r.deviceId == request.deviceId,
        )
        .toList();
    if (duplicates.isNotEmpty) {
      for (final old in [...duplicates, request]) {
        unawaited(old.cancel('m.unexpected_message').catchError((Object _) {}));
      }
      return false;
    }
    requests[request] = (
      user: device.userId,
      device: device.deviceId!,
      signing: device.ed25519Key!,
      curve: device.curve25519Key!,
    );
    request.onUpdate = () => unawaited(_changed(request));
    _deadlines[request] = Timer(
      request.createdAt
          .add(const Duration(minutes: 10))
          .difference(DateTime.now()),
      () {
        if (!request.isDone) {
          unawaited(request.cancel('m.timeout').catchError((Object _) {}));
        }
      },
    );
    unawaited(_changed(request));
    return true;
  }

  Future<KeyVerification> start(DeviceKeys device) async {
    if (_closed) throw StateError('Verification closed');
    final request = await device.startVerification();
    if (!_attach(request)) {
      throw UserActionError(
        'Проверка этого устройства уже идёт или недоступна.',
      );
    }
    return request;
  }

  Future<void> _changed(KeyVerification request) async {
    if (_closed || !requests.containsKey(request)) return;
    if (request.isDone) _deadlines.remove(request)?.cancel();
    if (request.canceled && viewing != request) {
      forget(request);
      return;
    }
    if (request.state == KeyVerificationState.done &&
        !request.canceled &&
        !completed.contains(request) &&
        _finishing.add(request)) {
      try {
        final target = requests[request]!;
        await finishDeviceVerification(
          client,
          request,
          target.user,
          target.device,
          target.signing,
          target.curve,
        );
        if (!_closed && requests.containsKey(request)) completed.add(request);
      } catch (_) {
        if (!_closed && requests.containsKey(request)) {
          errors[request] =
              'Ключ не удалось подтвердить и сохранить. Повторите сверку устройств.';
        }
      }
    }
    if (!_closed) notifyListeners();
  }

  void forget(KeyVerification request) {
    request.onUpdate = null;
    _deadlines.remove(request)?.cancel();
    requests.remove(request);
    completed.remove(request);
    errors.remove(request);
    _finishing.remove(request);
    if (!_closed) notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.cancel();
    client.verificationMethods = {};
    for (final timer in _deadlines.values) {
      timer.cancel();
    }
    for (final request in requests.keys) {
      request.onUpdate = null;
      if (!request.isDone) {
        unawaited(request.cancel('m.user').catchError((Object _) {}));
      }
    }
    requests.clear();
    completed.clear();
    errors.clear();
    dispose();
  }
}
